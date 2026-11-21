#!/usr/bin/env bash
# Remote hosts on the Mac (docs/design/remote.md, slice 2): boots the Linux test host, an
# Ubuntu container with KVM (`--runtime pratico-testhost`, nested virtualization) on a
# throwaway daemon, runs pratico's Linux daemon in it with Cloud Hypervisor, and drives it
# with the Mac's docker CLI over `ssh://`, as a VPS would be.
# Usage: e2e/testhost.sh <bin-dir>    (TESTHOST_KEEP=1 leaves it running, to work on it)
set -uo pipefail

BIN="${1:?usage: e2e/testhost.sh <bin-dir>}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DOCKER="${DOCKER:-/opt/homebrew/bin/docker}"
[ -x "$DOCKER" ] || { echo "testhost needs the docker CLI at $DOCKER"; exit 1; }
docker() { "$DOCKER" "$@"; }
ASSETS="${PRATICO_RUNTIME_ASSETS:-$ROOT/.build/runtime-assets}"
[ -f "$ASSETS/vmlinux" ] || { echo "runtime assets missing: run make assets"; exit 1; }

# Cloud Hypervisor's static build, checked against the digest GitHub records for it.
CH_VERSION=v55.0
CH_SHA256=446de7552dacc83bc86d1137e7ffa7c2d204cdda4850eac4f2d2666d63c0f697
CH_URL="https://github.com/cloud-hypervisor/cloud-hypervisor/releases/download/$CH_VERSION/cloud-hypervisor-static-aarch64"

STAGE="$ROOT/.build/testhost"
CACHE="$ROOT/.cache/testhost"
mkdir -p "$STAGE/runtime" "$CACHE"
ch="$CACHE/cloud-hypervisor-$CH_VERSION"
if [ ! -f "$ch" ]; then
    curl -fsSL --retry 3 -o "$ch.part" "$CH_URL" && mv "$ch.part" "$ch" || { echo "cannot fetch $CH_URL"; exit 1; }
fi
[ "$(shasum -a 256 "$ch" | cut -d' ' -f1)" = "$CH_SHA256" ] || { echo "$ch does not match its SHA-256"; exit 1; }
install -m 755 "$ch" "$STAGE/cloud-hypervisor"
cp "$ASSETS/vmlinux" "$STAGE/runtime/"
rm -rf "$STAGE/runtime/vminit" && cp -R "$ASSETS/vminit" "$STAGE/runtime/"
"$ROOT/scripts/build-virtiofsd.sh" "$CACHE/virtiofsd" >"$CACHE/virtiofsd.log" 2>&1 || { tail -20 "$CACHE/virtiofsd.log"; exit 1; }
install -m 755 "$CACHE/virtiofsd/virtiofsd" "$STAGE/virtiofsd"
echo "building pratico for Linux (scripts/linux-check.sh host)"
"$ROOT/scripts/linux-check.sh" host "$STAGE" >"$CACHE/build.log" 2>&1 || { tail -20 "$CACHE/build.log"; exit 1; }

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
Host testhost
    HostName 127.0.0.1
    Port $PORT
    User root
    IdentityFile $HOME_DIR/id
    IdentitiesOnly yes
    StrictHostKeyChecking no
    UserKnownHostsFile $HOME_DIR/known_hosts
    LogLevel ERROR
EOF
mkdir -p "$HOME_DIR/bin"
printf '#!/bin/sh\nexec /usr/bin/ssh -F %s "$@"\n' "$HOME_DIR/ssh_config" >"$HOME_DIR/bin/ssh"
chmod +x "$HOME_DIR/bin/ssh"
remote() { PATH="$HOME_DIR/bin:$PATH" "$DOCKER" -H ssh://testhost "$@"; }
onhost() { "$HOME_DIR/bin/ssh" testhost "$@"; }

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
    if [ "$fail" -eq 0 ]; then rm -rf "$HOME_DIR"; else echo "kept $HOME_DIR (daemon.log, testhost.log)"; fi
}
trap cleanup EXIT

PRATICO_TESTHOST=1 PRATICO_RUNTIME_ASSETS="$ASSETS" "$BIN/pratico-daemon" --home "$HOME_DIR" >>"$HOME_DIR/daemon.log" 2>&1 &
DAEMON_PID=$!
for _ in $(seq 50); do [ -S "$SOCK" ] && break; sleep 0.1; done
[ -S "$SOCK" ] || { echo "daemon did not create $SOCK"; cat "$HOME_DIR/daemon.log"; exit 1; }

