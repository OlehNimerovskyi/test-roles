#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

usage() {
  cat <<'EOF'
Usage: ./deploy.sh [--env FILE] [--render-only DIR]

Deploys Ghost to a Hetzner Cloud server that has no open inbound ports.
The blog and SSH are reachable only through a Cloudflare Tunnel.

  --env FILE          config file (default: .env next to this script)
  --render-only DIR   write the server files and cloud-init user data to DIR, call no API
  -h, --help          show this help
EOF
}

random_secret() {
  local secret
  secret="$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9')"
  printf '%s' "${secret:0:${1:-32}}"
}

generate_secrets() {
  MYSQL_PASSWORD="$(random_secret 32)"
  MYSQL_ROOT_PASSWORD="$(random_secret 32)"
  GHOST_OWNER_PASSWORD="$(random_secret 24)"
}

validate_config() {
  [[ "$SSH_USER" =~ ^[a-z_][a-z0-9_-]*$ ]] || die "SSH_USER must be a valid Linux user name"
  [[ -f "$SSH_PUBLIC_KEY_FILE" ]] || die "SSH public key not found: $SSH_PUBLIC_KEY_FILE"
  ssh-keygen -lf "$SSH_PUBLIC_KEY_FILE" >/dev/null 2>&1 || die "not a valid SSH public key: $SSH_PUBLIC_KEY_FILE"
}

write_ghost_env() {
  local file="$1" name value
  : >"$file"
  [[ -n "${SMTP_HOST:-}" ]] || return 0
  for name in mail__transport mail__from mail__options__host mail__options__port \
    mail__options__secure mail__options__auth__user mail__options__auth__pass; do
    case "$name" in
      mail__transport) value="SMTP" ;;
      mail__from) value="${GHOST_MAIL_FROM:-$GHOST_OWNER_EMAIL}" ;;
      mail__options__host) value="$SMTP_HOST" ;;
      mail__options__port) value="${SMTP_PORT:-587}" ;;
      mail__options__secure) value="${SMTP_SECURE:-false}" ;;
      mail__options__auth__user) value="${SMTP_USER:-}" ;;
      mail__options__auth__pass) value="${SMTP_PASSWORD:-}" ;;
    esac
    [[ "$value" != *"'"* ]] || die "SMTP settings must not contain single quotes"
    printf "%s='%s'\n" "$name" "$value" >>"$file"
  done
}

render_server_files() {
  local dir="$1"
  mkdir -p "$dir"
  (
    umask 077
    cp "$SCRIPT_DIR/server/compose.yml" "$dir/compose.yml"
    cp "$SCRIPT_DIR/server/bootstrap.sh" "$dir/bootstrap.sh"
    printf 'GHOST_URL=https://%s\nMYSQL_PASSWORD=%s\nMYSQL_ROOT_PASSWORD=%s\n' \
      "$BLOG_HOSTNAME" "$MYSQL_PASSWORD" "$MYSQL_ROOT_PASSWORD" >"$dir/.env"
    write_ghost_env "$dir/ghost.env"
    {
      printf 'SSH_USER=%q\n' "$SSH_USER"
      printf 'BLOG_HOSTNAME=%q\n' "$BLOG_HOSTNAME"
      printf 'CF_TUNNEL_TOKEN=%q\n' "$TUNNEL_TOKEN"
      printf 'GHOST_OWNER_NAME=%q\n' "$GHOST_OWNER_NAME"
      printf 'GHOST_OWNER_EMAIL=%q\n' "$GHOST_OWNER_EMAIL"
      printf 'GHOST_OWNER_PASSWORD=%q\n' "$GHOST_OWNER_PASSWORD"
      printf 'GHOST_BLOG_TITLE=%q\n' "$GHOST_BLOG_TITLE"
    } >"$dir/bootstrap.env"
    build_user_data "$dir" >"$dir/user-data.yaml"
  )
}

b64() { base64 <"$1" | tr -d '\n'; }

write_file_entry() {
  local path="$1" permissions="$2" source="$3"
  printf '  - path: %s\n    permissions: "%s"\n    encoding: b64\n    content: "%s"\n' \
    "$path" "$permissions" "$(b64 "$source")"
}

