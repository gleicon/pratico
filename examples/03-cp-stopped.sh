#!/usr/bin/env bash
# docker cp works with stopped containers too: no VM is booted for it.
. "$(dirname "$0")/lib.sh"
work=$(mktemp -d); trap 'rm -rf "$work"; docker rm -f pratico-example-cp >/dev/null 2>&1 || true' EXIT

step "configure a created container before its first start"
echo 'hello from the Mac' > "$work/greeting"
docker create --name pratico-example-cp alpine cat /etc/greeting >/dev/null
docker cp "$work/greeting" pratico-example-cp:/etc/
docker start -a pratico-example-cp

step "copy results out of an exited container"
docker cp pratico-example-cp:/etc/greeting "$work/back"
cat "$work/back"
