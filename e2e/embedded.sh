#!/usr/bin/env bash
# End-to-end checks for the embedded runtime (docs/design/runtime.md): the real
# `docker` CLI against pratico-daemon with PRATICO_RUNTIME=embedded. Apple's `container`
# CLI is replaced by a fake that records any call, and the suite fails if one happens.
# Usage: e2e/embedded.sh <bin-dir>     (or: make e2e-embedded)
set -uo pipefail

BIN="${1:?usage: e2e/embedded.sh <bin-dir>}"
DOCKER="${DOCKER:-/opt/homebrew/bin/docker}"
[ -x "$DOCKER" ] || { echo "e2e needs the docker CLI at $DOCKER"; exit 1; }
docker() { "$DOCKER" "$@"; }
ASSETS="${PRATICO_RUNTIME_ASSETS:-$(pwd)/.build/runtime-assets}"
[ -f "$ASSETS/vmlinux" ] || { echo "runtime assets missing: run make assets"; exit 1; }

HOME_DIR="$(mktemp -d -t pratico-emb)"
SOCK="$HOME_DIR/docker.sock"
export DOCKER_HOST="unix://$SOCK"
export DOCKER_CONFIG="$HOME_DIR/docker-config"
mkdir -p "$DOCKER_CONFIG"
echo '{"auths":{"pratico.invalid":{}}}' >"$DOCKER_CONFIG/config.json"
# Any use of Apple's CLI is a failure of this runtime.
FAKE="$HOME_DIR/fake-container"
printf '#!/bin/sh\necho "$@" >>"%s/apple-calls"\nexit 1\n' "$HOME_DIR" >"$FAKE"
chmod +x "$FAKE"
export PRATICO_RUNTIME=embedded PRATICO_RUNTIME_ASSETS="$ASSETS" PRATICO_CONTAINER_BIN="$FAKE"
export PRATICO_OSV_BIN=/nonexistent PRATICO_GRYPE_BIN=/nonexistent  # no scanning here
DAEMON_PID=""

pass=0
fail=0
ok() { echo "ok   $1"; pass=$((pass + 1)); }
bad() { echo "FAIL $1${2:+ — $2}"; fail=$((fail + 1)); }
check() { local name="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$name"; else bad "$name"; fi; }
expect_eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "want [$3] got [$2]"; fi; }

start_daemon() {
    "$BIN/pratico-daemon" --home "$HOME_DIR" >>"$HOME_DIR/daemon.log" 2>&1 &
    DAEMON_PID=$!
    for _ in $(seq 100); do [ -S "$SOCK" ] && return 0; sleep 0.1; done
    echo "daemon did not start"; cat "$HOME_DIR/daemon.log"; exit 1
}
stop_daemon() {
    [ -n "$DAEMON_PID" ] && kill "$DAEMON_PID" 2>/dev/null && wait "$DAEMON_PID" 2>/dev/null
    DAEMON_PID=""
}
cleanup() {
    if [ -S "$SOCK" ]; then
        ids=$(docker ps -aq 2>/dev/null)
        [ -n "$ids" ] && docker rm -f $ids >/dev/null 2>&1
    fi
    stop_daemon
    rm -rf "$HOME_DIR"
}
trap cleanup EXIT

start_daemon
out=$(docker run --rm alpine sh -c 'echo hello; exit 7' 2>&1)
rc=$?
expect_eq "run --rm prints output" "$(tail -1 <<<"$out")" "hello"
expect_eq "run --rm returns the exit code" "$rc" "7"
check "image is listed" test "$(docker images --format '{{.Repository}}:{{.Tag}}' | grep -c '^alpine:latest$')" = 1
check "kernel is pratico's" test "$(docker run --rm alpine uname -r)" = "6.18.15"

