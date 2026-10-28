#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

usage() {
  cat <<'EOF'
Usage: ./destroy.sh [--env FILE] [--yes]

Deletes everything deploy.sh created: the server and its data, the firewall, the uploaded SSH key,
the Cloudflare Tunnel, its DNS records and the Access application.

  --env FILE   config file (default: .env next to this script)
  --yes        skip the confirmation prompt
EOF
}

confirm() {
  local answer
  printf 'This permanently deletes server %s and all blog data.\nType the server name to confirm: ' "$SERVER_NAME" >&2
  read -r answer || true
  [[ "$answer" == "$SERVER_NAME" ]] || die "aborted, nothing was deleted"
}

retry_delete() {
  local description="$1" api="$2" path="$3" attempt status
  for attempt in 1 2 3 4 5 6 7 8 9 10; do
    status="$("$api" DELETE "$path")"
    [[ "$status" == 2* || "$status" == 404 ]] && return 0
    sleep "$POLL_INTERVAL"
  done
  warn "could not delete $description (last HTTP status $status, $attempt attempts)"
}

delete_server() {
  local server_id
  server_id="$(find_server_id)"
  if [[ -z "$server_id" ]]; then
    log "No server named $SERVER_NAME"
    return
  fi
  log "Deleting server $SERVER_NAME"
  hcloud DELETE "/servers/$server_id" >/dev/null
  local deadline=$((SECONDS + DEPLOY_TIMEOUT))
  while [[ -n "$(find_server_id)" ]]; do
    ((SECONDS < deadline)) || die "server $SERVER_NAME is still being deleted; run destroy.sh again later"
    sleep "$POLL_INTERVAL"
  done
}

delete_hetzner_resources() {
  local firewall_id key_ids key_id
  firewall_id="$(hcloud GET "/firewalls?name=$(urlencode "$SERVER_NAME-deny-inbound")" | jq -r '.firewalls[0].id // empty')"
  if [[ -n "$firewall_id" ]]; then
    log "Deleting firewall"
    retry_delete "firewall $firewall_id" hcloud_status "/firewalls/$firewall_id"
  fi

  key_ids="$(hcloud GET "/ssh_keys?label_selector=$(urlencode "managed-by=$MANAGED_BY")" |
    jq -r --arg prefix "$SERVER_NAME-" '.ssh_keys[] | select(.name | startswith($prefix)) | .id')"
  for key_id in $key_ids; do
    log "Deleting uploaded SSH key $key_id"
    hcloud DELETE "/ssh_keys/$key_id" >/dev/null
  done
}

delete_cloudflare_resources() {
  local tunnel_id app_id host record
  resolve_zone

  for host in "$BLOG_HOSTNAME" "$SSH_HOSTNAME"; do
    record="$(cf GET "/zones/$CF_ZONE_ID/dns_records?type=CNAME&name=$(urlencode "$host")" |
      jq -c --arg comment "Managed by $MANAGED_BY" '[.result[] | select(.comment == $comment)][0] // empty')"
    if [[ -n "$record" ]]; then
      log "Deleting DNS record $host"
      cf DELETE "/zones/$CF_ZONE_ID/dns_records/$(jq -r '.id' <<<"$record")" >/dev/null
    fi
  done

  app_id="$(find_access_app_id)"
  if [[ -n "$app_id" ]]; then
    log "Deleting Access application for $SSH_HOSTNAME"
    cf DELETE "/accounts/$CF_ACCOUNT_ID/access/apps/$app_id" >/dev/null
  fi

  tunnel_id="$(find_tunnel_id)"
  if [[ -n "$tunnel_id" ]]; then
    log "Deleting Cloudflare Tunnel $TUNNEL_NAME"
    cf_status DELETE "/accounts/$CF_ACCOUNT_ID/cfd_tunnel/$tunnel_id/connections" >/dev/null
    retry_delete "tunnel $tunnel_id" cf_status "/accounts/$CF_ACCOUNT_ID/cfd_tunnel/$tunnel_id"
  fi
}

main() {
  local env_file="$SCRIPT_DIR/.env" assume_yes=false
  while (($#)); do
    case "$1" in
      --env)
        env_file="${2:?--env needs a file}"
        shift 2
        ;;
      --yes)
        assume_yes=true
        shift
        ;;
      -h | --help)
        usage
        exit 0
        ;;
      *) die "unknown argument: $1 (see --help)" ;;
    esac
  done

  require_commands curl jq
  load_config "$env_file"
  require_vars HCLOUD_TOKEN CF_API_TOKEN CF_ZONE
  [[ "$assume_yes" == true ]] || confirm
  setup_auth_headers

  delete_server
  delete_hetzner_resources
  delete_cloudflare_resources
  rm -f "${STATE_DIR:-$SCRIPT_DIR/.state}/$SERVER_NAME-credentials.txt"
  log "Everything for $SERVER_NAME is gone"
}

main "$@"
