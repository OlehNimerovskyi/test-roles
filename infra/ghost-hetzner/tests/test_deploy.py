import base64
import os
import re
import subprocess
import tempfile
import unittest
from collections import Counter
from pathlib import Path

from mock_api import CF_TOKEN, HCLOUD_TOKEN, STATE, start_server

ROOT = Path(__file__).resolve().parent.parent
BLOG_HOST = "blog.example.test"
SSH_HOST = "ssh.example.test"
WRITE_FILE = re.compile(r'  - path: (\S+)\n    permissions: "(\d+)"\n    encoding: b64\n    content: "(\S*)"')


def decode_write_files(user_data: str) -> dict[str, tuple[str, str]]:
    return {
        path: (permissions, base64.b64decode(content).decode())
        for path, permissions, content in WRITE_FILE.findall(user_data)
    }


def parse_env(text: str) -> dict[str, str]:
    return dict(line.split("=", 1) for line in text.splitlines() if "=" in line)


class DeployScriptsTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.server = start_server()
        cls.base_url = f"http://127.0.0.1:{cls.server.server_port}"
        cls.tmp = tempfile.TemporaryDirectory()
        cls.key_file = Path(cls.tmp.name) / "id_test"
        subprocess.run(
            ["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", "test@example.test", "-f", str(cls.key_file)],
            check=True,
        )

    @classmethod
    def tearDownClass(cls) -> None:
        cls.server.shutdown()
        cls.tmp.cleanup()

    def setUp(self) -> None:
        STATE.reset()
        self.work_dir = Path(tempfile.mkdtemp(dir=self.tmp.name))
        self.env_file = self.write_env()

    def write_env(self, **overrides: str | None) -> Path:
        settings = {
            "HCLOUD_TOKEN": HCLOUD_TOKEN,
            "CF_API_TOKEN": CF_TOKEN,
            "CF_ZONE": "example.test",
            "ADMIN_EMAIL": '"admin@example.test, second@example.test"',
            "SSH_PUBLIC_KEY_FILE": f"{self.key_file}.pub",
            "GHOST_BLOG_TITLE": '"Test Blog"',
            **overrides,
        }
        env_file = self.work_dir / "test.env"
        env_file.write_text("".join(f"{k}={v}\n" for k, v in settings.items() if v is not None))
        return env_file

    def run_script(self, script: str, *args: str, stdin: str = "") -> subprocess.CompletedProcess:
        env = {
            **os.environ,
            "HCLOUD_API_URL": f"{self.base_url}/hcloud",
            "CF_API_URL": f"{self.base_url}/cf",
            "BLOG_HEALTHCHECK_URL": f"{self.base_url}/health",
            "POLL_INTERVAL": "0",
            "DEPLOY_TIMEOUT": "5",
            "STATE_DIR": str(self.work_dir / "state"),
        }
        return subprocess.run(
            ["bash", str(ROOT / script), "--env", str(self.env_file), *args],
            env=env,
            input=stdin,
            capture_output=True,
            text=True,
            timeout=120,
        )

    def deploy(self) -> subprocess.CompletedProcess:
        result = self.run_script("deploy.sh")
        self.assertEqual(result.returncode, 0, result.stderr)
        return result

    def test_server_is_reachable_only_through_the_tunnel(self) -> None:
        self.deploy()
        state = STATE.snapshot()

        [firewall] = state["firewalls"]
        [server] = state["servers"]
        self.assertEqual(firewall["rules"], [])
        self.assertEqual(server["request"]["firewalls"], [{"firewall": firewall["id"]}])

        [tunnel] = state["tunnels"]
        self.assertEqual(tunnel["config_src"], "cloudflare")
        self.assertEqual(
            state["tunnel_configs"][tunnel["id"]]["ingress"],
            [
                {"hostname": BLOG_HOST, "service": "http://127.0.0.1:2368"},
                {"hostname": SSH_HOST, "service": "ssh://127.0.0.1:22"},
                {"service": "http_status:404"},
            ],
        )
        records = {record["name"]: record for record in state["dns_records"]}
        for host in (BLOG_HOST, SSH_HOST):
            self.assertEqual(records[host]["content"], f"{tunnel['id']}.cfargotunnel.com")
            self.assertTrue(records[host]["proxied"])

    def test_ssh_hostname_is_gated_by_cloudflare_access(self) -> None:
        self.deploy()
        state = STATE.snapshot()

        [app] = state["access_apps"]
        [policy] = state["access_policies"][app["id"]].values()
        self.assertEqual(app["domain"], SSH_HOST)
        self.assertEqual(policy["decision"], "allow")
        self.assertEqual(
            policy["include"],
            [{"email": {"email": "admin@example.test"}}, {"email": {"email": "second@example.test"}}],
        )

    def test_user_data_ships_server_files_with_tight_permissions(self) -> None:
        self.deploy()
        state = STATE.snapshot()
        user_data = state["servers"][0]["request"]["user_data"]
        files = decode_write_files(user_data)

        self.assertTrue(user_data.startswith("#cloud-config\n"))
        self.assertIn("ssh_pwauth: false", user_data)
        self.assertIn("disable_root: true", user_data)
        self.assertEqual(files["/opt/ghost/compose.yml"], ("0644", (ROOT / "server/compose.yml").read_text()))
        self.assertEqual(files["/opt/ghost/bootstrap.sh"], ("0700", (ROOT / "server/bootstrap.sh").read_text()))
        for secret_file in ("/opt/ghost/.env", "/opt/ghost/ghost.env", "/opt/ghost/bootstrap.env"):
            self.assertEqual(files[secret_file][0], "0600")

        bootstrap_env = parse_env(files["/opt/ghost/bootstrap.env"][1])
        self.assertEqual(bootstrap_env["CF_TUNNEL_TOKEN"], f"fake-token-for-{state['tunnels'][0]['id']}")
        self.assertEqual(bootstrap_env["GHOST_OWNER_EMAIL"], "admin@example.test")
        self.assertEqual(parse_env(files["/opt/ghost/.env"][1])["GHOST_URL"], f"https://{BLOG_HOST}")

    def test_owner_credentials_are_saved_privately_and_match_the_server(self) -> None:
        result = self.deploy()
        files = decode_write_files(STATE.snapshot()["servers"][0]["request"]["user_data"])
        owner_password = parse_env(files["/opt/ghost/bootstrap.env"][1])["GHOST_OWNER_PASSWORD"]
        credentials = self.work_dir / "state" / "ghost-blog-credentials.txt"

        self.assertEqual(credentials.stat().st_mode & 0o777, 0o600)
        self.assertIn(f"Password: {owner_password}", credentials.read_text())
        self.assertGreaterEqual(len(owner_password), 20)
        self.assertIn("Ghost is live.", result.stdout)

    def test_second_deploy_reuses_every_resource(self) -> None:
        self.deploy()
        second = self.deploy()
        state = STATE.snapshot()

        creates = Counter(r["path"] for r in state["requests"] if r["method"] == "POST" and "/actions/" not in r["path"])
        self.assertEqual(
            creates,
            Counter({
                "/cf/accounts/account-1/cfd_tunnel": 1,
                "/cf/zones/zone-1/dns_records": 2,
                "/cf/accounts/account-1/access/apps": 1,
                f"/cf/accounts/account-1/access/apps/{state['access_apps'][0]['id']}/policies": 1,
                "/hcloud/ssh_keys": 1,
                "/hcloud/firewalls": 1,
                "/hcloud/servers": 1,
            }),
        )
        self.assertIn("already exists", second.stderr)
        self.assertNotIn("Password:", second.stdout)

    def test_destroy_removes_everything_deploy_created(self) -> None:
        self.deploy()
        result = self.run_script("destroy.sh", "--yes")
        state = STATE.snapshot()

        self.assertEqual(result.returncode, 0, result.stderr)
        for resource in ("servers", "firewalls", "ssh_keys", "tunnels", "dns_records", "access_apps"):
            self.assertEqual(state[resource], [], resource)
        self.assertFalse((self.work_dir / "state" / "ghost-blog-credentials.txt").exists())

    def test_destroy_without_confirmation_deletes_nothing(self) -> None:
        self.deploy()
        result = self.run_script("destroy.sh", stdin="wrong-name\n")
        state = STATE.snapshot()

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("aborted", result.stderr)
        self.assertFalse([r for r in state["requests"] if r["method"] == "DELETE"])
        self.assertEqual(len(state["servers"]), 1)

    def test_missing_token_fails_before_any_api_call(self) -> None:
        self.env_file = self.write_env(HCLOUD_TOKEN=None)
        result = self.run_script("deploy.sh")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("HCLOUD_TOKEN is not set", result.stderr)
        self.assertEqual(STATE.snapshot()["requests"], [])

    def test_unknown_server_type_stops_before_creating_anything(self) -> None:
        self.env_file = self.write_env(SERVER_TYPE="cx999")
        result = self.run_script("deploy.sh")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("server type cx999 does not exist", result.stderr)
        self.assertFalse([r for r in STATE.snapshot()["requests"] if r["method"] != "GET"])

    def test_render_only_writes_server_files_without_calling_apis(self) -> None:
        self.env_file = self.write_env(SMTP_HOST="smtp.example.test", SMTP_USER="mailer")
        out = self.work_dir / "rendered"
        result = self.run_script("deploy.sh", "--render-only", str(out))

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(STATE.snapshot()["requests"], [])
        for name in ("compose.yml", ".env", "ghost.env", "bootstrap.env", "bootstrap.sh", "user-data.yaml"):
            self.assertTrue((out / name).exists(), name)
        self.assertEqual((out / ".env").stat().st_mode & 0o777, 0o600)
        self.assertIn("mail__options__host='smtp.example.test'", (out / "ghost.env").read_text())


if __name__ == "__main__":
    unittest.main()
