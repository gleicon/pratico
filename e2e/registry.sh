#!/usr/bin/env bash
# TEST HARNESS ONLY — not part of pratico's setup and not run by `make e2e`.
#
# Verifies private-registry pull and push (SPEC AC-9, AC-25, AC-50) without a real
# private account.
# It starts a throwaway password-protected `registry:2` on 127.0.0.1 in the daemon under
# test, seeds it with busybox, then drives `docker login` + `docker pull` through that
# daemon. Everything it creates goes on exit: the daemon's home (registry, images) and the
# Keychain login it kept.
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
for tool in "$DOCKER" htpasswd openssl curl; do
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
# pratico keeps `docker login` in its Keychain items; this is its own logout.
logout() { curl -s -o /dev/null --unix-socket "$HOME_DIR/docker.sock" -X DELETE "http://d/pratico/registries/logins/$REG"; }
pass=0
fail=0
ok() { echo "ok   $1"; pass=$((pass + 1)); }
bad() { echo "FAIL $1${2:+ — $2}"; fail=$((fail + 1)); }

cleanup() {
    logout
    ids=$(docker ps -aq 2>/dev/null)
    [ -n "$ids" ] && docker rm -f $ids >/dev/null 2>&1
    [ -n "$DAEMON_PID" ] && kill "$DAEMON_PID" 2>/dev/null && wait "$DAEMON_PID" 2>/dev/null
    rm -rf "$WORK"
}
trap cleanup EXIT

# registry:2 is old and carries known CVEs: with scanning on, a serious finding would stop
# the registry mid-run (scan_block). Registry trust is what this harness checks.
printf 'scan = false\n' >"$HOME_DIR/config.toml"
"$BIN/pratico-daemon" --home "$HOME_DIR" >>"$WORK/daemon.log" 2>&1 &
DAEMON_PID=$!
for _ in $(seq 50); do [ -S "$HOME_DIR/docker.sock" ] && break; sleep 0.1; done

# --- Throwaway registry in the daemon under test, seeded, then logged out ------------
htpasswd -Bbn "$USER_NAME" "$PASSWORD" >"$WORK/auth/htpasswd"
docker run -d --name "$REG_NAME" -p "$REG:5000" -v "$WORK/auth:/auth" \
    -e REGISTRY_AUTH=htpasswd -e REGISTRY_AUTH_HTPASSWD_REALM=pratico-e2e \
    -e REGISTRY_AUTH_HTPASSWD_PATH=/auth/htpasswd registry:2 >/dev/null 2>&1 ||
    { echo "cannot start registry:2"; exit 1; }
for _ in $(seq 100); do
    [ "$(curl -s -o /dev/null -w '%{http_code}' "http://$REG/v2/")" = 401 ] && break
    sleep 0.2
done
docker pull -q busybox >/dev/null 2>&1
echo "$PASSWORD" | docker login "$REG" -u "$USER_NAME" --password-stdin >/dev/null 2>&1 &&
    docker tag busybox "$IMAGE" >/dev/null &&
    docker push "$IMAGE" >/dev/null 2>&1 ||
    { echo "cannot seed $IMAGE"; exit 1; }
docker rmi "$IMAGE" >/dev/null 2>&1
logout
rm -f "$DOCKER_CONFIG/config.json" && echo '{"auths":{"pratico.invalid":{}}}' >"$DOCKER_CONFIG/config.json"

# --- Checks ----------------------------------------------------------------------
if docker pull "$IMAGE" >/dev/null 2>&1; then bad "pull without login is refused"; else ok "pull without login is refused"; fi
if echo wrong | docker login "$REG" -u "$USER_NAME" --password-stdin >/dev/null 2>&1; then
    bad "docker login with a wrong password fails"
else
    ok "docker login with a wrong password fails"
fi
out=$(echo "$PASSWORD" | docker login "$REG" -u "$USER_NAME" --password-stdin 2>&1)
if grep -q "Login Succeeded" <<<"$out"; then ok "docker login succeeds"; else bad "docker login succeeds" "$out"; fi
# Drop the login pratico kept, so the pull must use the header the CLI forwards.
logout
out=$(docker pull "$IMAGE" 2>&1)
if [ $? -eq 0 ]; then ok "AC-9 docker pull of a private image succeeds"; else bad "AC-9 docker pull of a private image succeeds" "$out"; fi
# grep exits 1 for "no match"; anything else (match or error) fails the check.
grep -rqF -D skip "$PASSWORD" "$HOME_DIR"
rc=$?
if [ "$rc" -eq 1 ]; then ok "AC-50 password not stored under the pratico home"; else bad "AC-50 password not stored under the pratico home" "grep exit $rc"; fi

# AC-25: push, then a fresh pull returns the same digest.
logout
docker tag busybox "$PUSHED" >/dev/null 2>&1
out=$(docker push "$PUSHED" 2>&1)
pushed_digest=$(grep -oE 'digest: sha256:[0-9a-f]{64}' <<<"$out" | head -1 | cut -d' ' -f2)
if [ -n "$pushed_digest" ]; then ok "AC-25 docker push reports a digest"; else bad "AC-25 docker push reports a digest" "$out"; fi
docker rmi "$PUSHED" >/dev/null 2>&1
logout
docker pull "$PUSHED" >/dev/null 2>&1
# The same image is also busybox from Docker Hub here: read the pushed repository's digest.
pulled_digest=$(docker image inspect "$PUSHED" --format '{{range .RepoDigests}}{{println .}}{{end}}' 2>/dev/null |
    grep -F "$REG/pratico-e2e/pushed@" | cut -d@ -f2)
if [ -n "$pushed_digest" ] && [ "$pulled_digest" = "$pushed_digest" ]; then
    ok "AC-25 fresh pull returns the pushed digest"
else
    bad "AC-25 fresh pull returns the pushed digest" "pushed [$pushed_digest] pulled [$pulled_digest]"
fi
out=$(docker push "$REG/pratico-e2e/missing:1" 2>&1)
if grep -q "does not exist locally" <<<"$out"; then ok "push of a missing image is refused"; else bad "push of a missing image is refused" "$out"; fi

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ] || { echo "--- daemon log"; tail -20 "$WORK/daemon.log"; exit 1; }
