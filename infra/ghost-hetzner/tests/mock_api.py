import base64
import hashlib
import itertools
import json
import re
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

HCLOUD_TOKEN = "test-hcloud-token"
CF_TOKEN = "test-cf-token"
ZONE = {"id": "zone-1", "name": "example.test", "account": {"id": "account-1"}}


class MockState:
    def __init__(self) -> None:
        self.lock = threading.Lock()
        self.reset()

    def reset(self) -> None:
        self.ids = itertools.count(1)
        self.requests: list[dict] = []
        self.server_types = {
            "cx22": {"id": 1, "name": "cx22", "deprecation": None},
            "cx11": {"id": 2, "name": "cx11", "deprecation": {"announced": "2024-01-01"}},
        }
        self.ssh_keys: dict[int, dict] = {}
        self.firewalls: dict[int, dict] = {}
        self.servers: dict[int, dict] = {}
        self.tunnels: dict[str, dict] = {}
        self.tunnel_configs: dict[str, dict] = {}
        self.dns_records: dict[str, dict] = {}
        self.access_apps: dict[str, dict] = {}
        self.access_policies: dict[str, dict[str, dict]] = {}

    def next_id(self) -> int:
        return next(self.ids)

    def snapshot(self) -> dict:
        return {
            "requests": self.requests,
            "ssh_keys": list(self.ssh_keys.values()),
            "firewalls": list(self.firewalls.values()),
            "servers": list(self.servers.values()),
            "tunnels": list(self.tunnels.values()),
            "tunnel_configs": self.tunnel_configs,
            "dns_records": list(self.dns_records.values()),
            "access_apps": list(self.access_apps.values()),
            "access_policies": self.access_policies,
        }


STATE = MockState()
ROUTES: list[tuple[str, re.Pattern, object]] = []


def route(method: str, pattern: str):
    def register(handler):
        ROUTES.append((method, re.compile(f"^{pattern}$"), handler))
        return handler

    return register


def md5_fingerprint(public_key: str) -> str:
    digest = hashlib.md5(base64.b64decode(public_key.split()[1])).hexdigest()
    return ":".join(digest[i : i + 2] for i in range(0, len(digest), 2))


def cf_ok(result, status=200):
    return status, {"success": True, "errors": [], "result": result}


def cf_error(status, message):
    return status, {"success": False, "errors": [{"code": status, "message": message}], "result": None}


def hcloud_error(status, code, message):
    return status, {"error": {"code": code, "message": message}}


@route("GET", "/hcloud/server_types")
def list_server_types(query, _body):
    name = query.get("name")
    types = [t for t in STATE.server_types.values() if name in (None, t["name"])]
    return 200, {"server_types": types}


@route("GET", "/hcloud/ssh_keys")
def list_ssh_keys(query, _body):
    keys = list(STATE.ssh_keys.values())
    if "fingerprint" in query:
        keys = [k for k in keys if k["fingerprint"] == query["fingerprint"]]
    if "label_selector" in query:
        label, value = query["label_selector"].split("=")
        keys = [k for k in keys if k["labels"].get(label) == value]
    return 200, {"ssh_keys": keys}


@route("POST", "/hcloud/ssh_keys")
def create_ssh_key(_query, body):
    if any(k["name"] == body["name"] for k in STATE.ssh_keys.values()):
        return hcloud_error(409, "uniqueness_error", "SSH key name already in use")
    key = {
        "id": STATE.next_id(),
        "name": body["name"],
        "public_key": body["public_key"],
        "fingerprint": md5_fingerprint(body["public_key"]),
        "labels": body.get("labels", {}),
    }
    STATE.ssh_keys[key["id"]] = key
    return 201, {"ssh_key": key}


@route("DELETE", r"/hcloud/ssh_keys/(\d+)")
def delete_ssh_key(_query, _body, key_id):
    STATE.ssh_keys.pop(int(key_id), None)
    return 204, None


@route("GET", "/hcloud/firewalls")
def list_firewalls(query, _body):
    name = query.get("name")
    return 200, {"firewalls": [f for f in STATE.firewalls.values() if name in (None, f["name"])]}


@route("POST", "/hcloud/firewalls")
def create_firewall(_query, body):
    firewall = {"id": STATE.next_id(), "name": body["name"], "labels": body.get("labels", {}), "rules": body.get("rules", [])}
    STATE.firewalls[firewall["id"]] = firewall
    return 201, {"firewall": firewall, "actions": []}


