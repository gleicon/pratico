#!/usr/bin/env bash
# Disk volumes (a database on its default volume), shares, copy-up, nocopy, and tmpfs.
. "$(dirname "$0")/lib.sh"
trap 'docker rm -f pratico-example-pg >/dev/null 2>&1; docker volume rm -f pratico-example-data pratico-example-etc pratico-example-share pratico-example-pgdata >/dev/null 2>&1 || true' EXIT

step "a database on a disk volume: its entrypoint chowns the data, as on Linux"
docker run -d --name pratico-example-pg -e POSTGRES_PASSWORD=example -v pratico-example-pgdata:/var/lib/postgresql/data postgres:17-alpine >/dev/null
for _ in $(seq 60); do docker exec pratico-example-pg pg_isready -U postgres >/dev/null 2>&1 && break; sleep 0.5; done
docker exec pratico-example-pg psql -U postgres -tAc "select 'postgres answers'"
docker rm -f pratico-example-pg >/dev/null

step "a disk volume keeps its data from one container to the next"
docker run --rm -v pratico-example-data:/data alpine sh -c 'echo kept > /data/f'
docker run --rm -v pratico-example-data:/data alpine cat /data/f

step "copy-up: a new volume mounted over /etc starts with the image's files"
docker run --rm -v pratico-example-etc:/etc alpine cat /etc/alpine-release

step "nocopy: the volume starts empty"
docker run --rm -v pratico-example-nocopy:/srv:nocopy alpine ls -A /srv | wc -l
docker volume rm pratico-example-nocopy >/dev/null

step "a disk is a sparse ext4 image; a share is a folder several containers mount at once"
docker volume inspect pratico-example-data --format '{{.Mountpoint}} ({{.Options.type}})'
docker volume create --opt type=share pratico-example-share >/dev/null
docker volume inspect pratico-example-share --format '{{.Mountpoint}} ({{.Options.type}})'

step "tmpfs: memory in the VM, Docker's default options, size enforced"
docker run --rm --tmpfs /scratch:size=1m alpine sh -c 'grep " /scratch " /proc/mounts'

step "--rm takes the anonymous volume a bare -v /path creates"
docker run --rm -v /scratch alpine true
