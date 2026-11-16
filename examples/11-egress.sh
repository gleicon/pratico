#!/usr/bin/env bash
# Where a container connects, threat feeds, and an allowlist.
. "$(dirname "$0")/lib.sh"
trap 'docker rm -f pratico-example-egress pratico-example-allow >/dev/null 2>&1 || true' EXIT
show() {
    api "/pratico/egress?container=$1" | python3 -c 'import json,sys
for f in json.load(sys.stdin)[0]["Flows"]:
    print(("refused " if f["Blocked"] else "ok      ") + f["Proto"], (f["Name"] or f["Address"]) + ":" + str(f["Port"]), f["Reason"] or "")'
}

step "the threat feeds pratico matches"
api /pratico/egress/feeds | python3 -c 'import json,sys; [print(f["Name"], f["Entries"], f["Error"] or "") for f in json.load(sys.stdin)["Feeds"]]'

step "a container's connections, named by DNS and by the TLS server name"
docker run --name pratico-example-egress alpine sh -c 'wget -qT10 -O /dev/null https://example.com; wget -qT10 -O /dev/null https://pypi.org' >/dev/null 2>&1 || true
show pratico-example-egress

step "an allowlist: only the names listed"
docker run --name pratico-example-allow --label dev.pratico.egress.allow=example.com alpine \
    sh -c 'wget -qT10 -O /dev/null https://example.com && echo "example.com: reached"; wget -qT5 -O /dev/null https://pypi.org || echo "pypi.org: refused"'
show pratico-example-allow
