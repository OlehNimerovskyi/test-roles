# shellcheck shell=bash

HCLOUD_API_URL="${HCLOUD_API_URL:-https://api.hetzner.cloud/v1}"
CF_API_URL="${CF_API_URL:-https://api.cloudflare.com/client/v4}"
MANAGED_BY="ghost-deploy"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die() {
  printf '\033[1;31merror:\033[0m %s\n' "$*" >&2
  exit 1
}

require_commands() {
  local cmd
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || die "missing required command: $cmd"
  done
}

require_vars() {
  local name
  for name in "$@"; do
    [[ -n "${!name:-}" ]] || die "$name is not set (see .env.example)"
  done
}

load_config() {
  local env_file="$1"
  [[ -f "$env_file" ]] || die "config file not found: $env_file (copy .env.example to .env and fill it in)"
  set -a
  # shellcheck disable=SC1090
  source "$env_file"
  set +a

  SERVER_NAME="${SERVER_NAME:-ghost-blog}"
  SERVER_TYPE="${SERVER_TYPE:-cx22}"
  SERVER_LOCATION="${SERVER_LOCATION:-nbg1}"
  SERVER_IMAGE="${SERVER_IMAGE:-ubuntu-24.04}"
  SSH_USER="${SSH_USER:-admin}"
  SSH_PUBLIC_KEY_FILE="${SSH_PUBLIC_KEY_FILE:-$HOME/.ssh/id_ed25519.pub}"
  BLOG_HOSTNAME="${BLOG_HOSTNAME:-blog.${CF_ZONE:-}}"
  SSH_HOSTNAME="${SSH_HOSTNAME:-ssh.${CF_ZONE:-}}"
  TUNNEL_NAME="${TUNNEL_NAME:-$SERVER_NAME}"
  GHOST_OWNER_NAME="${GHOST_OWNER_NAME:-Admin}"
  local first_admin_email="${ADMIN_EMAIL:-}"
  first_admin_email="${first_admin_email%%,*}"
  GHOST_OWNER_EMAIL="${GHOST_OWNER_EMAIL:-${first_admin_email// /}}"
  GHOST_BLOG_TITLE="${GHOST_BLOG_TITLE:-My Ghost Blog}"
  DEPLOY_TIMEOUT="${DEPLOY_TIMEOUT:-900}"
  POLL_INTERVAL="${POLL_INTERVAL:-10}"
}

# Tokens go into 0600 header files so they never show up in `ps` output
setup_auth_headers() {
  AUTH_DIR="$(mktemp -d)"
  chmod 700 "$AUTH_DIR"
  trap 'rm -rf "$AUTH_DIR"' EXIT
  printf 'Authorization: Bearer %s\n' "$HCLOUD_TOKEN" >"$AUTH_DIR/hcloud"
  printf 'Authorization: Bearer %s\n' "$CF_API_TOKEN" >"$AUTH_DIR/cf"
  chmod 600 "$AUTH_DIR/hcloud" "$AUTH_DIR/cf"
}

# Prints "<http status>\n<body>"; callers that must succeed use hcloud/cf instead
api_request() {
  local method="$1" url="$2" header_file="$3" body="${4:-}"
  local args=(-sS -X "$method" -H "@$header_file" -H "Content-Type: application/json" -w '\n%{http_code}')
  local response
  if [[ -n "$body" ]]; then
    response="$(curl "${args[@]}" --data-binary @- "$url" <<<"$body")" || die "request failed: $method $url"
  else
    response="$(curl "${args[@]}" "$url")" || die "request failed: $method $url"
  fi
  printf '%s\n%s' "${response##*$'\n'}" "${response%$'\n'*}"
}

api_or_die() {
  local method="$1" url="$2" header_file="$3" body="${4:-}"
  local response status payload message
  response="$(api_request "$method" "$url" "$header_file" "$body")"
  status="${response%%$'\n'*}"
  payload="${response#*$'\n'}"
  if [[ "$status" -ge 400 ]]; then
    message="$(jq -r '.error.message // .errors[0].message // empty' <<<"$payload" 2>/dev/null || true)"
    die "$method ${url%%\?*} failed with HTTP $status${message:+: $message}"
  fi
  printf '%s' "$payload"
}

hcloud() { api_or_die "$1" "$HCLOUD_API_URL$2" "$AUTH_DIR/hcloud" "${3:-}"; }
cf() { api_or_die "$1" "$CF_API_URL$2" "$AUTH_DIR/cf" "${3:-}"; }
status_only() {
  local response
  response="$(api_request "$@")"
  printf '%s' "${response%%$'\n'*}"
}
hcloud_status() { status_only "$1" "$HCLOUD_API_URL$2" "$AUTH_DIR/hcloud" "${3:-}"; }
cf_status() { status_only "$1" "$CF_API_URL$2" "$AUTH_DIR/cf" "${3:-}"; }

urlencode() { jq -rn --arg value "$1" '$value | @uri'; }

resolve_zone() {
  local zone
  zone="$(cf GET "/zones?name=$(urlencode "$CF_ZONE")")"
  CF_ZONE_ID="$(jq -r '.result[0].id // empty' <<<"$zone")"
  CF_ACCOUNT_ID="$(jq -r '.result[0].account.id // empty' <<<"$zone")"
  [[ -n "$CF_ZONE_ID" ]] || die "Cloudflare zone $CF_ZONE not found (is the domain on this Cloudflare account?)"
}

find_tunnel_id() {
  cf GET "/accounts/$CF_ACCOUNT_ID/cfd_tunnel?name=$(urlencode "$TUNNEL_NAME")&is_deleted=false" |
    jq -r '.result[0].id // empty'
}

find_server_id() {
  hcloud GET "/servers?name=$(urlencode "$SERVER_NAME")" | jq -r '.servers[0].id // empty'
}

find_access_app_id() {
  cf GET "/accounts/$CF_ACCOUNT_ID/access/apps" |
    jq -r --arg domain "$SSH_HOSTNAME" '[.result[] | select(.domain == $domain)][0].id // empty'
}

find_dns_record_id() {
  cf GET "/zones/$CF_ZONE_ID/dns_records?type=CNAME&name=$(urlencode "$1")" | jq -r '.result[0].id // empty'
}
