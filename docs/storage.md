# Storage

## Images

Images live in an OCI store under `~/.pratico/store`. Pull, push, tag, save, and load
work with any OCI registry or archive; `docker load` takes OCI archives (Docker 25+), and
Apple's `container` tool reads and writes the same format.

## Root filesystem

Each image is unpacked once into an ext4 disk image,
`store/rootfs-cache/<digest>.ext4`. A container's `rootfs.ext4` is an APFS clone of it
(`clonefile`), so `create` takes the same few milliseconds for any image size, and the
clone shares every block until the container writes one. Where cloning fails, pratico
copies.

The VM mounts the image as a block device. Writes go to that container's clone only;
`docker rm` deletes it. Deleting an image deletes its cached copy, and the daemon sweeps
copies of images removed while it was down.

## Volumes and bind mounts

A volume is a directory, `~/.pratico/volumes/<name>/_data`, shared into each VM that
mounts it over virtiofs, as a bind mount is. Two containers mounting one volume see the
same files, live.

- `-v name:/path` and `--mount type=volume` create a missing named volume. A bare
  `-v /path`, and each image `VOLUME` no other mount covers, get an anonymous volume.
- Copy-up: a volume still empty when a container first mounts it gets the image's files
  at that path (directories, regular files, symlinks, permission bits), read from the
  rootfs on the Mac before the VM boots. `nocopy` skips it.
- `docker rm -v` and `--rm` remove a container's anonymous volumes unless another
  container mounts them. Named volumes stay. A volume any container mounts, running or
  not, is never removed.
- `volume prune` removes unused anonymous volumes; `-a` adds named ones.
- Only the `local` driver, without options.
- `--tmpfs` mounts live in the VM's memory, with Docker's default options; `size=` is
  enforced.
- Host Unix sockets, `/var/run/docker.sock` included, are relayed into the VM over
  vsock, so a container can drive pratico through the mounted socket.

`--read-only` mounts the root filesystem read-only; `--shm-size` sizes `/dev/shm`.

Files on volumes and bind mounts are owned by the Mac user. An image that `chown`s its
data to another uid sees the volume's owner instead.

## Copying files

`docker cp` works on running and stopped containers. A running one goes through the
guest agent, with no tools needed in the image. A stopped one is read from its ext4
rootfs on the Mac without booting the VM; copying into it rewrites the rootfs, and the
container cannot start until that finishes.

Archive extraction (`cp`, `load`) refuses paths that escape the target, follows no
symlinks, and caps sizes and entry counts.

## Disk use

`docker system df`, `docker ps --size`, `docker inspect --size`, and the menubar's Disk
menu count allocated blocks: each image's unpacked copy once, each container's rootfs
by the blocks it owns (not those shared with the image), logs, volumes, and scan data.
A running container's writes count once its kernel has flushed them to its disk image,
which Linux does within 30 seconds, or at `sync`. The menu's cleanup actions list what
they remove, ask, then call the matching prune endpoint. Prune filters: `until`,
`label`, `label!`.

## Snapshots

The menubar's Snapshot writes every container, network, and volume definition to
`~/.pratico/snapshots/pratico-snapshot-<time>.tar.gz`: JSON files and a `manifest.json`.
Images come back from their registries on restore; volume data is not included.
Restore shows each container's image, command, mounts, ports, and privileges before
asking, skips names that exist, and starts containers only if asked.

Examples: [02-volumes.sh](../examples/02-volumes.sh),
[03-cp-stopped.sh](../examples/03-cp-stopped.sh),
[06-snapshot.sh](../examples/06-snapshot.sh), [07-cleanup.sh](../examples/07-cleanup.sh).
Decisions: SPEC D-6, D-32, D-36, D-37, D-42.
