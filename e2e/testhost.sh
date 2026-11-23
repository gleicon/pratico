#!/usr/bin/env bash
# Remote hosts on the Mac (docs/design/remote.md): boots the Linux test host, an Ubuntu
# container with KVM and systemd (`--runtime pratico-testhost`, nested virtualization) on a
# throwaway daemon. Its user `dev` installs the release payload (scripts/host-payload.sh)
# as a VPS's user would, `sudo pratico-daemon install`, and the Mac's docker CLI drives the
# service over `ssh://dev@`; then an upgrade, which keeps containers, and the uninstall.
# Usage: e2e/testhost.sh <bin-dir>    (TESTHOST_KEEP=1 leaves it running, to work on it)
set -uo pipefail

BIN="${1:?usage: e2e/testhost.sh <bin-dir>}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DOCKER="${DOCKER:-/opt/homebrew/bin/docker}"
[ -x "$DOCKER" ] || { echo "testhost needs the docker CLI at $DOCKER"; exit 1; }
docker() { "$DOCKER" "$@"; }
ASSETS="${PRATICO_RUNTIME_ASSETS:-$ROOT/.build/runtime-assets}"
[ -f "$ASSETS/vmlinux" ] || { echo "runtime assets missing: run make assets"; exit 1; }

STAGE="$ROOT/.build/testhost"
CACHE="$ROOT/.cache/testhost"
mkdir -p "$STAGE" "$CACHE"
echo "building the Linux host payload (scripts/host-payload.sh)"
"$ROOT/scripts/host-payload.sh" "$STAGE" >"$CACHE/build.log" 2>&1 || { tail -20 "$CACHE/build.log"; exit 1; }

. "$ROOT/e2e/reap.sh"
reap_stale pratico-testhost
# $TMPDIR keeps the socket path under the 104-byte sun_path limit.
HOME_DIR="$(mktemp -d -t pratico-testhost)"
SOCK="$HOME_DIR/docker.sock"
export DOCKER_HOST="unix://$SOCK"
export DOCKER_CONFIG="$HOME_DIR/docker-config"
mkdir -p "$DOCKER_CONFIG"
echo '{"auths":{"pratico.invalid":{}},"cliPluginsExtraDirs":["/opt/homebrew/lib/docker/cli-plugins"]}' >"$DOCKER_CONFIG/config.json"

# A key for this run only, and an ssh that knows the test host: the docker CLI runs
# `ssh` from PATH, and must not touch the user's own ~/.ssh.
ssh-keygen -q -t ed25519 -N "" -f "$HOME_DIR/id" -C pratico-testhost
cp "$HOME_DIR/id.pub" "$STAGE/authorized_keys"
PORT=2222
cat >"$HOME_DIR/ssh_config" <<EOF
Host testhost devhost
    HostName 127.0.0.1
    Port $PORT
    IdentityFile $HOME_DIR/id
    IdentitiesOnly yes
    StrictHostKeyChecking no
    UserKnownHostsFile $HOME_DIR/known_hosts
    LogLevel ERROR
Host testhost
    User root
Host devhost
    User dev
EOF
mkdir -p "$HOME_DIR/bin"
printf '#!/bin/sh\nexec /usr/bin/ssh -F %s "$@"\n' "$HOME_DIR/ssh_config" >"$HOME_DIR/bin/ssh"
chmod +x "$HOME_DIR/bin/ssh"
# docker as dev, through the installed service; commands on the host as root, or as dev.
remote() { PATH="$HOME_DIR/bin:$PATH" "$DOCKER" -H ssh://devhost "$@"; }
onhost() { "$HOME_DIR/bin/ssh" testhost "$@"; }
asdev() { "$HOME_DIR/bin/ssh" devhost "$@"; }

pass=0
fail=0
ok() { echo "ok   $1"; pass=$((pass + 1)); }
bad() { echo "FAIL $1${2:+ — $2}"; fail=$((fail + 1)); }
check() { local name="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$name"; else bad "$name"; fi; }
expect_eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "want [$3] got [$2]"; fi; }
# name, want, command...: the command's output becomes `want` within 10 s.
eventually_eq() {
    local name="$1" want="$2" got=""
    shift 2
    for _ in $(seq 20); do got=$("$@" 2>&1) && [ "$got" = "$want" ] && { ok "$name"; return; }; sleep 0.5; done
    bad "$name" "want [$want] got [$got]"
}

DAEMON_PID=""
cleanup() {
    if [ "${TESTHOST_KEEP:-0}" = 1 ]; then
        echo "kept running: DOCKER_HOST=$DOCKER_HOST (outer daemon $DAEMON_PID); PATH=$HOME_DIR/bin:\$PATH docker -H ssh://testhost"
        return
    fi
    if [ -S "$SOCK" ]; then
        docker logs testhost >"$HOME_DIR/testhost.log" 2>&1
        ids=$(docker ps -aq 2>/dev/null)
        [ -n "$ids" ] && docker rm -f $ids >/dev/null 2>&1
    fi
    [ -n "$DAEMON_PID" ] && kill "$DAEMON_PID" 2>/dev/null && wait "$DAEMON_PID" 2>/dev/null
    reap_own "$HOME_DIR"
    if [ "$fail" -eq 0 ]; then rm -rf "$HOME_DIR"; else echo "kept $HOME_DIR (daemon.log, testhost.log)"; fi
}
trap cleanup EXIT

PRATICO_TESTHOST=1 PRATICO_RUNTIME_ASSETS="$ASSETS" "$BIN/pratico-daemon" --home "$HOME_DIR" >>"$HOME_DIR/daemon.log" 2>&1 &
DAEMON_PID=$!
for _ in $(seq 50); do [ -S "$SOCK" ] && break; sleep 0.1; done
[ -S "$SOCK" ] || { echo "daemon did not create $SOCK"; cat "$HOME_DIR/daemon.log"; exit 1; }

docker buildx create --name pratico-build --driver docker-container --driver-opt default-load=true >/dev/null
BUILDX_BUILDER=pratico-build docker build -q -t pratico-testhost "$ROOT/e2e/testhost" >/dev/null || { echo "cannot build the test host image"; exit 1; }
docker run -d --name testhost --runtime pratico-testhost --privileged --cpus 4 -m 6g \
    -p "127.0.0.1:$PORT:22" -v "$STAGE:/opt/pratico:ro" -v "$ROOT/e2e:/e2e:ro" pratico-testhost >/dev/null || { echo "cannot start the test host"; exit 1; }
# Up once sshd answers and systemd has finished booting ("degraded" counts: a container
# lacks some of a machine's units).
for _ in $(seq 200); do onhost test -d /run/systemd/system 2>/dev/null && break; sleep 0.3; done
onhost timeout 60 systemctl is-system-running --wait >/dev/null 2>&1 || true

# The checks a real host gets too (e2e/worker.sh): install, use, upgrade, uninstall.
asuser() { asdev "$@"; }
PAYLOAD=/opt/pratico SERVER_ARCH=linux/arm64 USER_NAME=dev INSTALL_LOG="$HOME_DIR/install.log"
# The menubar's own SSH (PraticoRemote): key file, known_hosts, dial-stdio, as dev.
MENUBAR_SSH() {
    PRATICO_REMOTE_TEST_TARGET=devhost PRATICO_REMOTE_TEST_CONFIG="$HOME_DIR/ssh_config" \
        swift test --package-path "$ROOT" --filter remoteHostAnswersOverPraticosOwnSSH 2>&1 | grep -q "remoteHostAnswersOverPraticosOwnSSH() passed"
}
. "$ROOT/e2e/host-checks.sh"

echo "testhost: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
