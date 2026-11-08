#!/usr/bin/env bash
# TEST HARNESS ONLY — not part of pratico's setup and not run by `make e2e`.
#
# Verifies private-registry pulls (SPEC AC-9, AC-50) without a real private account.
# It starts a throwaway password-protected `registry:2` on 127.0.0.1, seeds it with
# busybox, then drives `docker login` + `docker pull` through pratico-daemon. Everything
# it creates is removed on exit: the registry container, the pushed image, the Keychain
# login, and registry:2/busybox if this script pulled them.
#
# Usage: e2e/registry.sh <bin-dir>    (or: make e2e-registry)
set -uo pipefail

BIN="${1:?usage: e2e/registry.sh <bin-dir>}"
DOCKER="${DOCKER:-/opt/homebrew/bin/docker}"
PORT="${REG_PORT:-15000}"
REG="127.0.0.1:$PORT"
IMAGE="$REG/pratico-e2e/bb:1"
USER_NAME=e2euser
PASSWORD="e2e-$(openssl rand -hex 8)"
for tool in "$DOCKER" container htpasswd openssl; do
    command -v "$tool" >/dev/null || { echo "registry harness needs $tool"; exit 1; }
done
docker() { "$DOCKER" "$@"; }

WORK="$(mktemp -d -t pratico-reg)"
HOME_DIR="$WORK/home"
mkdir -p "$HOME_DIR" "$WORK/auth" "$WORK/docker-config"
export DOCKER_HOST="unix://$HOME_DIR/docker.sock"
export DOCKER_CONFIG="$WORK/docker-config"  # keeps the CLI's login out of ~/.docker
REG_NAME="pratico-e2e-registry-$$"
DAEMON_PID=""
had_registry=0; container image inspect registry:2 >/dev/null 2>&1 && had_registry=1
had_busybox=0; container image inspect busybox >/dev/null 2>&1 && had_busybox=1

pass=0
fail=0
ok() { echo "ok   $1"; pass=$((pass + 1)); }
bad() { echo "FAIL $1${2:+ — $2}"; fail=$((fail + 1)); }

cleanup() {
    [ -n "$DAEMON_PID" ] && kill "$DAEMON_PID" 2>/dev/null && wait "$DAEMON_PID" 2>/dev/null
    container rm -f "$REG_NAME" >/dev/null 2>&1
    container image delete "$IMAGE" >/dev/null 2>&1
    container registry logout "$REG" >/dev/null 2>&1
    [ "$had_registry" = 0 ] && container image delete registry:2 >/dev/null 2>&1
    [ "$had_busybox" = 0 ] && container image delete busybox >/dev/null 2>&1
    rm -rf "$WORK"
}
trap cleanup EXIT

# --- Throwaway registry, seeded through Apple's CLI, then logged out ----------
htpasswd -Bbn "$USER_NAME" "$PASSWORD" >"$WORK/auth/htpasswd"
container run -d --name "$REG_NAME" -p "$REG:5000" -v "$WORK/auth:/auth" \
    -e REGISTRY_AUTH=htpasswd -e REGISTRY_AUTH_HTPASSWD_REALM=pratico-e2e \
    -e REGISTRY_AUTH_HTPASSWD_PATH=/auth/htpasswd registry:2 >/dev/null 2>&1 ||
    { echo "cannot start registry:2"; exit 1; }
for _ in $(seq 50); do
    [ "$(curl -s -o /dev/null -w '%{http_code}' "http://$REG/v2/")" = 401 ] && break
    sleep 0.2
done
container image pull busybox >/dev/null 2>&1
echo "$PASSWORD" | container registry login --scheme http -u "$USER_NAME" --password-stdin "$REG" >/dev/null 2>&1 &&
    container image tag busybox "$IMAGE" >/dev/null &&
    container image push --scheme http "$IMAGE" >/dev/null 2>&1 ||
    { echo "cannot seed $IMAGE"; exit 1; }
container image delete "$IMAGE" >/dev/null 2>&1
container registry logout "$REG" >/dev/null 2>&1

"$BIN/pratico-daemon" --home "$HOME_DIR" >>"$WORK/daemon.log" 2>&1 &
DAEMON_PID=$!
for _ in $(seq 50); do [ -S "$HOME_DIR/docker.sock" ] && break; sleep 0.1; done

# --- Checks ----------------------------------------------------------------------
if docker pull "$IMAGE" >/dev/null 2>&1; then bad "pull without login is refused"; else ok "pull without login is refused"; fi
if echo wrong | docker login "$REG" -u "$USER_NAME" --password-stdin >/dev/null 2>&1; then
    bad "docker login with a wrong password fails"
else
    ok "docker login with a wrong password fails"
fi
out=$(echo "$PASSWORD" | docker login "$REG" -u "$USER_NAME" --password-stdin 2>&1)
if grep -q "Login Succeeded" <<<"$out"; then ok "docker login succeeds"; else bad "docker login succeeds" "$out"; fi
# Drop the Keychain entry /auth created, so the pull must use the forwarded header.
container registry logout "$REG" >/dev/null 2>&1
out=$(docker pull "$IMAGE" 2>&1)
if [ $? -eq 0 ]; then ok "AC-9 docker pull of a private image succeeds"; else bad "AC-9 docker pull of a private image succeeds" "$out"; fi
# grep exits 1 for "no match"; anything else (match or error) fails the check.
grep -rqF -D skip "$PASSWORD" "$HOME_DIR"
rc=$?
if [ "$rc" -eq 1 ]; then ok "AC-50 password not stored under the pratico home"; else bad "AC-50 password not stored under the pratico home" "grep exit $rc"; fi

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ] || { echo "--- daemon log"; tail -20 "$WORK/daemon.log"; exit 1; }
