#!/usr/bin/env bash
set -euo pipefail

GHOST_DIR="${GHOST_DIR:-/opt/ghost}"
GHOST_LOCAL_URL="${GHOST_LOCAL_URL:-http://127.0.0.1:2368}"
GHOST_READY_TIMEOUT="${GHOST_READY_TIMEOUT:-600}"

log() { echo "[bootstrap] $*"; }

lock_down_ssh() {
  cat >/etc/ssh/sshd_config.d/10-tunnel-only.conf <<'EOF'
ListenAddress 127.0.0.1
ListenAddress ::1
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
EOF
  mkdir -p /run/sshd
  sshd -t
  # Ubuntu's ssh.socket listens on 0.0.0.0:22 and ignores ListenAddress, so use the plain service
  systemctl disable --now ssh.socket 2>/dev/null || true
  systemctl enable ssh.service
  systemctl restart ssh.service
  log "sshd now listens on loopback only"
}

enable_host_firewall() {
  ufw default deny incoming
  ufw default allow outgoing
  ufw --force enable
  log "ufw enabled with no inbound rules"
}

# User data holds the tunnel token and owner password; containers must not read it from the metadata service
block_metadata_for_containers() {
  cat >/etc/systemd/system/docker-block-metadata.service <<'EOF'
[Unit]
Description=Block the cloud metadata service for Docker containers
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'iptables -C DOCKER-USER -d 169.254.169.254/32 -j DROP 2>/dev/null || iptables -I DOCKER-USER -d 169.254.169.254/32 -j DROP'

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now docker-block-metadata.service
}

ghost_request() {
  curl -s -H "Host: $BLOG_HOSTNAME" -H "X-Forwarded-Proto: https" -H "Content-Type: application/json" "$@"
}

wait_for_ghost() {
  local deadline=$((SECONDS + GHOST_READY_TIMEOUT))
  until [[ "$(ghost_request -o /dev/null -w '%{http_code}' "$GHOST_LOCAL_URL/ghost/api/admin/site/")" == 200 ]]; do
    if ((SECONDS >= deadline)); then
      log "Ghost did not become ready within ${GHOST_READY_TIMEOUT}s"
      return 1
    fi
    sleep 5
  done
  log "Ghost is ready"
}

start_ghost() {
  usermod -aG docker "$SSH_USER" || return 1
  (cd "$GHOST_DIR" && docker compose up -d) || return 1
  wait_for_ghost
}

setup_owner() {
  local setup_url="$GHOST_LOCAL_URL/ghost/api/admin/authentication/setup/"
  local status body code
  status="$(ghost_request "$setup_url" | jq -r '.setup[0].status')" || return 1
  if [[ "$status" == "true" ]]; then
    log "Ghost owner already exists"
    return 0
  fi
  body="$(jq -n \
    --arg name "$GHOST_OWNER_NAME" \
    --arg email "$GHOST_OWNER_EMAIL" \
    --arg password "$GHOST_OWNER_PASSWORD" \
    --arg title "$GHOST_BLOG_TITLE" \
    '{setup: [{name: $name, email: $email, password: $password, blogTitle: $title}]}')"
  code="$(ghost_request -o /dev/null -w '%{http_code}' -X POST --data-binary @- "$setup_url" <<<"$body")"
  if [[ "$code" != 2* ]]; then
    log "Ghost owner setup failed with HTTP $code"
    return 1
  fi
  log "Ghost owner $GHOST_OWNER_EMAIL created"
}

install_tunnel() {
  install -d -m 0755 /usr/share/keyrings /etc/cloudflared
  curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg -o /usr/share/keyrings/cloudflare-main.gpg
  echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main" \
    >/etc/apt/sources.list.d/cloudflared.list
  apt-get update -q
  apt-get install -y -q cloudflared

  # Token lives in a root-only env file instead of the world-readable unit file `cloudflared service install` writes
  install -m 600 /dev/null /etc/cloudflared/tunnel.env
  printf 'TUNNEL_TOKEN=%s\n' "$CF_TUNNEL_TOKEN" >/etc/cloudflared/tunnel.env
  cat >/etc/systemd/system/cloudflared.service <<'EOF'
[Unit]
Description=Cloudflare Tunnel
After=network-online.target
Wants=network-online.target

[Service]
EnvironmentFile=/etc/cloudflared/tunnel.env
ExecStart=/usr/bin/cloudflared --no-autoupdate tunnel run
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now cloudflared.service
  log "Cloudflare Tunnel started"
}

main() {
  trap 'shred -u "$GHOST_DIR/bootstrap.env" 2>/dev/null || true' EXIT
  # shellcheck disable=SC1091
  source "$GHOST_DIR/bootstrap.env"

  lock_down_ssh
  enable_host_firewall
  block_metadata_for_containers

  if start_ghost && setup_owner; then
    log "Ghost is running with an owner account"
  else
    # An owner-less Ghost can be claimed by whoever opens /ghost first, so keep it offline
    log "Ghost bootstrap failed; stopping Ghost and opening the tunnel for SSH debugging only"
    (cd "$GHOST_DIR" && docker compose stop ghost) || true
  fi

  install_tunnel
  touch "$GHOST_DIR/.bootstrap-complete"
  log "done"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
