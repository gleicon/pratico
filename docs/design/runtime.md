# Embedded runtime — design

pratico's only runtime since 2026-11-12, when the `container` CLI backend was removed
(SPEC D-26–D-28). This note records why, how it is built, and what was learned building it.

## Why

Before it, the daemon drove Apple's `container` CLI. That made users install
`container`, and every limit of the CLI was a pratico limit:

| Limit of the CLI backend | Effect |
|---|---|
| Exit codes come only from an attached `container start` child | lost when the daemon restarts |
| No container-name DNS without an admin-created domain | `/etc/hosts` rewritten inside each container via `exec sh`; none for distroless |
| Networks fixed at create; guest lacks `CAP_NET_ADMIN` | disconnect of a used container is name-only |
| vmnet: `default` reclaims `bridge100` | custom networks die; a "pause anchor" container works around it |
| Auto-allocated subnets get no host bridge | pratico allocates subnets itself |
| No pause | cgroup freezer agent via `exec sh` |
| `container stats` takes ~2 s | background sampler |
| 50–300 ms per CLI call | ~1.2 s `docker run` |

The embedded runtime needs nothing installed, and removed each of these.

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

1. **pratico-daemon**: keeps the Docker API, records, events, health, scanning, and
   drives shims through `ShimClient`.
2. **pratico-shim** (one process per running container, like `containerd-shim` or
   `container-runtime-linux`): owns the VM, stdio, and log files. It writes the exit
   status to `~/.pratico/containers/<id>/exit.json` and serves a small control API
   (start, stop, kill, pause, exec, resize, stats, limits, copies, NICs) on
   `~/.pratico/run/<short id>.sock`. It outlives daemon restarts: on startup the
   daemon reconnects to every live shim, and reads exit files for the rest. No exit code
   is ever lost.
3. **pratico-net**: a user-space Ethernet switch in the daemon. VM NICs are
   `VZFileHandleNetworkDeviceAttachment` datagram socket pairs whose other end the
   daemon holds. It has no vmnet, no host bridges, and no `bridge100`.
