#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

ssh-keygen -q -t ed25519 -N "" -C "ci@example.test" -f "$WORK/id"
cat >"$WORK/test.env" <<EOF
CF_ZONE=example.test
ADMIN_EMAIL=admin@example.test
SSH_PUBLIC_KEY_FILE=$WORK/id.pub
EOF
"$ROOT/deploy.sh" --env "$WORK/test.env" --render-only "$WORK/server" 2>/dev/null

docker run --rm -v "$WORK/server:/work:ro" -v "$WORK/id.pub:/key.pub:ro" ubuntu:24.04 bash -euo pipefail -c '
  apt-get update -qq >/dev/null
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq cloud-init >/dev/null 2>&1
  cloud-init schema --config-file /work/user-data.yaml --annotate
  packages="$(python3 -c "import yaml; print(\" \".join(yaml.safe_load(open(\"/work/user-data.yaml\"))[\"packages\"]))")"
  # shellcheck disable=SC2086
  apt-cache show $packages >/dev/null && echo "all packages exist in Ubuntu 24.04: $packages"
  python3 - <<PY
import base64, yaml
config = yaml.safe_load(open("/work/user-data.yaml"))
sources = {"compose.yml", ".env", "ghost.env", "bootstrap.env", "bootstrap.sh"}
for entry in config["write_files"]:
    name = entry["path"].rsplit("/", 1)[1]
    assert base64.b64decode(entry["content"]) == open(f"/work/{name}", "rb").read(), name
    sources.discard(name)
assert not sources, f"missing from write_files: {sources}"
assert config["users"][0]["ssh_authorized_keys"] == [open("/key.pub").read().strip()], "authorized key mismatch"
print("write_files decode to the rendered server files; authorized key matches")
PY
'