build_user_data() {
  local dir="$1"
  cat <<EOF
#cloud-config
package_update: true
package_upgrade: true
packages:
  - docker.io
  - docker-compose-v2
  - ufw
  - jq
  - curl
  - unattended-upgrades
users:
  - name: $SSH_USER
    groups: [sudo]
    shell: /bin/bash
    sudo: "ALL=(ALL) NOPASSWD:ALL"
    lock_passwd: true
    ssh_authorized_keys:
      - $(jq -n --arg key "$(cat "$SSH_PUBLIC_KEY_FILE")" '$key')
disable_root: true
ssh_pwauth: false
write_files:
$(write_file_entry /opt/ghost/compose.yml 0644 "$dir/compose.yml")
$(write_file_entry /opt/ghost/.env 0600 "$dir/.env")
$(write_file_entry /opt/ghost/ghost.env 0600 "$dir/ghost.env")
$(write_file_entry /opt/ghost/bootstrap.env 0600 "$dir/bootstrap.env")
$(write_file_entry /opt/ghost/bootstrap.sh 0700 "$dir/bootstrap.sh")
runcmd:
  - [bash, /opt/ghost/bootstrap.sh]
EOF
}

check_server_type() {
  local types deprecated
  types="$(hcloud GET "/server_types?name=$(urlencode "$SERVER_TYPE")")"
  if [[ "$(jq '.server_types | length' <<<"$types")" == 0 ]]; then
    die "Hetzner server type $SERVER_TYPE does not exist; pick one from https://www.hetzner.com/cloud"
  fi
  deprecated="$(jq -r '.server_types[0].deprecation // empty' <<<"$types")"
  [[ -z "$deprecated" ]] || warn "Hetzner server type $SERVER_TYPE is deprecated"
}

ensure_tunnel() {
  TUNNEL_ID="$(find_tunnel_id)"
  if [[ -z "$TUNNEL_ID" ]]; then
    log "Creating Cloudflare Tunnel $TUNNEL_NAME"
    TUNNEL_ID="$(cf POST "/accounts/$CF_ACCOUNT_ID/cfd_tunnel" \
      "$(jq -n --arg name "$TUNNEL_NAME" '{name: $name, config_src: "cloudflare"}')" | jq -r '.result.id')"
  else
    log "Reusing Cloudflare Tunnel $TUNNEL_NAME ($TUNNEL_ID)"
  fi

  log "Routing $BLOG_HOSTNAME to Ghost and $SSH_HOSTNAME to sshd through the tunnel"
  cf PUT "/accounts/$CF_ACCOUNT_ID/cfd_tunnel/$TUNNEL_ID/configurations" "$(jq -n \
    --arg blog "$BLOG_HOSTNAME" --arg ssh "$SSH_HOSTNAME" \
    '{config: {ingress: [
      {hostname: $blog, service: "http://127.0.0.1:2368"},
      {hostname: $ssh, service: "ssh://127.0.0.1:22"},
      {service: "http_status:404"}
    ]}}')" >/dev/null
  TUNNEL_TOKEN="$(cf GET "/accounts/$CF_ACCOUNT_ID/cfd_tunnel/$TUNNEL_ID/token" | jq -r '.result')"
}

ensure_dns_record() {
  local host="$1" body record_id
  body="$(jq -n --arg name "$host" --arg content "$TUNNEL_ID.cfargotunnel.com" --arg comment "Managed by $MANAGED_BY" \
    '{type: "CNAME", name: $name, content: $content, proxied: true, comment: $comment}')"
  record_id="$(find_dns_record_id "$host")"
  if [[ -n "$record_id" ]]; then
    cf PUT "/zones/$CF_ZONE_ID/dns_records/$record_id" "$body" >/dev/null
  else
    cf POST "/zones/$CF_ZONE_ID/dns_records" "$body" >/dev/null
  fi
  log "DNS $host -> tunnel"
}

