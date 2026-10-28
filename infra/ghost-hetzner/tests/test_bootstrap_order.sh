#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# shellcheck source=SCRIPTDIR/../server/bootstrap.sh
source "$ROOT/server/bootstrap.sh"
export GHOST_DIR="$WORK"

record() { echo "$*" >>"$WORK/calls"; }
lock_down_ssh() { record ssh; }
enable_host_firewall() { record firewall; }
block_metadata_for_containers() { record metadata; }
install_tunnel() { record tunnel; }
docker() { record "docker $*"; }
shred() { record "shred $*"; }

run_scenario() {
  local name="$1" ghost_result="$2" owner_result="$3" expected="$4" actual
  : >"$WORK/calls"
  printf 'SSH_USER=admin\n' >"$WORK/bootstrap.env"
  (
    # shellcheck disable=SC2317
    start_ghost() {
      record start
      return "$ghost_result"
    }
    # shellcheck disable=SC2317
    setup_owner() {
      record owner
      return "$owner_result"
    }
    main >/dev/null
  )
  actual="$(paste -sd ',' "$WORK/calls")"
  if [[ "$actual" != "$expected" ]]; then
    printf 'FAIL %s\n  expected: %s\n  actual:   %s\n' "$name" "$expected" "$actual" >&2
    exit 1
  fi
  printf 'PASS %s\n' "$name"
}

run_scenario "tunnel opens only after the owner exists" 0 0 \
  "ssh,firewall,metadata,start,owner,tunnel,shred -u $WORK/bootstrap.env"
run_scenario "Ghost failing to start is stopped before the tunnel opens" 1 0 \
  "ssh,firewall,metadata,start,docker compose stop ghost,tunnel,shred -u $WORK/bootstrap.env"
run_scenario "failed owner setup keeps the owner-less Ghost offline" 0 1 \
  "ssh,firewall,metadata,start,owner,docker compose stop ghost,tunnel,shred -u $WORK/bootstrap.env"
