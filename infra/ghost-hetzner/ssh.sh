#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

env_file="$SCRIPT_DIR/.env"
if [[ "${1:-}" == "--env" ]]; then
  env_file="${2:?--env needs a file}"
  shift 2
fi

require_commands ssh cloudflared
load_config "$env_file"
require_vars CF_ZONE

# cloudflared opens a browser for the Cloudflare Access login, then proxies SSH through the tunnel
exec ssh -o "ProxyCommand=cloudflared access ssh --hostname %h" "$SSH_USER@$SSH_HOSTNAME" "$@"
