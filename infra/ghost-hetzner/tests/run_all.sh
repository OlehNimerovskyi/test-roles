#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

step() { printf '\n\033[1m== %s\033[0m\n' "$*"; }

step "shellcheck"
shellcheck -x deploy.sh destroy.sh ssh.sh server/bootstrap.sh tests/*.sh
echo "clean"

step "deploy.sh and destroy.sh against mock Hetzner and Cloudflare APIs"
(cd tests && python3 -m unittest test_deploy -v)

step "bootstrap ordering: the tunnel opens only after Ghost has an owner"
bash tests/test_bootstrap_order.sh

step "cloud-init user data in an Ubuntu 24.04 container"
bash tests/validate_cloud_init.sh

step "Ghost and MySQL from the rendered server files"
bash tests/test_ghost_stack.sh
