#!/usr/bin/env bash
# Disk use, and pruning with filters. Prints the plans; prunes only with --prune.
. "$(dirname "$0")/lib.sh"

step "what pratico uses, and what each cleanup would free"
api /pratico/disk | python3 -c "$(cat <<'PY'
import json, sys
d = json.load(sys.stdin)
mb = lambda n: "%.1f MB" % (n / 1e6)
print("total", mb(d["Total"]), "| free on this Mac", mb(d["Free"]))
for kind, plan in d["Cleanup"].items():
    names = [i["Name"] for k in ("Containers", "Images", "Volumes") for i in plan[k]]
    print("%-10s frees %10s: %s" % (kind, mb(plan["Bytes"]), ", ".join(names) or "nothing"))
PY
)"

if [ "${1:-}" = --prune ]; then
    step "stopped containers older than a day, except those labeled keep"
    docker container prune -f --filter until=24h --filter 'label!=keep'
fi
