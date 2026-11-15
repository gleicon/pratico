#!/usr/bin/env bash
# A Compose project with a private network and an internal one.
. "$(dirname "$0")/../lib.sh"
cd "$(dirname "$0")"
compose() { docker compose -p pratico-example "$@"; }
trap 'compose down >/dev/null 2>&1 || true' EXIT

compose up -d
step "services find each other by name on the private network"
compose exec -T api ping -c1 -W2 web | grep "packets received"
step "web reaches the internet through front"
compose exec -T web ping -c1 -W3 1.1.1.1 >/dev/null && echo "web: out"
step "api, only on the internal network, does not"
compose exec -T api ping -c1 -W2 1.1.1.1 >/dev/null 2>&1 && echo "api: out (unexpected)" || echo "api: stays in"
