#!/usr/bin/env bash
# Bounds, performance, and compatibility (SPEC AC-44 to AC-49), against pratico-daemon in a
# throwaway home. Slower and heavier than the e2e suites (32 VMs at once, 100 containers,
# 100 daemon restarts), so it is its own target: make bench.
# Usage: e2e/bench.sh <bin-dir>
set -uo pipefail

BIN="${1:?usage: e2e/bench.sh <bin-dir>}"
DOCKER="${DOCKER:-/opt/homebrew/bin/docker}"
[ -x "$DOCKER" ] || { echo "bench needs the docker CLI at $DOCKER"; exit 1; }
ASSETS="${PRATICO_RUNTIME_ASSETS:-$(pwd)/.build/runtime-assets}"
[ -f "$ASSETS/vmlinux" ] || { echo "runtime assets missing: run make assets"; exit 1; }
export PRATICO_RUNTIME_ASSETS="$ASSETS"
HERE="$(cd "$(dirname "$0")" && pwd)"
BENCH="python3 -I $HERE/bench.py"
# Docker CLI releases for AC-49, downloaded once into the build directory.
CLI_CACHE="$(pwd)/.build/docker-cli"

HOME_DIR="$(mktemp -d -t pratico-bench)"
SOCK="$HOME_DIR/docker.sock"
export DOCKER_HOST="unix://$SOCK"
export DOCKER_CONFIG="$HOME_DIR/docker-config"
mkdir -p "$DOCKER_CONFIG"
echo '{"auths":{"pratico.invalid":{}}}' >"$DOCKER_CONFIG/config.json"
export PRATICO_OSV_BIN=/nonexistent PRATICO_GRYPE_BIN=/nonexistent PRATICO_TRIVY_BIN=/nonexistent
printf 'scan = false\n' >"$HOME_DIR/config.toml"  # scanners would add load unrelated to the bars
docker() { "$DOCKER" "$@"; }
DAEMON_PID=""

pass=0
fail=0
ok() { echo "ok   $1"; pass=$((pass + 1)); }
bad() { echo "FAIL $1${2:+ — $2}"; fail=$((fail + 1)); }
check() { local name="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$name"; else bad "$name"; fi; }
expect_eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "want [$3] got [$2]"; fi; }
expect_has() { if grep -qF -- "$3" <<<"$2"; then ok "$1"; else bad "$1" "want [$3] in [$2]"; fi; }
# Numbers against a bar: within NAME VALUE MAX, printed with the value either way.
within() { if [ -n "$2" ] && [ "${2%.*}" -le "$3" ] 2>/dev/null; then ok "$1 ($2 ≤ $3)"; else bad "$1" "got [$2], bar $3"; fi; }

start_daemon() {
    "$BIN/pratico-daemon" --home "$HOME_DIR" >>"$HOME_DIR/daemon.log" 2>&1 &
    DAEMON_PID=$!
    for _ in $(seq 100); do [ -S "$SOCK" ] && return 0; sleep 0.05; done
    echo "daemon did not create $SOCK"; tail -5 "$HOME_DIR/daemon.log"; exit 1
}
stop_daemon() {
    [ -n "$DAEMON_PID" ] && kill "$DAEMON_PID" 2>/dev/null && wait "$DAEMON_PID" 2>/dev/null
    DAEMON_PID=""
}
rss_mib() { echo $(( $(ps -o rss= -p "$DAEMON_PID" | tr -d ' ') / 1024 )); }
# Descriptors only (lsof's numbered FD column): `txt` lines are mapped code, and system
# frameworks map more lazily (analyticsd's allowlist after the first container start).
open_files() { lsof -n -P -p "$DAEMON_PID" 2>/dev/null | awk 'NR > 1 && $4 ~ /^[0-9]+/' | wc -l | tr -d ' '; }
remove_all() { local ids; ids=$(docker ps -aq); [ -n "$ids" ] && docker rm -f $ids >/dev/null 2>&1; }
cleanup() { [ -S "$SOCK" ] && remove_all; stop_daemon; rm -rf "$HOME_DIR"; }
trap cleanup EXIT

# The Docker CLI at VERSION from download.docker.com's static builds, cached; prints its path.
cli() {
    local v="$1" dir="$CLI_CACHE/$1"
    if [ ! -x "$dir/docker/docker" ]; then
        mkdir -p "$dir"
        curl -fsSL "https://download.docker.com/mac/static/stable/aarch64/docker-$v.tgz" -o "$dir/docker.tgz" || return 1
        tar -xzf "$dir/docker.tgz" -C "$dir" docker/docker || return 1
        rm -f "$dir/docker.tgz"
    fi
    echo "$dir/docker/docker"
}