ensure_ssh_access_policy() {
  local app_id policy policy_id
  app_id="$(find_access_app_id)"
  if [[ -z "$app_id" ]]; then
    log "Creating Cloudflare Access application for $SSH_HOSTNAME"
    app_id="$(cf POST "/accounts/$CF_ACCOUNT_ID/access/apps" "$(jq -n \
      --arg name "$SERVER_NAME SSH" --arg domain "$SSH_HOSTNAME" \
      '{name: $name, domain: $domain, type: "self_hosted", session_duration: "24h", app_launcher_visible: false}')" |
      jq -r '.result.id')"
  fi

  policy="$(jq -n --arg emails "$ADMIN_EMAIL" '{
    name: "Allow admins",
    decision: "allow",
    include: [$emails | split(",")[] | gsub("^\\s+|\\s+$"; "") | select(length > 0) | {email: {email: .}}]
  }')"
  policy_id="$(cf GET "/accounts/$CF_ACCOUNT_ID/access/apps/$app_id/policies" | jq -r '.result[0].id // empty')"
  if [[ -n "$policy_id" ]]; then
    cf PUT "/accounts/$CF_ACCOUNT_ID/access/apps/$app_id/policies/$policy_id" "$policy" >/dev/null
  else
    cf POST "/accounts/$CF_ACCOUNT_ID/access/apps/$app_id/policies" "$policy" >/dev/null
  fi
  log "SSH through the tunnel requires a Cloudflare Access login as: $ADMIN_EMAIL"
}

ensure_ssh_key() {
  local fingerprint
  fingerprint="$(ssh-keygen -E md5 -lf "$SSH_PUBLIC_KEY_FILE" | awk '{print $2}')"
  fingerprint="${fingerprint#MD5:}"
  SSH_KEY_ID="$(hcloud GET "/ssh_keys?fingerprint=$(urlencode "$fingerprint")" | jq -r '.ssh_keys[0].id // empty')"
  if [[ -z "$SSH_KEY_ID" ]]; then
    log "Uploading SSH public key to Hetzner"
    SSH_KEY_ID="$(hcloud POST /ssh_keys "$(jq -n \
      --arg name "$SERVER_NAME-${fingerprint//:/}" --arg key "$(cat "$SSH_PUBLIC_KEY_FILE")" --arg managed "$MANAGED_BY" \
      '{name: $name, public_key: $key, labels: {"managed-by": $managed}}')" | jq -r '.ssh_key.id')"
  fi
}

ensure_firewall() {
  local name="$SERVER_NAME-deny-inbound"
  FIREWALL_ID="$(hcloud GET "/firewalls?name=$(urlencode "$name")" | jq -r '.firewalls[0].id // empty')"
  if [[ -z "$FIREWALL_ID" ]]; then
    log "Creating Hetzner firewall $name"
    FIREWALL_ID="$(hcloud POST /firewalls "$(jq -n --arg name "$name" --arg managed "$MANAGED_BY" \
      '{name: $name, labels: {"managed-by": $managed}, rules: []}')" | jq -r '.firewall.id')"
  fi
  # No rules means every inbound packet is dropped; re-applied on each run in case rules were added by hand
  hcloud POST "/firewalls/$FIREWALL_ID/actions/set_rules" '{"rules": []}' >/dev/null
  log "Hetzner firewall $name allows no inbound traffic"
}

ensure_server() {
  local server attached render_dir body
  SERVER_ID="$(find_server_id)"
  SERVER_CREATED=false
  if [[ -n "$SERVER_ID" ]]; then
    warn "Server $SERVER_NAME already exists; cloud-init only runs on first boot, so server files are not changed"
    server="$(hcloud GET "/servers/$SERVER_ID")"
    attached="$(jq --argjson fw "$FIREWALL_ID" '[.server.public_net.firewalls[]? | select(.id == $fw)] | length' <<<"$server")"
    if [[ "$attached" == 0 ]]; then
      hcloud POST "/firewalls/$FIREWALL_ID/actions/apply_to_resources" \
        "$(jq -n --argjson id "$SERVER_ID" '{apply_to: [{type: "server", server: {id: $id}}]}')" >/dev/null
      log "Attached firewall to existing server"
    fi
    return
  fi

  generate_secrets
  render_dir="$(mktemp -d)"
  render_server_files "$render_dir"
  if (($(wc -c <"$render_dir/user-data.yaml") > 32768)); then
    rm -rf "$render_dir"
    die "cloud-init user data exceeds Hetzner's 32 KiB limit"
  fi

  body="$(jq -n \
    --arg name "$SERVER_NAME" --arg type "$SERVER_TYPE" --arg location "$SERVER_LOCATION" --arg image "$SERVER_IMAGE" \
    --argjson ssh_key "$SSH_KEY_ID" --argjson firewall "$FIREWALL_ID" --arg managed "$MANAGED_BY" \
    --rawfile user_data "$render_dir/user-data.yaml" \
    '{name: $name, server_type: $type, location: $location, image: $image,
      ssh_keys: [$ssh_key], firewalls: [{firewall: $firewall}], user_data: $user_data,
      labels: {"managed-by": $managed}, public_net: {enable_ipv4: true, enable_ipv6: true},
      start_after_create: true}')"
  rm -rf "$render_dir"

  log "Creating Hetzner server $SERVER_NAME ($SERVER_TYPE in $SERVER_LOCATION)"
  SERVER_ID="$(hcloud POST /servers "$body" | jq -r '.server.id')"
  SERVER_CREATED=true
  save_credentials
}

