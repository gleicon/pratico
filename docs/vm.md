# VMs

Every container runs in its own lightweight VM on Virtualization.framework, through
[apple/containerization](https://github.com/apple/containerization). Nothing runs when no
container does.

```
pratico-daemon ── Docker API, images, networks, volumes, scans
      │  one per container
pratico-shim ──── owns one VM
      │  vsock
vminitd ───────── guest init and agent: processes, exec, cp, stats, healthchecks
```

## What a VM is made of

- **Kernel**: Linux 6.18.63 (the latest LTS) for arm64, built by pratico; see
  [Kernel](#kernel). It ships inside the app, so the first `docker run` works offline.
- **Init**: `vminitd`, built by pratico from apple/containerization's source; see
  [Init](#init). It is PID 1 and serves a gRPC agent
  over vsock: create and signal processes, ptys, interface and address setup, DNS,
  filesystem operations, statistics.
- **Devices**: the container's root filesystem as a block device (see
  [storage](storage.md)), virtiofs shares for volumes and bind mounts, one network card
  (see [networking](network.md)), and vsock.

## Kernel

pratico builds its guest kernel from kernel.org's source, unmodified, with
apple/containerization's configuration for Virtualization.framework
(`Vendor/containerization/kernel/config-arm64`) and pratico's additions
([`vm/kernel/config-pratico`](../vm/kernel/config-pratico)):

- BPF compiled only (no interpreter) and never for unprivileged users, with the
  kernel's types (BTF, `/sys/kernel/btf/vmlinux`), and tracepoints, uprobes, and perf
  events to attach to. Not kprobes, fentry, or the BPF LSM: on arm64 they cost 63 to 140
  ms on every boot, and nothing in pratico uses them yet.
- Landlock, for programs that sandbox themselves.
- 1000 Hz, as virtio's device reset waits out whole timer ticks (8 ms per device at
  250 Hz), and no EFI or ACPI: the boot loader starts the kernel with a device tree.

The kernel reaches init in about 70 ms (128 ms in 0.2.14).

`scripts/build-kernel.sh` runs the build in a pratico VM from pinned inputs: the tarball
by SHA-256, the Debian build image by digest, its packages from a fixed
snapshot.debian.org date, and a fixed build timestamp, user, and host. Two builds give
the same bytes, and the result must match [`vm/kernel/vmlinux.sha256`](../vm/kernel/vmlinux.sha256),
so anyone can check that the kernel in the app is the one these files make. The
configuration it was built with ships in the app as
`Contents/Resources/runtime/kernel-config`.

## Init

`vminitd` and `vmexec` are built from apple/containerization's source, vendored in
[`Vendor/containerization`](../Vendor/README.md) at the release pratico builds with, by
`scripts/build-init.sh`: Swift 6.3.3 and its static Linux SDK, pinned by digest and
SHA-256, in a pratico VM. The image is tagged by its content and pinned in
[`vm/init/vminit.sha256`](../vm/init/vminit.sha256); when a new pratico brings a new one,
the daemon rebuilds its init disk on start, and VMs already running keep the one they
booted.

The scripts and code behind both builds, and the seccomp compiler: [tooling](tooling.md).

## Lifecycle

- **create** clones the root filesystem and records the container. No VM yet.
- **start** spawns a shim, which boots the VM and reports `created`. The daemon then
  attaches networks, publishes ports, and records the container as running, and only
  then tells the shim to start the process, so a process that asks the daemon about
  itself at once sees itself running.
- **stop** sends the stop signal (`--stop-signal`, image `STOPSIGNAL`, else SIGTERM),
  waits `--stop-timeout` (else 10 s), then SIGKILL. **kill** sends the signal asked.
- **restart policies** start a container again when it exits; see
  [run options](run-options.md#restart-policies).
- **pause** pauses the whole VM: its vCPUs stop, not just a cgroup.
- **top** runs the image's `ps` in the container (a VM has no host `ps` to look in
  from), so an image without `ps` cannot answer it.
- **update** changes the restart policy at once, and the limits of a running container
  inside its VM, up to the vCPUs and memory it booted with; see
  [run options](run-options.md#docker-update).
- **exec**, **cp**, **stats**, and healthchecks go through the agent; images need no
  shell or tools for them. An exec has the container's capabilities and limits.
- **logs** keep timestamps per line: `--since`, `--until`, `--tail`, and `-f` (which
  ends at `--until`).

Shims outlive the daemon. A daemon restart, upgrade, or crash reconnects to every
running shim; output goes to files the shim writes, and exit codes are kept in
`exit.json`, so nothing is lost while the daemon is away.

Root filesystems and disk volumes are journaled ext4: a VM killed mid-run (a crash,
power loss, `kill -9`) leaves a filesystem the guest kernel recovers by replaying its
journal at the next start. Containers made before 0.2.8 have unjournaled root
filesystems; pratico checks their clean flag before each start and, when it is not set,
rebuilds the image from its own files first (the daemon log says so).

## Memory

`--memory` (default `default_memory`, 1024 MiB) sets the guest's RAM, plus 128 MiB for
the guest kernel and init, and the container's `memory.max`. It is a ceiling: the Mac
backs only the pages the guest touches. `--memory-reservation`, `--memory-swap`, and
`--pids-limit` are the cgroup's `memory.low`, `memory.swap.max`, and `pids.max`. There
is no memory balloon, so page cache the guest fills comes back when the container
stops, not while it runs.

## Resource use

Measured on an Apple silicon Mac with idle `alpine` containers. `make bench` checks the
latency and daemon bounds on every run.

| | |
|---|---|
| `docker run --rm alpine true` | P99 316 ms over 50 runs, VM boot included |
| Memory per running container | ≈ 250 MB (VM process ≈ 215 MB, shim ≈ 33 MB) |
| No containers running | no VMs |
| Daemon | ≈ 45 MB; 48 MB with 32 containers running |
| Daemon CPU, 16 idle containers | 0.5% of a core |
| `/_ping`, `/version`, `ps -a` with 100 containers | P99 ≤ 3 ms |

Most of a start is the VM itself. Profiled with `PRATICO_TRACE=1` (step timings in the
daemon log and `shim.log`, the guest console in `boot.log`), in 0.2.15: about 75 ms is
Virtualization.framework starting the VM, whatever the kernel or memory size; the kernel
reaches init in about 70 ms; vminitd serves its agent about 15 ms later; the agent's
setup (rootfs, interface, DNS) takes about 15 ms; the process start about 50 ms, 30 of
them `vmexec` loading. The Docker CLI adds about 80 ms of its own. Measured against
0.2.14 over interleaved runs of `docker run -d`, a start is about 70 ms shorter.

## Why one VM per container

A single shared VM boots once and its containers start faster, but they share one kernel:
one kernel exploit, one runaway process, or one `--privileged` container reaches all of
them. Here each container has its own kernel, memory, and network card; a VM's limits
are its size; and stopping the last container frees everything.

All run options: [run-options.md](run-options.md). Design notes: [design/runtime.md](design/runtime.md).
Decisions: SPEC D-34, D-41, D-42, D-45.
