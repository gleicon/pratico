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

- **Kernel**: Linux 6.18.56 for arm64, as built by Kata Containers 4.3.1, unmodified and
  pinned by SHA-256. It ships inside the app, so the first `docker run` works offline.
- **Init**: `vminitd` from Apple's `vminit` image. It is PID 1 and serves a gRPC agent
  over vsock: create and signal processes, ptys, interface and address setup, DNS,
  filesystem operations, statistics.
- **Devices**: the container's root filesystem as a block device (see
  [storage](storage.md)), virtiofs shares for volumes and bind mounts, one network card
  (see [networking](network.md)), and vsock.

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
- **exec**, **cp**, **stats**, and healthchecks go through the agent; images need no
  shell or tools for them. An exec has the container's capabilities and limits.
- **logs** keep timestamps per line: `--since`, `--until`, `--tail`, and `-f` (which
  ends at `--until`).

Shims outlive the daemon. A daemon restart, upgrade, or crash reconnects to every
running shim; output goes to files the shim writes, and exit codes are kept in
`exit.json`, so nothing is lost while the daemon is away.

The root filesystem has no journal. A VM killed mid-run (a crash, power loss, `kill -9`)
can leave it inconsistent, and the guest would then fail writes. pratico checks the
ext4 superblock's clean flag before each start; when it is not set, it rebuilds the
image from its own files first (the daemon log says so).

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
daemon log and `shim.log`): the kernel boot is about 130 ms, at about 8 ms per virtio
device (measured with four network cards, before one-card networking removed three);
vminitd setup is about 110 ms; the process start about 40 ms. The Docker CLI adds about
80 ms of its own.

## Why one VM per container

A single shared VM boots once and its containers start faster, but they share one kernel:
one kernel exploit, one runaway process, or one `--privileged` container reaches all of
them. Here each container has its own kernel, memory, and network card; a VM's limits
are its size; and stopping the last container frees everything.

All run options: [run-options.md](run-options.md). Design notes: [design/runtime.md](design/runtime.md).
Decisions: SPEC D-34, D-41, D-42, D-45.
