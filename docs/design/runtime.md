# Embedded runtime — design

Status: in progress. Steps 1–2 of the migration are done behind
`PRATICO_RUNTIME=embedded` (SPEC D-26–D-28). Replaces the `container` CLI backend.

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
4. **Assets**: Linux kernel (~16 MB, built from Containerization's `kernel/config-arm64`)
   and the `vminit` init filesystem (built from `vminitd` source), at pinned versions
   and SHA-256 digests, **bundled in the app** (decided 2026-11-09). A download would
   need pratico-hosted artifacts (the only upstream kernel is inside a multi-hundred-MB
   Kata tarball), so the bundle is the source of truth: first `docker run` works offline,
   with no setup step. Newer assets arrive with app releases; the GPL source offer for
   the kernel ships alongside (see Licenses).

## Networking

Each Docker network is a broadcast domain in pratico-net. Containers on different
networks cannot exchange a frame, because the switch never forwards one.

- **Addresses**: pratico assigns IPs (IPAM per network) and configures them through
  the agent (`addressAdd`, `up`, routes); no DHCP is needed.
- **DNS**, as on Docker for Linux: the switch answers DNS at each network's gateway
  address (Docker uses `127.0.0.11`). Container names, aliases, and short IDs on that
  network resolve; everything else forwards to the host's resolvers. Nothing is written
  into containers, so distroless images work.
- **Default `bridge` matches Docker** (decided 2026-11-09): bare container names do not
  resolve there. That hurts agents, which mostly `docker run` ad hoc without creating a
  network: a database plus a test runner on `bridge` cannot find each other by name,
  and the agent falls back to scraping IPs from `docker inspect` (which change on every
  restart) or to the deprecated `--link`. pratico goes beyond Docker without changing
  Docker's behavior:
  - `<name>.pratico.internal` resolves on every network, `bridge` included, scoped to
    containers that share a network with the asker (no cross-network discovery).
  - `host.docker.internal` / `host.pratico.internal` reach the Mac, and
    `gateway.docker.internal` the network gateway, as Docker Desktop provides.
  - `docker inspect`, events, and the menubar show each container's DNS names.
- **Hot connect/disconnect on running containers**: Virtualization.framework cannot
  hot-add NICs. So each VM gets a fixed number of NIC slots (config
  `network_slots`, default 4) at boot.
  - Connect: the switch binds a free slot to the network, then the agent assigns its
    address and brings it up.
  - Disconnect: the agent takes the slot down, and the switch unbinds it. Frames are
    dropped at the switch, so isolation holds even against a hostile guest.
- **Internet (uplink)**, in Swift, no extra binaries (decided 2026-11-09): the switch
  routes off-network traffic to pratico's own user-space stack, in the style of slirp.
  - It answers ARP, ICMP echo, and DNS.
  - It relays UDP flows over host sockets.
  - It terminates guest TCP with a minimal TCP endpoint: handshake, sequence numbers and
    ACKs, window, retransmission, FIN and RST. Each flow becomes a SwiftNIO channel to a
    host socket.
- **Egress intercept** (new, from [sandwich-proxy](https://github.com/gleicon/sandwich-proxy),
  MIT, same author): since every container connection is a NIO channel inside pratico,
  HTTP and HTTPS flows can pass through sandwich's engine transparently. The container
  needs no `HTTP_PROXY` setting.
  - Per container: log, replay, breakpoint, and filter requests, and export HAR.
  - Threat feeds (URLhaus, PhishTank, OpenPhish) can block malicious destinations.
  - HTTPS inspection mints certificates per SNI, and is opt-in per container: pratico
    injects its CA into that container's trust store only when asked.
  - Agents get a record of everything a container fetched or sent.
  - The parts embedded are sandwich's proxy pipeline, certificate manager, threat
    feeds, and HAR code, as a library target.
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
| sandwich-proxy (embedded parts) | MIT | keep copyright notice |
| SQLite.swift (sandwich's dependency) | MIT | keep copyright notice |
| Linux kernel binary | GPL-2.0 | offer the exact source + config for the shipped binary (link to the tagged source and our config in the release) |

The app gets an "Acknowledgements" file in the DMG and in About. Naming stays
"pratico"; Apple names are not used.

## Migration (vertical slices, e2e green after each)

1. ✅ Assets and image store: pull, list, inspect, tag, rm, save on `ContainerizationOCI`.
2. ✅ Shim and lifecycle: create/start/stop/kill/wait/logs/rm and VM pause; exit codes
   survive daemon restart. Next within it: stdin (`run -i`, `-it`, attach) and
   healthchecks through the shim.
3. Exec, cp, stats, pause on the agent; remove the freezer agent and the stats sampler.
4. pratico-net: switch, IPAM, embedded DNS (+ `.pratico.internal`, `host.docker.internal`),
   Swift uplink (ARP/ICMP/UDP/TCP), port publishing; bridge and none.
5. Custom networks with hot connect/disconnect (new e2e: disconnect cuts traffic by IP).
6. Registry auth and push on the OCI client; scanning reads the store directly.
7. Egress intercept: sandwich engine on container flows, per-container opt-in, menubar view.
8. Remove `AppleContainer`, the `/etc/hosts` sync, and the anchor; update SPEC
   (D-10/D-11/D-15/D-21/D-25) and docs.

Each slice keeps the Docker API unchanged; the CLI backend stays until slice 8, so a
slice can switch over per operation group.

## As built (steps 1–2)

| Piece | Where |
|---|---|
| Asset fetch, pinned digests | `scripts/fetch-runtime-assets.sh`, `make assets` → `.build/runtime-assets/{vmlinux,vminit/}` (app: `Contents/Resources/runtime`) |
| Runtime bootstrap (store, `vminit` load, `initfs.ext4`) | `EmbeddedRuntime` in `Sources/PraticoDaemonKit/Embedded.swift` |
| Images on the store | `EmbeddedImageBackend` in `ImageBackend.swift`; `ImageService` is backend-agnostic |
| Shim (VM owner) | `ShimHost`, `ShimControl` in `Shim.swift`; executable `Sources/pratico-shim` |
| Daemon side | `ShimClient` (spawn in its own session, control socket, exit watch via `DispatchSource` on the pid); `ContainerService` branches on `embedded` |
| Tests | `make e2e-embedded` (`e2e/embedded.sh`): fake `container` binary that fails the suite if called |

Per-container files in `<home>/containers/<id>/`: `config.json` (Docker record),
`rootfs.ext4`, `spec.json` (what the shim runs), `state.json` (pid, running/paused),
`log` (+ `log.1`), `exit.json` (code, time, error), `shim.log`. The control socket is
`<home>/run/<short id>.sock`.

Shim control API (HTTP over the socket, one request per connection): `POST /kill?signal=N`,
`POST /stop?t=S` (SIGTERM, SIGKILL after S seconds), `POST /pause`, `POST /resume`.

Learned while building:
- Virtualization.framework needs the `com.apple.security.virtualization` entitlement on
  the process that runs VMs: the shim, not the daemon. `swift build` relinks and drops the
  signature, so `make build` re-signs `pratico-shim` every time.
- Logs flow through the file: the shim is the only writer; the daemon tails it (50 ms)
  for `logs -f` and attach, and flushes it before closing attached clients on exit.
- Async Containerization calls are bridged into the daemon's thread-per-connection
  model with `blocking { }`; it must never run on a Swift concurrency thread.
- Interim limits, each 501 with a reason: exec, cp, stats, `docker login`, custom
  networks, published ports; containers have no network yet (step 4).

## Risks and costs

- Each shim process holds a VM; memory per idle container is the VM's (as today).
- macOS 26 only (unchanged).
- The Containerization API is pre-1.0 and changes; pin a version and track releases.
- The Swift TCP endpoint is the largest new piece; it needs a soak test (bulk
  transfers, many short connections, packet loss) before it replaces anything.
- Kernel updates are pratico's responsibility (security fixes ship with app releases).

## Decisions (2026-11-09)

1. Default `bridge` matches Docker; pratico adds `.pratico.internal` names and
   `host.docker.internal` (see Networking).
2. Kernel and `vminit` are bundled; no pratico download infrastructure.
3. The uplink is pure Swift; no extra binaries. sandwich-proxy parts are embedded for
   egress intercept.
