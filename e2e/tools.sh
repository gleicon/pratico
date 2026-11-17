#!/usr/bin/env bash
# Real tools against a throwaway daemon (make e2e-tools): Testcontainers (Go) and a
# Compose stack with a database. Needs Go and network access; minutes.
set -euo pipefail
BIN="${1:?usage: e2e/tools.sh <bin-dir>}"
DOCKER="${DOCKER:-/opt/homebrew/bin/docker}"
COMPOSE="${COMPOSE:-/opt/homebrew/bin/docker-compose}"
command -v go >/dev/null || { echo "e2e-tools needs Go (brew install go)"; exit 1; }
ASSETS="${PRATICO_RUNTIME_ASSETS:-$(pwd)/.build/runtime-assets}"
HOME_DIR="$(mktemp -d -t pratico-tools)"
export DOCKER_HOST="unix://$HOME_DIR/docker.sock" PRATICO_RUNTIME_ASSETS="$ASSETS"
export DOCKER_CONFIG="$HOME_DIR/docker-config" TESTCONTAINERS_RYUK_DISABLED=false
mkdir -p "$DOCKER_CONFIG" && echo '{}' >"$DOCKER_CONFIG/config.json"
"$BIN/pratico-daemon" --home "$HOME_DIR" >>"$HOME_DIR/daemon.log" 2>&1 &
DAEMON_PID=$!
cleanup() {
    local rc=$?
    # A tool's error often only says what failed (Testcontainers drops a pull's errors and
    # reports "No such image" at create): the daemon's side says why.
    if [ "$rc" != 0 ]; then echo "== daemon log (last 40 lines)"; tail -40 "$HOME_DIR/daemon.log"; fi
    "$COMPOSE" -p pratico-tools -f "$(dirname "$0")/tools/compose.yaml" down -v >/dev/null 2>&1 || true
    # Shims outlive the daemon: every VM goes before it does (BuildKit's included).
    ids=$("$DOCKER" ps -aq 2>/dev/null || true)
    [ -n "$ids" ] && "$DOCKER" rm -f $ids >/dev/null 2>&1 || true
    kill "$DAEMON_PID" 2>/dev/null && wait "$DAEMON_PID" 2>/dev/null
    rm -rf "$HOME_DIR"
}
trap cleanup EXIT
for _ in $(seq 100); do [ -S "$HOME_DIR/docker.sock" ] && break; sleep 0.1; done

echo "== Testcontainers (Go)"
(cd "$(dirname "$0")/tools/testcontainers-go" && go test -count=1 ./...)

echo "== docker build through buildx: BuildKit in a pratico VM, results loaded"
CTX="$HOME_DIR/build-ctx"
mkdir -p "$CTX"
printf 'FROM alpine:3.20\nRUN apk add --no-cache curl >/dev/null && echo built > /built\nCOPY msg /msg\nCMD ["cat", "/msg"]\n' >"$CTX/Dockerfile"
echo "built by buildkit" >"$CTX/msg"
mkdir -p "$DOCKER_CONFIG" && echo '{"cliPluginsExtraDirs":["/opt/homebrew/lib/docker/cli-plugins"]}' >"$DOCKER_CONFIG/config.json"
"$DOCKER" buildx create --name pratico-build --driver docker-container --driver-opt default-load=true >/dev/null
BUILDX_BUILDER=pratico-build "$DOCKER" build -q -t tools-built "$CTX" >/dev/null
[ "$("$DOCKER" run --rm tools-built)" = "built by buildkit" ] || { echo "FAIL docker build"; exit 1; }
echo "ok"

echo "== Compose: an app and its database on a private network"
"$COMPOSE" -p pratico-tools -f "$(dirname "$0")/tools/compose.yaml" up -d --wait
"$COMPOSE" -p pratico-tools -f "$(dirname "$0")/tools/compose.yaml" exec -T app sh -c 'PGPASSWORD=app psql -h db -U app -tAc "select 40+2"' | grep -qx 42
echo "ok"
