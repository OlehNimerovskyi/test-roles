#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
PROJECT="ghost-stack-test"
export GHOST_DIR="$WORK/server"

cleanup() {
  (cd "$GHOST_DIR" 2>/dev/null && docker compose -p "$PROJECT" down -v >/dev/null 2>&1) || true
  rm -rf "$WORK"
}
trap cleanup EXIT

pass() { printf 'PASS %s\n' "$*"; }
fail() {
  printf 'FAIL %s\n' "$*" >&2
  exit 1
}

ssh-keygen -q -t ed25519 -N "" -C "ci@example.test" -f "$WORK/id"
cat >"$WORK/test.env" <<EOF
CF_ZONE=example.test
ADMIN_EMAIL=owner@example.test
SSH_PUBLIC_KEY_FILE=$WORK/id.pub
GHOST_BLOG_TITLE="Stack Test Blog"
EOF
"$ROOT/deploy.sh" --env "$WORK/test.env" --render-only "$GHOST_DIR" 2>/dev/null

(cd "$GHOST_DIR" && COMPOSE_PROJECT_NAME="$PROJECT" docker compose up -d --quiet-pull 2>/dev/null)

# shellcheck disable=SC1091
source "$GHOST_DIR/bootstrap.env"
# shellcheck source=SCRIPTDIR/../server/bootstrap.sh
source "$ROOT/server/bootstrap.sh"
set +e

wait_for_ghost >/dev/null || fail "Ghost did not become ready"
pass "Ghost answers through the same Host and X-Forwarded-Proto headers cloudflared sends"

[[ "$(ghost_request "$GHOST_LOCAL_URL/ghost/api/admin/authentication/setup/" | jq -r '.setup[0].status')" == false ]] ||
  fail "fresh Ghost should not have an owner yet"
setup_owner >/dev/null || fail "owner setup failed"
[[ "$(ghost_request "$GHOST_LOCAL_URL/ghost/api/admin/authentication/setup/" | jq -r '.setup[0].status')" == true ]] ||
  fail "owner was not created"
pass "setup_owner creates the owner before the blog is exposed"

setup_owner | grep -q "already exists" || fail "second setup_owner run should be a no-op"
pass "setup_owner is idempotent"

login_code() {
  ghost_request -o /dev/null -w '%{http_code}' -X POST -H "Origin: https://$BLOG_HOSTNAME" --data-binary @- \
    "$GHOST_LOCAL_URL/ghost/api/admin/session/" <<<"$(jq -n --arg user "$GHOST_OWNER_EMAIL" --arg pass "$1" \
      '{username: $user, password: $pass}')"
}
[[ "$(login_code "$GHOST_OWNER_PASSWORD")" == 201 ]] || fail "owner cannot log in with the generated password"
[[ "$(login_code "not-the-password-1")" != 201 ]] || fail "wrong password was accepted"
pass "owner logs in with the generated password, a wrong password is rejected"

ghost_request "$GHOST_LOCAL_URL/" | grep -q "Stack Test Blog" || fail "home page does not show the blog title"
pass "home page renders with the configured blog title"

published_ports() {
  docker compose -p "$PROJECT" ps --format json "$1" |
    jq -s 'flatten | [.[].Publishers[]? | select(.PublishedPort > 0)] | length'
}
cd "$GHOST_DIR"
[[ "$(docker compose -p "$PROJECT" port ghost 2368)" == "127.0.0.1:2368" ]] || fail "Ghost is not bound to loopback only"
[[ "$(published_ports ghost)" == 1 ]] || fail "expected exactly one published Ghost port"
[[ "$(published_ports db)" == 0 ]] || fail "MySQL must not be published on the host"
pass "Ghost is published on 127.0.0.1 only and MySQL is not published at all"
