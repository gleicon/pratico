#!/usr/bin/env bash
# Snapshots: every container, network, and volume definition as a .tar.gz of JSON.
. "$(dirname "$0")/lib.sh"

step "take one"
snap=$(api /pratico/snapshots -X POST | python3 -c 'import json,sys; print(json.load(sys.stdin)["Path"])')
echo "$snap"
tar -tzf "$snap"

step "what a restore would do, without doing it (the menubar shows this first)"
q=$(python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$snap")
api "/pratico/snapshots/restore?path=$q&dry_run=1" -X POST | python3 -m json.tool