docker buildx create --name pratico-build --driver docker-container --driver-opt default-load=true >/dev/null
BUILDX_BUILDER=pratico-build docker build -q -t pratico-testhost "$ROOT/e2e/testhost" >/dev/null || { echo "cannot build the test host image"; exit 1; }
docker run -d --name testhost --runtime pratico-testhost --privileged --cpus 8 -m 8g \
    -p "127.0.0.1:$PORT:22" -v "$STAGE:/opt/pratico:ro" -v "$ROOT/e2e:/e2e:ro" pratico-testhost >/dev/null || { echo "cannot start the test host"; exit 1; }
for _ in $(seq 100); do onhost test -S /var/run/docker.sock 2>/dev/null && break; sleep 0.3; done

check "test host: reachable over ssh" onhost true
check "test host: /dev/kvm" onhost test -c /dev/kvm
expect_eq "ssh://: server is pratico on Linux" "$(remote version --format '{{.Server.Os}}/{{.Server.Arch}}' 2>&1)" "linux/arm64"
check "ssh://: pull alpine" remote pull -q alpine
expect_eq "ssh://: run alpine true" "$(remote run --rm --network none alpine sh -c 'echo ran' 2>&1)" "ran"
expect_eq "ssh://: exit code comes back" "$(remote run --rm --network none alpine sh -c 'exit 3' >/dev/null 2>&1; echo $?)" "3"
expect_eq "net: DNS from the switch" "$(remote run --rm alpine sh -c 'nslookup -type=a example.com >/dev/null && echo resolved' 2>&1)" "resolved"
expect_eq "net: out to the internet" "$(remote run --rm alpine sh -c 'wget -q -T 10 -O /dev/null http://example.com && echo fetched' 2>&1)" "fetched"
check "net: user network" remote network create th-net
remote run -d --name th-server --network th-net alpine sh -c 'while true; do echo hello | nc -l -p 8080; done' >/dev/null 2>&1
expect_eq "net: containers reach each other by name" "$(remote run --rm --network th-net alpine sh -c 'for i in 1 2 3 4 5; do nc -w 2 th-server 8080 && break; sleep 1; done' 2>&1)" "hello"
remote run -d --name th-published -p 18080:8080 alpine sh -c 'while true; do echo published | nc -l -p 8080; done' >/dev/null 2>&1
eventually_eq "net: a published port on the test host" published onhost "echo | timeout 3 nc -q 1 127.0.0.1 18080"
remote rm -f th-server th-published >/dev/null 2>&1
check "net: network rm" remote network rm th-net

onhost "rm -rf /tmp/th-share && mkdir -p /tmp/th-share && echo from-host >/tmp/th-share/in"
expect_eq "fs: a bind mount reads the host's files" "$(remote run --rm -v /tmp/th-share:/share alpine cat /share/in 2>&1)" "from-host"
remote run --rm -v /tmp/th-share:/share alpine sh -c 'echo from-vm >/share/out' >/dev/null 2>&1
expect_eq "fs: and writes them" "$(onhost cat /tmp/th-share/out 2>&1)" "from-vm"
remote run --rm -v th-vol:/data alpine sh -c 'echo kept >/data/f' >/dev/null 2>&1
expect_eq "fs: a named volume outlives its container" "$(remote run --rm -v th-vol:/data alpine cat /data/f 2>&1)" "kept"
check "fs: volume rm" remote volume rm th-vol

remote run -d --name sleeper --network none alpine sh -c 'echo up; sleep 60' >/dev/null 2>&1
check "test host: the container is a Cloud Hypervisor VM" onhost pgrep -f /opt/pratico/cloud-hypervisor
expect_eq "ssh://: ps lists it" "$(remote ps --format '{{.Names}}' 2>&1)" "sleeper"
eventually_eq "ssh://: logs" up remote logs sleeper
check "ssh://: rm -f" remote rm -f sleeper
check "test host: its VM is gone" sh -c "! '$HOME_DIR/bin/ssh' testhost pgrep -f /opt/pratico/cloud-hypervisor"

echo "testhost: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