# stdin and terminals
expect_eq "run -i pipes stdin" "$(printf 'a\nb\nc\n' | docker run -i --rm alpine wc -l | tr -d ' ')" "3"
PTY="python3 -I $(dirname "$0")/pty.py"
expect_eq "run -it gets a sized tty" "$($PTY 33 111 "$DOCKER" run -it --rm alpine sh -c 'sleep 1; tty; stty size' | tr -d '\r' | xargs)" "/dev/pts/0 33 111"
typed=$( (sleep 3; printf 'echo typed-$((6*7))\n'; sleep 1; printf 'exit 5\n') | $PTY 24 80 sh -c "$DOCKER run -it --rm alpine sh; echo rc=\$?" | tr -d '\r')
check "an interactive shell runs what is typed" grep -q 'typed-42' <<<"$typed"
expect_eq "it returns the shell's exit code" "$(tail -1 <<<"$typed")" "rc=5"
docker run --rm alpine /nonexistent >/dev/null 2>&1
expect_eq "a missing executable exits 127" "$?" "127"

# healthchecks run through the shim's agent
docker run -d --name e-hc --health-cmd 'test -f /tmp/ok' --health-interval 1s --health-retries 2 \
    alpine sh -c 'sleep 4; touch /tmp/ok; sleep 300' >/dev/null
sleep 3.5
expect_eq "healthcheck reports unhealthy" "$(docker inspect e-hc --format '{{.State.Health.Status}}')" "unhealthy"
sleep 3
expect_eq "and recovers to healthy" "$(docker inspect e-hc --format '{{.State.Health.Status}}')" "healthy"
docker rm -f e-hc >/dev/null

docker run -d --name e-tick alpine sh -c 'for i in 1 2 3; do echo tick $i; sleep 1; done' >/dev/null
expect_eq "logs -f follows to the end" "$(docker logs -f e-tick | xargs)" "tick 1 tick 2 tick 3"
expect_eq "exit 0 recorded" "$(docker inspect e-tick --format '{{.State.Status}} {{.State.ExitCode}}')" "exited 0"

docker run -d --name e-clock alpine sh -c 'while true; do echo x; sleep 0.2; done' >/dev/null
sleep 1
docker pause e-clock >/dev/null
expect_eq "pause shows as Paused" "$(docker inspect e-clock --format '{{.State.Status}}')" "paused"
n1=$(docker logs e-clock | wc -l); sleep 1; n2=$(docker logs e-clock | wc -l)
expect_eq "a paused VM runs nothing" "$n1" "$n2"
docker unpause e-clock >/dev/null
sleep 1
check "unpause resumes" test "$(docker logs e-clock | wc -l)" -gt "$n2"
docker run -d --name e-sleep alpine sleep 300 >/dev/null
docker stop -t 1 e-sleep >/dev/null
expect_eq "stop escalates to SIGKILL after the grace period" "$(docker inspect e-sleep --format '{{.State.ExitCode}}')" "137"

# A daemon restart leaves containers running and loses no exit code.
docker run -d --name e-late alpine sh -c 'sleep 3; echo late; exit 42' >/dev/null
stop_daemon
sleep 5
start_daemon
expect_eq "container still runs after a daemon restart" "$(docker inspect e-clock --format '{{.State.Status}}')" "running"
expect_eq "exit code of a container that ended while the daemon was down" \
    "$(docker inspect e-late --format '{{.State.ExitCode}}')" "42"
expect_eq "its output was kept" "$(docker logs e-late)" "late"
docker stop -t 1 e-clock >/dev/null
check "a restarted daemon still controls it" test "$(docker inspect e-clock --format '{{.State.Running}}')" = false

docker rm -f e-tick e-clock e-sleep e-late >/dev/null
expect_eq "rm removes rootfs and shim files" "$(ls "$HOME_DIR/containers" | wc -l | tr -d ' ')" "0"
check "tag" docker tag alpine pratico-e2e/emb:1
check "inspect by tag" test "$(docker image inspect pratico-e2e/emb:1 --format '{{.Os}}/{{.Architecture}}')" = "linux/arm64"
docker save -o "$HOME_DIR/save.tar" alpine 2>/dev/null
check "docker save writes a Docker archive" tar -xOf "$HOME_DIR/save.tar" manifest.json
docker rmi pratico-e2e/emb:1 >/dev/null
check "rmi removes the image" docker rmi alpine
if [ -s "$HOME_DIR/apple-calls" ]; then bad "no Apple container CLI calls" "$(head -3 "$HOME_DIR/apple-calls")"; else ok "no Apple container CLI calls"; fi

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ] || { echo "--- daemon log"; tail -20 "$HOME_DIR/daemon.log"; exit 1; }