@route("POST", r"/hcloud/firewalls/(\d+)/actions/set_rules")
def set_firewall_rules(_query, body, firewall_id):
    STATE.firewalls[int(firewall_id)]["rules"] = body["rules"]
    return 201, {"actions": []}


@route("POST", r"/hcloud/firewalls/(\d+)/actions/apply_to_resources")
def apply_firewall(_query, body, firewall_id):
    for target in body["apply_to"]:
        server = STATE.servers[target["server"]["id"]]
        server["public_net"]["firewalls"].append({"id": int(firewall_id), "status": "applied"})
    return 201, {"actions": []}


@route("DELETE", r"/hcloud/firewalls/(\d+)")
def delete_firewall(_query, _body, firewall_id):
    firewall_id = int(firewall_id)
    in_use = any(fw["id"] == firewall_id for s in STATE.servers.values() for fw in s["public_net"]["firewalls"])
    if in_use:
        return hcloud_error(422, "resource_in_use", "firewall is still applied to a server")
    STATE.firewalls.pop(firewall_id, None)
    return 204, None


@route("GET", "/hcloud/servers")
def list_servers(query, _body):
    name = query.get("name")
    return 200, {"servers": [s for s in STATE.servers.values() if name in (None, s["name"])]}


@route("POST", "/hcloud/servers")
def create_server(_query, body):
    if any(s["name"] == body["name"] for s in STATE.servers.values()):
        return hcloud_error(409, "uniqueness_error", "server name is already used")
    server = {
        "id": STATE.next_id(),
        "name": body["name"],
        "status": "initializing",
        "request": body,
        "public_net": {"firewalls": [{"id": fw["firewall"], "status": "applied"} for fw in body.get("firewalls", [])]},
        "labels": body.get("labels", {}),
    }
    STATE.servers[server["id"]] = server
    return 201, {"server": server, "action": {"id": STATE.next_id(), "status": "running"}}


@route("GET", r"/hcloud/servers/(\d+)")
def get_server(_query, _body, server_id):
    server = STATE.servers.get(int(server_id))
    if server is None:
        return hcloud_error(404, "not_found", "server not found")
    server["status"] = "running"
    return 200, {"server": server}


@route("DELETE", r"/hcloud/servers/(\d+)")
def delete_server(_query, _body, server_id):
    STATE.servers.pop(int(server_id), None)
    return 200, {"action": {"id": STATE.next_id(), "status": "running"}}


@route("GET", "/cf/zones")
def list_zones(query, _body):
    return cf_ok([ZONE] if query.get("name") == ZONE["name"] else [])


@route("GET", r"/cf/accounts/account-1/cfd_tunnel")
def list_tunnels(query, _body):
    name = query.get("name")
    return cf_ok([t for t in STATE.tunnels.values() if name in (None, t["name"])])


@route("POST", r"/cf/accounts/account-1/cfd_tunnel")
def create_tunnel(_query, body):
    tunnel = {"id": f"tunnel-{STATE.next_id()}", "name": body["name"], "config_src": body.get("config_src")}
    STATE.tunnels[tunnel["id"]] = tunnel
    return cf_ok(tunnel)


@route("GET", r"/cf/accounts/account-1/cfd_tunnel/([\w-]+)")
def get_tunnel(_query, _body, tunnel_id):
    tunnel = STATE.tunnels[tunnel_id]
    status = "healthy" if STATE.servers else "inactive"
    return cf_ok({**tunnel, "status": status})


@route("PUT", r"/cf/accounts/account-1/cfd_tunnel/([\w-]+)/configurations")
def put_tunnel_config(_query, body, tunnel_id):
    STATE.tunnel_configs[tunnel_id] = body["config"]
    return cf_ok({"tunnel_id": tunnel_id, "config": body["config"]})


@route("GET", r"/cf/accounts/account-1/cfd_tunnel/([\w-]+)/token")
def get_tunnel_token(_query, _body, tunnel_id):
    return cf_ok(f"fake-token-for-{tunnel_id}")


@route("DELETE", r"/cf/accounts/account-1/cfd_tunnel/([\w-]+)/connections")
def delete_tunnel_connections(_query, _body, _tunnel_id):
    return cf_ok(None)


