#!/usr/bin/env bash
# Named volumes, anonymous volumes, copy-up, nocopy, and tmpfs.
. "$(dirname "$0")/lib.sh"
trap 'docker volume rm -f pratico-example-data pratico-example-etc >/dev/null 2>&1 || true' EXIT

step "two containers share a named volume"
docker run --rm -v pratico-example-data:/data alpine sh -c 'echo shared > /data/f'
docker run --rm -v pratico-example-data:/data alpine cat /data/f

step "copy-up: a new volume mounted over /etc starts with the image's files"
docker run --rm -v pratico-example-etc:/etc alpine cat /etc/alpine-release

step "nocopy: the volume starts empty"
docker run --rm -v pratico-example-nocopy:/srv:nocopy alpine ls -A /srv | wc -l
docker volume rm pratico-example-nocopy >/dev/null

step "volumes are plain folders on the Mac"
docker volume inspect pratico-example-data --format '{{.Mountpoint}}'

step "tmpfs: memory in the VM, Docker's default options, size enforced"
docker run --rm --tmpfs /scratch:size=1m alpine sh -c 'grep " /scratch " /proc/mounts'

step "--rm takes the anonymous volume a bare -v /path creates"
docker run --rm -v /scratch alpine true
