#!/usr/bin/env bash
# Images move between pratico and Apple's container tool as OCI archives.
. "$(dirname "$0")/lib.sh"
command -v container >/dev/null || { echo "needs Apple's container tool"; exit 0; }
work=$(mktemp -d); trap 'rm -rf "$work"; container image delete pratico-example/interop:1 >/dev/null 2>&1 || true; docker rmi pratico-example/interop:1 >/dev/null 2>&1 || true' EXIT

docker pull -q alpine >/dev/null
docker tag alpine pratico-example/interop:1

step "pratico -> container"
docker save pratico-example/interop:1 -o "$work/img.tar"
container image load -i "$work/img.tar"
container run --rm pratico-example/interop:1 echo "ran in Apple's container"

step "container -> pratico"
container image save pratico-example/interop:1 -o "$work/back.tar"
docker rmi pratico-example/interop:1 >/dev/null
docker load -i "$work/back.tar"
docker run --rm pratico-example/interop:1 echo "ran in pratico"