save_credentials() {
  CREDENTIALS_FILE="$STATE_DIR/$SERVER_NAME-credentials.txt"
  mkdir -p "$STATE_DIR"
  chmod 700 "$STATE_DIR"
  (
    umask 077
    printf 'Ghost admin: https://%s/ghost/\nEmail: %s\nPassword: %s\n' \
      "$BLOG_HOSTNAME" "$GHOST_OWNER_EMAIL" "$GHOST_OWNER_PASSWORD" >"$CREDENTIALS_FILE"
  )
}

wait_until() {
  local description="$1" deadline=$((SECONDS + DEPLOY_TIMEOUT))
  shift
  log "Waiting for $description"
  until "$@"; do
    ((SECONDS < deadline)) || return 1
    sleep "$POLL_INTERVAL"
  done
}

server_is_running() { [[ "$(hcloud GET "/servers/$SERVER_ID" | jq -r '.server.status')" == running ]]; }
tunnel_is_healthy() { [[ "$(cf GET "/accounts/$CF_ACCOUNT_ID/cfd_tunnel/$TUNNEL_ID" | jq -r '.result.status')" == healthy ]]; }
blog_is_up() { [[ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$BLOG_HEALTHCHECK_URL")" == 200 ]]; }

wait_for_deployment() {
  local hint="SSH in with ./ssh.sh and check /var/log/cloud-init-output.log"
  wait_until "the server to boot" server_is_running || die "server did not reach the running state"
  wait_until "the server to connect to the tunnel" tunnel_is_healthy || die "tunnel never became healthy. $hint"
  wait_until "Ghost to answer at https://$BLOG_HOSTNAME" blog_is_up || die "Ghost is not reachable through the tunnel. $hint"
}

print_summary() {
  cat <<EOF

Ghost is live.
  Blog:   https://$BLOG_HOSTNAME
  Admin:  https://$BLOG_HOSTNAME/ghost/
  SSH:    ./ssh.sh   (Cloudflare Access login as $ADMIN_EMAIL, then key-based login as $SSH_USER)
EOF
  if [[ "$SERVER_CREATED" == true ]]; then
    cat <<EOF

Ghost owner account (saved to $CREDENTIALS_FILE, change the password after first login):
  Email:    $GHOST_OWNER_EMAIL
  Password: $GHOST_OWNER_PASSWORD
EOF
  fi
}

main() {
  local env_file="$SCRIPT_DIR/.env" render_only=""
  while (($#)); do
    case "$1" in
      --env)
        env_file="${2:?--env needs a file}"
        shift 2
        ;;
      --render-only)
        render_only="${2:?--render-only needs a directory}"
        shift 2
        ;;
      -h | --help)
        usage
        exit 0
        ;;
      *) die "unknown argument: $1 (see --help)" ;;
    esac
  done

  require_commands curl jq openssl ssh-keygen base64
  load_config "$env_file"
  require_vars CF_ZONE ADMIN_EMAIL
  validate_config
  STATE_DIR="${STATE_DIR:-$SCRIPT_DIR/.state}"
  BLOG_HEALTHCHECK_URL="${BLOG_HEALTHCHECK_URL:-https://$BLOG_HOSTNAME/ghost/api/admin/site/}"

  if [[ -n "$render_only" ]]; then
    TUNNEL_TOKEN="${TUNNEL_TOKEN:-render-only-placeholder}"
    generate_secrets
    render_server_files "$render_only"
    log "Server files written to $render_only"
    return
  fi

  require_vars HCLOUD_TOKEN CF_API_TOKEN
  setup_auth_headers
  check_server_type
  resolve_zone
  ensure_tunnel
  ensure_dns_record "$BLOG_HOSTNAME"
  ensure_dns_record "$SSH_HOSTNAME"
  ensure_ssh_access_policy
  ensure_ssh_key
  ensure_firewall
  ensure_server
  wait_for_deployment
  print_summary
}

main "$@"