4. **Assets**: the Linux kernel (an LTS release, unmodified kernel.org source with
   Containerization's `kernel/config-arm64` plus `vm/kernel/config-pratico`, D-52) and the
   `vminit` init filesystem (`vminitd` and `vmexec` from the vendored source, with the
   flight recorder's BPF probes, D-53 and D-56), all built by pratico from pinned inputs,
   reproducible, checked against SHA-256 digests, and **bundled in the app** (decided
   2026-11-09): first `docker run` works offline, with no setup step. Newer assets
   arrive with app releases; the GPL source offer for the kernel ships alongside (see
   Licenses). Build tools: [tooling](../tooling.md).

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
- **One NIC, an address per network (D-43)**: Virtualization.framework cannot hot-add
  NICs and refuses a fifth, so a card per network capped containers at 4 networks. Each
  VM boots with one card, `eth0`, holding an address on each of its networks; the
  primary network's address is the boot address, the others are added once the guest
  is up. The switch keys the VM's ports by network and classifies each frame by source
  address (ARP sender or IPv4 source); frames from an address it has not registered for
  that VM are dropped. A MAC no longer names one network, so delivery also checks the
  destination: a peer gets a frame only when its ARP target or IPv4 destination is that
  peer's address on the sender's network (broadcast and multicast: the sender's subnet
  or 224.0.0.0/4). Otherwise a raw frame from n1 to a peer's MAC could reach the peer's
  n2 address.
  - A MAC per network (D-44): vminitd cannot set a MAC or add links, so the card keeps
    its first network's MAC and each other endpoint gets its own. The switch rewrites the
    Ethernet source and ARP sender from the card's MAC to the endpoint's on the way out
    (`NetSwitch.handle`), and the destination and ARP target back on the way in
    (`NetSwitch.send`). `NetPort.mac` is the endpoint's, `NetPort.card` the guest's.
  - Connect: the daemon reserves an address and adds an endpoint on the card; the shim's
    agent adds the address; then the switch registers the port. A container's first
    network also gets the default route and the published ports. If the guest step
    fails, only that endpoint is undone. Connects and disconnects are serialized, so
    concurrent ones cannot take two addresses for one network or undo each other.
  - Disconnect: the switch drops the port first, so no frame from or to that address
    passes from then on; its uplink flows end. The link stays up for the other networks.
  - vminitd cannot delete an address or a route. A disconnected address stays on the
    card, reserved for that container until it restarts, and reconnecting to the same
    network gets it back. When the primary network goes, the shim takes `eth0` down and
    up (which clears the old default route and keeps the addresses), adds the default
    via the next network's gateway, and points `resolv.conf` at it.
  - Every pratico gateway answers DNS as the asker's own networks.
- **Internet (uplink)**, in Swift, no extra binaries (decided 2026-11-09): the switch
  routes off-network traffic to pratico's own user-space stack, in the style of slirp.
  - It answers ARP, ICMP echo, and DNS.
  - It relays UDP flows over host sockets.
  - It terminates guest TCP with a minimal TCP endpoint: handshake, sequence numbers and
    ACKs, window, retransmission, FIN and RST. Each flow is a host socket, run on the
    uplink's one serial queue.
- **Egress** (D-51): every flow through the uplink is named (pratico's DNS answers, TLS
  SNI, HTTP `Host`), recorded per container, and checked against threat feeds and the
  container's allowlist; see [egress](../egress.md). Content is not decrypted.
- **`--internal` networks** have no uplink port: real isolation from the internet.
- **Port publishing**: the daemon listens on the host address and port, and relays
  each connection through the uplink to the container's address.
- **`none`**: no NIC. **`host`**: still unsupported (a VM has its own kernel).

## Docker operations on the new runtime

| Docker | CLI backend (removed) | Embedded |
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
| volumes | — | ext4 disk images, or virtiofs shares (D-49) |

## Licenses

| Component | License | Obligations when bundled |
|---|---|---|
| apple/containerization (incl. vminitd) | Apache-2.0 | ship LICENSE + NOTICE text, mark modified files, no Apple trademarks/logos |
| SwiftNIO, grpc-swift, swift-protobuf, swift-crypto, … (its dependencies) | Apache-2.0 | same |
| zstd | BSD-3 (dual BSD/GPLv2; use BSD) | keep copyright notice |
| Linux kernel binary | GPL-2.0 | offer the exact source + config for the shipped binary (link to the tagged source and our config in the release) |
| Flight recorder probes (`vm/bpf`, pratico's own) | MIT, declared `Dual MIT/GPL` to the kernel | source in this repository at the release's tag; built against the kernel's types (`vmlinux.btf`) |

The app gets an "Acknowledgements" file in the DMG and in About. Naming stays
"pratico"; Apple names are not used.

## Migration

Eight vertical slices, 2026-11-09 to 2026-11-12, each with the Docker API unchanged and
e2e green: the image store, the shim and lifecycle, exec/cp/stats, pratico-net (switch,
DNS, uplink, published ports), custom networks with hot connect, registry logins and
push, then the embedded runtime as the default and the CLI backend removed. Egress
naming and threat feeds came after (D-51).

## As built

| Piece | Where |
|---|---|
| Asset fetch, pinned digests | `scripts/fetch-runtime-assets.sh`, `make assets` → `.build/runtime-assets/{vmlinux,vminit/}` (app: `Contents/Resources/runtime`) |
| Runtime bootstrap (store, `vminit` load, `initfs.ext4`) | `EmbeddedRuntime` in `Sources/PraticoDaemonKit/Embedded.swift` |
| Images on the store | `EmbeddedImageBackend` in `ImageBackend.swift`; `ImageService` is backend-agnostic |
| Registry client, trust, logins | `RegistrySession`, `RegistryPolicy` in `RegistrySession.swift`; `Registries` (policy, Keychain logins, `registries.json`) in `Registries.swift` |
| NIC endpoints | `ShimNIC`, `NICSlots` (endpoints, cards by socket, the primary one; add, bind, revert, unbind) in `Net/NIC.swift`; hot connect and disconnect in `NetworkService` and `ContainerNetworks.swift` |
| Socket mounts | `ContainerService.shimMount` (maps `/var/run/docker.sock` to the daemon's socket, marks Unix sockets) in `Containers.swift`; the shim relays them with `UnixSocketConfiguration(direction: .into)` |
| `/var/run/docker.sock` link | `DefaultSocket` in `Sources/PraticoCore/DefaultSocket.swift` (the `/bin/ln` launchd job and the install and remove scripts the menubar runs through an admin prompt) |
| Shim (VM owner) | `ShimHost`, `ShimControl` in `Shim.swift`; executable `Sources/pratico-shim` |
| Daemon side | `ShimClient` (spawn in its own session, control socket, exit watch via `DispatchSource` on the pid), used by `ContainerService` |
| Tests | `make e2e-embedded` (`e2e/embedded.sh`) |

Per-container files in `<home>/containers/<id>/`: `config.json` (Docker record),
`rootfs.ext4`, `spec.json` (what the shim runs), `state.json` (pid, running/paused),
`log` (+ `log.1`), `activity.jsonl` (+ `activity.1.jsonl`, the flight recorder, D-56), `exit.json` (code, time, error; written last), `shim.log`. The control socket is
`<home>/run/<short id>.sock`.

Shim control API (HTTP over the socket, one request per connection): `POST /kill?signal=N`,
`POST /stop?t=S` (SIGTERM, SIGKILL after S seconds), `POST /pause`, `POST /resume`,
`POST /resize?h=&w=`, `POST /stdin` (hijacked: raw bytes into the process's stdin until
EOF), `POST /exec` (`{"args", "timeout"}` → `{"exitCode", "output"}`, used by
healthchecks and stat), `POST /exec-stream` (hijacked; Docker's raw or multiplexed
framing), `GET /exec-status?id=`, `POST /exec-resize?id=&h=&w=`, `POST /copy-out?src=&dst=`
and `POST /copy-in?src=&dst=&mode=` (host paths must be inside the container directory),
`GET /stats` (agent counters under the CLI backend's keys), `POST /limits` (cgroup limits of a running container, D-55), `POST /nic` (a `NICChange`:
`up` with card, address and an optional gateway, `down`, or `route`; the shim remembers
which addresses each card holds, since it outlives daemon restarts and the agent cannot
delete one). SIGTERM to a shim stops its
container like `docker stop` (SIGKILL after 10 s).

Learned while building:
- Virtualization.framework needs the `com.apple.security.virtualization` entitlement on
  the process that runs VMs: the shim, not the daemon. `swift build` relinks and drops the
  signature, so `make build` re-signs `pratico-shim` every time.
- Logs flow through the file: the shim is the only writer; the daemon tails it (50 ms)
  for `logs -f` and attach, and flushes it before closing attached clients on exit.
- Async Containerization calls are bridged into the daemon's thread-per-connection
  model with `blocking { }`; it must never run on a Swift concurrency thread.
- A terminal process has one output stream: Containerization rejects a separate stderr
  with `terminal=true`.
- The Docker CLI picks `run`'s exit code from the start error's wording (127 for
  "executable file not found", 126 for "permission denied"), so start errors use it.
- `cp` out uses the agent's copy (extraction is `openat`/`O_NOFOLLOW`, rejects `..`) and
  tars on the host; `cp` in unpacks with bsdtar on the host, copies each entry in, then
  `chown -R 0:0` where the image has it. Stat runs `stat` in the guest, falling back to
  a copy-out for images without a shell.
- `StatsService.epoch` is a lazy `static let`; it is pinned at init, or the first CPU
  totals come out negative and the Docker CLI reports `EOF`.
- pratico-net as built (4a): `Net/Packets.swift` (bounds-checked Ethernet/ARP/IPv4/UDP/
  ICMP/DNS), `Net/Switch.swift` (daemon; `<home>/run/net.sock`), `Net/NIC.swift` (shim:
  socket pair to Virtualization.framework, relay bound at `<home>/run/<short id>.<n>`).
  The switch knows ports by their socket path and drops frames whose source MAC or IP is
  not the port's. Addresses come from the network's subnet (`bridge`: 172.17.0.0/16,
  gateway .1) and are recorded in the shim's spec, so a restarted daemon re-registers
  them. External A queries use `getaddrinfo` (VPN and split DNS apply), at most 32 at a
  time; AAAA and other types get empty answers until IPv6 routing exists.
- The uplink as built (4b, `Net/Uplink.swift`, `Net/TCPSegment.swift`): one serial
  queue runs every flow. UDP flows use connected host sockets (60 s idle). Ping uses
  unprivileged ICMP datagram sockets. TCP is terminated per connection: the SYN-ACK
  goes out only after the Mac's connect succeeds (refusals stay refusals), 1 MiB receive
  buffer with window scaling, go-back-N retransmission with backoff, FIN/RST both ways.
  The gateway address maps to the Mac's 127.0.0.1. Traffic to other pratico subnets,
  loopback, multicast, and anything from `--internal` networks never leaves. Packets over
  the 1500-byte MTU are fragmented. Measured: internet at line rate; to the Mac,
  ~79 MB/s down and ~70 MB/s up; 300 sequential and 20 parallel connections clean.
- Published ports (4c): the daemon binds each `-p` on the Mac (all interfaces unless a
  host IP is given, as Docker) before the start completes, so a taken port fails it with
  Docker's message. Each accepted connection is opened toward the container from the
  gateway by the same TCP endpoint, actively; UDP keeps a per-client flow. Listeners
  are rebound after a daemon restart and released when the container stops.
- Shims are spawned with `POSIX_SPAWN_CLOEXEC_DEFAULT`: without it they inherited the
  daemon's API connections and port listeners, which kept a published port captive
  after a daemon restart.
- `docker login` (6): the daemon pings the registry's `/v2/` with the credentials
  (Basic or Bearer challenge) and keeps them as Internet-password items with security
  domain `dev.pratico.registry`. Pulls and pushes use a request's `X-Registry-Auth`
  first, then that login. The menubar's Registries menu removes a kept login.
- Registry client (SPEC D-29): pratico's own, on URLSession
  (`Sources/PraticoDaemonKit/RegistrySession.swift`), plugged into Containerization's
  `ImportOperation`/`ExportOperation`. Containerization's client refuses credentials
  over plain HTTP and only takes CAs through `SSL_CERT_FILE`, which replaces the
  system's roots. Its guards are kept: digest checks, no substituted pinned digest,
  size bounds, token realms in the registry's own domain.
  - Trust: the system's roots first, then each `registry_ca`, so pratico can say which
    CA vouched. macOS rejects a self-signed CA certificate used directly as a server's;
    use a CA plus a leaf.
  - Plain HTTP: loopback by default (`registry_http_loopback`), others by
    `registry_http` (hosts, host:port, or IPv4 CIDRs, matched the same way for
    `docker info` and for requests); HTTPS is still tried first, and an untrusted certificate never
    falls back to HTTP.
  - Awareness: `docker info` warnings and `RegistryConfig`, a note in pull and push
    output, the daemon log, `registries.json` and the menubar.
- Limits: IPv4 only (IPv6 networks, `--ip6`, and IPv6 port binds are refused); one NIC per VM, so no network count limit (Virtualization.framework refuses a fifth network device, which capped the earlier card-per-network design at 4).

## Risks and costs

- Each shim process holds a VM; memory per idle container is the VM's (as today).
- macOS 26 only (unchanged).
- Containerization is forked whole at one commit (`Vendor/README.md`); upstream
  security fixes are pratico's to merge.
- The Swift TCP endpoint is the largest piece pratico owns; e2e covers bulk transfers
  both ways and many short connections.
- Kernel updates are pratico's responsibility (security fixes ship with app releases).

## Decisions (2026-11-09)

1. Default `bridge` matches Docker; pratico adds `.pratico.internal` names and
   `host.docker.internal` (see Networking).
2. Kernel and `vminit` are bundled; no pratico download infrastructure.
3. The uplink is pure Swift; no extra binaries.

## Start order (2026-11-14)

The shim boots the VM and creates the container (rootfs mounted, init not started), writes
`state.json` as `created`, and serves its control socket. The daemon then attaches the
NICs to pratico-net, publishes ports, records the container as running, and calls the
shim's `POST /start`, which starts the process. A shim that gets no `/start` within 120 s
stops its VM and exits. The process therefore never runs before its ports are bound or
before the daemon reports it running; a container that queries the daemon through a
mounted socket sees itself.

## Rootfs cache and start latency (2026-11-15)

Profiled with `PRATICO_TRACE=1`: of a `docker run --rm alpine true`, about 130 ms is the
guest kernel booting (each virtio device costs ≈ 8 ms to probe; VMs had 4 NICs, 3 of
them spare for hot connect, until D-43 cut that to one), about 110 ms is vminitd starting and the host agent setting
up the container, about 40 ms is the process start, and about 80 ms is the docker CLI
itself. pratico's own share was the per-container image unpack and a 20 ms poll for the
shim; both are gone: images are unpacked once and cloned (APFS `clonefile`), and the shim
signals readiness on a pipe.

## Stopped containers (2026-11-14)

`docker cp` with a stopped container boots nothing. Copies out read the container's ext4
rootfs on the Mac with ContainerizationEXT4's reader, writing every entry relative to
its parent's descriptor with `O_NOFOLLOW` and `O_EXCL`, under byte and entry caps. Copies
in unpack the tar on the Mac, then rewrite the rootfs: export it, format a new image,
unpack the export and then the new files (owned by root), and swap the image in. A
container whose rootfs is in use cannot start until the copy ends. The same reader does
volume copy-up when a new container mounts an empty volume.