@route("DELETE", r"/cf/accounts/account-1/cfd_tunnel/([\w-]+)")
def delete_tunnel(_query, _body, tunnel_id):
    if STATE.servers:
        return cf_error(400, "tunnel has active connections")
    STATE.tunnels.pop(tunnel_id, None)
    return cf_ok(None)


@route("GET", "/cf/zones/zone-1/dns_records")
def list_dns_records(query, _body):
    records = [
        r for r in STATE.dns_records.values()
        if query.get("type") in (None, r["type"]) and query.get("name") in (None, r["name"])
    ]
    return cf_ok(records)


@route("POST", "/cf/zones/zone-1/dns_records")
def create_dns_record(_query, body):
    if any(r["name"] == body["name"] for r in STATE.dns_records.values()):
        return cf_error(400, "a record with that host already exists")
    record = {"id": f"record-{STATE.next_id()}", **body}
    STATE.dns_records[record["id"]] = record
    return cf_ok(record)


@route("PUT", r"/cf/zones/zone-1/dns_records/([\w-]+)")
def update_dns_record(_query, body, record_id):
    STATE.dns_records[record_id] = {"id": record_id, **body}
    return cf_ok(STATE.dns_records[record_id])


@route("DELETE", r"/cf/zones/zone-1/dns_records/([\w-]+)")
def delete_dns_record(_query, _body, record_id):
    STATE.dns_records.pop(record_id, None)
    return cf_ok({"id": record_id})


@route("GET", "/cf/accounts/account-1/access/apps")
def list_access_apps(_query, _body):
    return cf_ok(list(STATE.access_apps.values()))


@route("POST", "/cf/accounts/account-1/access/apps")
def create_access_app(_query, body):
    app = {"id": f"app-{STATE.next_id()}", **body}
    STATE.access_apps[app["id"]] = app
    STATE.access_policies[app["id"]] = {}
    return cf_ok(app)


@route("DELETE", r"/cf/accounts/account-1/access/apps/([\w-]+)")
def delete_access_app(_query, _body, app_id):
    STATE.access_apps.pop(app_id, None)
    STATE.access_policies.pop(app_id, None)
    return cf_ok({"id": app_id})


@route("GET", r"/cf/accounts/account-1/access/apps/([\w-]+)/policies")
def list_access_policies(_query, _body, app_id):
    return cf_ok(list(STATE.access_policies[app_id].values()))


@route("POST", r"/cf/accounts/account-1/access/apps/([\w-]+)/policies")
def create_access_policy(_query, body, app_id):
    policy = {"id": f"policy-{STATE.next_id()}", **body}
    STATE.access_policies[app_id][policy["id"]] = policy
    return cf_ok(policy)


@route("PUT", r"/cf/accounts/account-1/access/apps/([\w-]+)/policies/([\w-]+)")
def update_access_policy(_query, body, app_id, policy_id):
    STATE.access_policies[app_id][policy_id] = {"id": policy_id, **body}
    return cf_ok(STATE.access_policies[app_id][policy_id])


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_args) -> None:
        pass

    def _send(self, status: int, payload) -> None:
        data = b"" if payload is None else json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _handle(self) -> None:
        parsed = urlparse(self.path)
        query = {k: v[0] for k, v in parse_qs(parsed.query).items()}
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b""
        body = json.loads(raw) if raw else None

        if parsed.path == "/health":
            return self._send(200, {"status": "ok"})
        if parsed.path == "/_state":
            with STATE.lock:
                return self._send(200, STATE.snapshot())

        expected = HCLOUD_TOKEN if parsed.path.startswith("/hcloud/") else CF_TOKEN
        if self.headers.get("Authorization") != f"Bearer {expected}":
            return self._send(401, {"error": {"code": "unauthorized", "message": "bad token"}})

        with STATE.lock:
            STATE.requests.append({"method": self.command, "path": parsed.path, "query": query, "body": body})
            for method, pattern, handler in ROUTES:
                match = pattern.match(parsed.path)
                if method == self.command and match:
                    status, payload = handler(query, body, *match.groups())
                    return self._send(status, payload)
        return self._send(404, {"error": {"code": "not_found", "message": f"no mock for {self.command} {parsed.path}"}})

    do_GET = do_POST = do_PUT = do_DELETE = _handle


def start_server() -> ThreadingHTTPServer:
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server
