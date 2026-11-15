#!/usr/bin/env bash
# What the scanners found, through pratico's API (the menubar shows the same).
. "$(dirname "$0")/lib.sh"

step "which scanners pratico found"
api /pratico/scanners | python3 -c 'import json,sys; [print(("ok " if s["path"] else "-- ")+s["name"], s.get("version") or "", "("+s.get("kind","scanner")+")") for s in json.load(sys.stdin)["scanners"]]'

step "pull, then wait for the scan (it runs in the background)"
docker pull -q alpine >/dev/null
for _ in $(seq 120); do
    api /pratico/scans/summary | python3 -c 'import json,sys; sys.exit(json.load(sys.stdin)["Scanning"])' && break
    sleep 1
done
api /pratico/scans/summary | python3 -m json.tool

step "findings for alpine: severity, EPSS, and which scanner reported each"
api /pratico/scans | python3 -c '
import json, sys
for img in json.load(sys.stdin):
    if "alpine:latest" not in img["Tags"] or "Report" not in img: continue
    for f in img["Report"]["findings"][:10]:
        epss = "%.1f%%" % (f["epss"] * 100) if f.get("epss") is not None else "-"
        print(f["id"], f["package"], f["version"], f["severity"], "EPSS", epss, "by", ",".join(f["sources"]))'

step "SBOM (needs syft: brew install syft)"
api "/pratico/scans/alpine/sbom?format=cyclonedx" 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["bomFormat"], d["specVersion"], len(d.get("components", [])), "components")' || echo "no SBOM yet"

# A blocked image is allowed with: api /pratico/scans/<image id>/allow -X POST
# (the menubar's Allow This Image…, which writes scan_allow in config.toml).
