# Embedded runtime — design

Status: proposed (2026-11-09). Replaces the `container` CLI backend (D-10/D-11 era).

## Why

Up to v0.1.0-alpha.1 the daemon drives Apple's `container` CLI. That forces users to
install `container`, and every limit of the CLI became a pratico limit:

| Limit of the CLI backend | Effect today |
|---|---|
| Exit codes come only from an attached `container start` child | lost when the daemon restarts |
| No container-name DNS without an admin-created domain | `/etc/hosts` rewritten inside each container via `exec sh`; none for distroless |
| Networks fixed at create; guest lacks `CAP_NET_ADMIN` | disconnect of a used container is name-only |
| vmnet: `default` reclaims `bridge100` | custom networks die; a "pause anchor" container works around it |
| Auto-allocated subnets get no host bridge | pratico allocates subnets itself |
| No pause | cgroup freezer agent via `exec sh` |
| `container stats` takes ~2 s | background sampler |
| 50–300 ms per CLI call | ~1.2 s `docker run` |

The goal: pratico ships its own runtime, needs nothing installed, and each of these rows
disappears.

## Building blocks

[apple/containerization](https://github.com/apple/containerization), the Swift package
that `container` itself is built on, linked into pratico:

- `VZVirtualMachineManager` / `LinuxContainer`: one lightweight VM per container on
  Virtualization.framework. Real `pause()`/`resume()` of the VM.
- `vminitd`: init system in each VM, a gRPC agent over vsock. As guest root it can
  `createProcess` (with pty), `signal`, `wait` (exit status), `up`/`down` interfaces,
  `addressAdd`, routes, `configureDNS`, `containerStatistics`, filesystem operations.
- `ContainerizationOCI`: image store, registry client (pull, push, auth).
- `ContainerizationEXT4`: per-container ext4 root filesystems from image layers.
- Network devices are any `VZInterface` returning a `VZVirtioNetworkDeviceConfiguration`,
  so pratico can attach its own `VZFileHandleNetworkDeviceAttachment`.

Requirements: Apple silicon, macOS 26 (already pratico's floor), entitlement
`com.apple.security.virtualization` only. That entitlement is not restricted; ad-hoc
signing works (D-10 still holds).

## Components

```
pratico-menubar ──► pratico-daemon ──(unix socket per container)──► pratico-shim ×N
                    Docker API, state,                               one VM each
                    images, scans, events                            (Containerization)
                    pratico-net: switch + DNS ◄──(datagram fds)────── VM NICs
```

1. **pratico-daemon**: keeps the Docker API, records, events, health, scanning. The
   `AppleContainer` adapter is replaced by a `Runtime` protocol, with the shim client
   as the only implementation.
2. **pratico-shim** (one process per running container, like `containerd-shim` or
   `container-runtime-linux`): owns the VM, stdio, and log files. It writes the exit
   status to `~/.pratico/containers/<id>/exit` and serves a small control API (start,
   stop, kill, pause, exec, resize, stats, fs ops, net config) on
   `~/.pratico/containers/<id>/shim.sock`. It outlives daemon restarts: on startup the
   daemon reconnects to every live shim, and reads exit files for the rest. No exit code
   is ever lost.
3. **pratico-net**: a user-space Ethernet switch in the daemon. VM NICs are
   `VZFileHandleNetworkDeviceAttachment` datagram socket pairs whose other end the
   daemon holds. It has no vmnet, no host bridges, and no `bridge100`.
4. **Assets**: Linux kernel and the `vminit` init filesystem, at pinned versions and
   digests. They are bundled in the app (kernel ~16 MB) or fetched on first run and
   verified. pratico checks for them in `~/.pratico/runtime/`.

## Networking

Each Docker network is a broadcast domain in pratico-net. Containers on different
networks cannot exchange a frame, because the switch never forwards one.

- **Addresses**: pratico assigns IPs (IPAM per network) and configures them through
  the agent (`addressAdd`, `up`, routes); no DHCP is needed.
- **DNS**, as on Docker for Linux: the switch answers DNS at each network's gateway
  address (Docker uses `127.0.0.11`). Container names, aliases, and short IDs on that
  network resolve; everything else forwards to the host's resolvers. Nothing is written
  into containers, so distroless images work.
- **Hot connect/disconnect on running containers**: Virtualization.framework cannot
  hot-add NICs. So each VM gets a fixed number of NIC slots (config
  `network_slots`, default 4) at boot.
  - Connect: the switch binds a free slot to the network, then the agent assigns its
    address and brings it up.
  - Disconnect: the agent takes the slot down, and the switch unbinds it. Frames are
    dropped at the switch, so isolation holds even against a hostile guest.
- **Internet (uplink)**: the switch routes off-network traffic to an uplink port. The
  uplink does NAT through a user-space TCP/IP stack. Proposed first version: bundled
  [gvproxy](https://github.com/containers/gvisor-tap-vsock) (Apache-2.0, used by Podman)
  attached as the uplink port. A Swift stack can replace it later without touching the
  rest.
- **`--internal` networks** have no uplink port: real isolation from the internet.
- **Port publishing**: the daemon listens on the host address and port, and relays
  each connection through the uplink to the container's address. Loopback-only
  publishing becomes the safe default per config.
- **`none`**: no NIC slots bound. **`host`**: still unsupported (a VM has its own kernel).

## Docker operations on the new runtime

| Docker | Today (CLI) | Embedded |
|---|---|---|
| create | `container create` | unpack rootfs → ext4 clone; record only, no VM yet |
| start | attached `container start` child | spawn shim; VM boots; logs written by shim |
| stop/kill | `container stop/kill` | agent signal → wait → VM stop |
| pause | cgroup freezer via `exec sh` | `VZVirtualMachine.pause()` |
| exec | `container exec` + host pty | agent `createProcess` with pty, resize |
| cp | `tar`/`stat` via exec | agent filesystem ops (no guest tools needed) |
| stats | 2 s CLI sampler | agent `containerStatistics`, on demand |
| logs | daemon pipes | shim-owned files, survive daemon restarts |
| images | `container image …` + Apple Keychain | `ContainerizationOCI` store in `~/.pratico/store`; `docker login` credentials in pratico's own Keychain item |
| networks | Apple vmnet networks + `/etc/hosts` | pratico-net + embedded DNS |
| volumes | — | ext4 volume images or virtiofs directories (volumes task) |

## Licenses

| Component | License | Obligations when bundled |
|---|---|---|
| apple/containerization (incl. vminitd) | Apache-2.0 | ship LICENSE + NOTICE text, mark modified files, no Apple trademarks/logos |
| SwiftNIO, grpc-swift, swift-protobuf, swift-crypto, … (its dependencies) | Apache-2.0 | same |
| zstd | BSD-3 (dual BSD/GPLv2; use BSD) | keep copyright notice |
| gvproxy / gvisor-tap-vsock | Apache-2.0 | same as above |
| Linux kernel binary | GPL-2.0 | offer the exact source + config for the shipped binary (link to the tagged source and our config in the release) |

The app gets an "Acknowledgements" file in the DMG and in About. Naming stays
"pratico"; Apple names are not used.

## Migration (vertical slices, e2e green after each)

1. Assets and image store: pull, list, inspect, tag, rm, save on `ContainerizationOCI`.
2. Shim and lifecycle: create/start/stop/kill/wait/logs/rm; exit codes survive daemon
   restart (new e2e check).
3. Exec, cp, stats, pause on the agent; remove the freezer agent and the stats sampler.
4. pratico-net: switch, IPAM, embedded DNS, uplink, port publishing; bridge and none.
5. Custom networks with hot connect/disconnect (new e2e: disconnect cuts traffic by IP).
6. Registry auth and push on the OCI client; scanning reads the store directly.
7. Remove `AppleContainer`, the `/etc/hosts` sync, and the anchor; update SPEC
   (D-10/D-11/D-15/D-21/D-25) and docs.

Each slice keeps the Docker API unchanged; the CLI backend stays until slice 7, so a
slice can switch over per operation group.

## Risks and costs

- Each shim process holds a VM; memory per idle container is the VM's (as today).
- macOS 26 only (unchanged).
- The Containerization API is pre-1.0 and changes; pin a version and track releases.
- gvproxy is a foreign (Go) binary in the bundle until a Swift uplink exists.
- Kernel updates are pratico's responsibility (security fixes ship with app releases).

## Open questions

1. DNS on the default `bridge` network: Docker resolves names only on user networks.
   Resolve on `bridge` too (better) or match Docker?
2. Bundle the kernel and `vminit` in the DMG (+~30 MB, works offline) or fetch on first
   run?
3. Uplink: gvproxy first (recommended), or a Swift user-space stack from the start?
