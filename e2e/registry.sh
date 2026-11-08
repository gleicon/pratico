#!/usr/bin/env bash
# TEST HARNESS ONLY — not part of pratico's setup and not run by `make e2e`.
#
# Verifies private-registry pull and push (SPEC AC-9, AC-25, AC-50) without a real
# private account.
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
PUSHED="$REG/pratico-e2e/pushed:1"
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
# With no auth settings the CLI would fall back to the macOS Keychain helper.
echo '{"auths":{"pratico.invalid":{}}}' >"$DOCKER_CONFIG/config.json"
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
    container image delete "$IMAGE" "$PUSHED" >/dev/null 2>&1
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

# AC-25: push, then a fresh pull returns the same digest.
container registry logout "$REG" >/dev/null 2>&1
docker tag busybox "$PUSHED" >/dev/null 2>&1
out=$(docker push "$PUSHED" 2>&1)
pushed_digest=$(grep -oE 'digest: sha256:[0-9a-f]{64}' <<<"$out" | head -1 | cut -d' ' -f2)
if [ -n "$pushed_digest" ]; then ok "AC-25 docker push reports a digest"; else bad "AC-25 docker push reports a digest" "$out"; fi
docker rmi "$PUSHED" >/dev/null 2>&1
container registry logout "$REG" >/dev/null 2>&1
docker pull "$PUSHED" >/dev/null 2>&1
pulled_digest=$(docker image inspect "$PUSHED" --format '{{index .RepoDigests 0}}' 2>/dev/null | cut -d@ -f2)
if [ -n "$pushed_digest" ] && [ "$pulled_digest" = "$pushed_digest" ]; then
    ok "AC-25 fresh pull returns the pushed digest"
else
    bad "AC-25 fresh pull returns the pushed digest" "pushed [$pushed_digest] pulled [$pulled_digest]"
fi
out=$(docker push "$REG/pratico-e2e/missing:1" 2>&1)
if grep -q "does not exist locally" <<<"$out"; then ok "push of a missing image is refused"; else bad "push of a missing image is refused" "$out"; fi

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ] || { echo "--- daemon log"; tail -20 "$WORK/daemon.log"; exit 1; }
