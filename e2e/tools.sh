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
    "$COMPOSE" -p pratico-tools -f "$(dirname "$0")/tools/compose.yaml" down -v >/dev/null 2>&1 || true
    kill "$DAEMON_PID" 2>/dev/null && wait "$DAEMON_PID" 2>/dev/null
    rm -rf "$HOME_DIR"
}
trap cleanup EXIT
for _ in $(seq 100); do [ -S "$HOME_DIR/docker.sock" ] && break; sleep 0.1; done

echo "== Testcontainers (Go)"
(cd "$(dirname "$0")/tools/testcontainers-go" && go test -count=1 ./...)

echo "== Compose: an app and its database on a private network"
"$COMPOSE" -p pratico-tools -f "$(dirname "$0")/tools/compose.yaml" up -d --wait
"$COMPOSE" -p pratico-tools -f "$(dirname "$0")/tools/compose.yaml" exec -T app sh -c 'PGPASSWORD=app psql -h db -U app -tAc "select 40+2"' | grep -qx 42
echo "ok"