start_daemon
docker pull -q alpine >/dev/null 2>&1

# AC-49: the oldest CLI the API minimum allows (25.0, API 1.44) and the current one run
# AC-6 and AC-10; 20.10 (API 1.41) is told the server's API is too new for it.
OLDEST=25.0.5
for v in "$OLDEST" current; do
    if [ "$v" = current ]; then c="$DOCKER"; v="$("$DOCKER" version --format '{{.Client.Version}}' 2>/dev/null)"; else c=$(cli "$v") || { bad "AC-49 download Docker CLI $v"; continue; }; fi
    check "AC-49 Docker CLI $v: docker version (AC-6)" "$c" version
    expect_eq "AC-49 Docker CLI $v: docker run --rm alpine echo hello (AC-10)" "$("$c" run --rm alpine echo hello 2>&1)" "hello"
done
if c=$(cli 20.10.24); then
    expect_has "AC-49 Docker CLI 20.10 is refused as Docker Engine refuses it" "$("$c" version 2>&1)" "client version 1.41 is too old. Minimum supported API version is 1.44"
else
    bad "AC-49 download Docker CLI 20.10.24"
fi

# AC-44: docker run --rm alpine true, 50 times in a row.
read -r p99 worst <<<"$($BENCH runs 50 "$DOCKER" run --rm alpine true)"
within "AC-44 docker run --rm alpine true P99 over 50 runs, ms" "$p99" 1500

# AC-45: control calls with 100 containers.
for i in $(seq 100); do docker create --name "b-$i" alpine true >/dev/null || { bad "AC-45 create container $i"; break; }; done
read -r ping version list <<<"$($BENCH calls "$SOCK" 1000 /_ping /v1.55/version '/v1.55/containers/json?all=1')"
within "AC-45 /_ping P99 with 100 containers, ms" "$ping" 50
within "AC-45 /version P99 with 100 containers, ms" "$version" 50
within "AC-45 /containers/json P99 with 100 containers, ms" "$list" 50
remove_all

# AC-46: 64 concurrent clients, 32 running containers.
for i in $(seq 32); do docker run -d --name "r-$i" -m 128m alpine sleep 900 >/dev/null || { bad "AC-46 start container $i"; break; }; done
expect_eq "AC-46 32 containers run" "$(docker ps -q | wc -l | tr -d ' ')" "32"
expect_eq "AC-46 64 concurrent clients, 50 calls each: errors" "$($BENCH concurrent "$SOCK" 64 50 /v1.55/containers/json)" "0"
within "AC-46 daemon RSS with 32 running containers, MiB" "$(rss_mib)" 100

# AC-47: one connection past the limit waits for a slot; the daemon stays up and bounded.
read -r first after <<<"$($BENCH hold "$SOCK" 65)"
expect_eq "AC-47 64 of 65 connections answered at once, the 65th waits" "$first" "64"
expect_eq "AC-47 the 65th is answered once a slot frees" "$after" "65"
check "AC-47 the daemon is still up" docker version
within "AC-47 daemon RSS after 65 connections, MiB" "$(rss_mib)" 100
remove_all

# AC-48: 100 daemon start/stop cycles; then 100 container start/stop cycles in one daemon.
stop_daemon
for i in $(seq 100); do
    start_daemon
    docker version >/dev/null 2>&1 || bad "AC-48 cycle $i: docker version"
    [ "$i" = 1 ] && first=$(open_files)
    [ "$i" = 100 ] && last=$(open_files)
    [ "$i" = 100 ] || stop_daemon
done
expect_eq "AC-48 idle open files after daemon cycle 100 equal cycle 1" "$last" "$first"
docker create --name cyc alpine sleep 300 >/dev/null
docker start cyc >/dev/null && docker stop -t 0 cyc >/dev/null
sleep 1
before=$(open_files)
for _ in $(seq 100); do docker start cyc >/dev/null && docker stop -t 0 cyc >/dev/null || { bad "AC-48 container cycle"; break; }; done
sleep 1
expect_eq "AC-48 idle open files after 100 container start/stop cycles are unchanged" "$(open_files)" "$before"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ] || { echo "--- daemon log"; tail -20 "$HOME_DIR/daemon.log"; exit 1; }
