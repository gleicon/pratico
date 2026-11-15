#!/usr/bin/env bash
# Point docker at pratico once, then use it as usual.
. "$(dirname "$0")/lib.sh"

step "a context the CLI and Compose remember (created once)"
docker context inspect pratico >/dev/null 2>&1 ||
    docker context create pratico --docker "host=unix://$SOCK" >/dev/null
echo "docker context use pratico   # makes it the default"

step "every container runs in its own VM: its kernel is pratico's, not the Mac's"
docker run --rm alpine uname -sr

step "the daemon reports itself"
api /pratico/status | python3 -m json.tool
