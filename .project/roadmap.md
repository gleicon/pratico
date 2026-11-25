# Roadmap: pratico v0.1.0

Source: `SPEC.md`. Each task is done when its ACs pass in the end-to-end suite.

v0.1.0 ships functional, buildable from Makefiles, and packaged as a `.dmg`.

## Skeleton

- [x] `make` builds daemon and menubar app; `make test` and `make e2e` run unit and end-to-end suites
- [x] Menubar Start/Stop runs the bundled daemon helper (per-user launch agent); menu shows state, socket path, API version; socket answers `docker version` against a pinned API version; e2e suite drives the real `docker` CLI (AC-1, AC-2, AC-5, AC-6, AC-34, AC-40, AC-53)
- [x] Start refuses, menubar error naming the Apple container runtime, when it is not running (AC-3)
- [x] Daemon refuses to start on an unknown or invalid `config.toml` key; menubar names key and line (AC-41)
- [x] Unimplemented endpoints return 501 naming the endpoint; missing objects return Docker-format 404 (AC-29, AC-7)

## First container

- [x] `docker pull alpine` streams progress and `docker images` lists it (AC-8)
- [x] `docker run --rm alpine echo hello` prints `hello` in its own Apple container VM, labelled as Docker-created (AC-10, AC-11)
- [x] Container metadata survives daemon restart; store and containers dirs are excluded from Time Machine (AC-12, AC-42)
- [x] `container`-created containers are invisible and untouchable through the Docker API (AC-30)

## Container lifecycle

- [x] stop/start/restart/kill/rm work on a running container (AC-13)
- [x] pause freezes the container and `inspect` reports `State.Paused` (AC-13.a)
- [x] `docker ps` filters by label, name, status (AC-14)
- [x] env, workdir, entrypoint, and command reach the container process (AC-18)
- [x] Bind mounts work, read-write by default, `:ro` enforced (AC-16, AC-17)
- [x] `-p` publishes on all interfaces; `-p <ip>:...` binds only that IP (AC-15, AC-15.a)
- [x] `docker logs` supports tail/follow/timestamps; on-disk log capped at 100 MiB (AC-19, AC-51)
- [x] `docker exec` works with and without TTY (AC-20)
- [x] `docker cp` copies in and out (AC-21)
- [x] `docker stats` reports CPU, memory, net I/O (AC-22)
- [x] `docker events` emits lifecycle events in order (AC-23)
- [x] Healthcheck runs, `State.Health` reported, `health_status` events emitted (AC-52, daemon part)

## Images and registries

- [x] Image tag/inspect/rm/prune (AC-24)
- [x] Pull from an authenticated private registry; no password ever lands under `~/.pratico` (AC-9, AC-50)
- [x] Push to a registry; fresh pull returns same digest (AC-25)

## Embedded runtime (design: docs/design/runtime.md) — replaces the `container` CLI backend

- [x] Kernel and vminit assets pinned and verified; images (pull, list, inspect, tag, rm, save) on the ContainerizationOCI store (`make e2e-embedded`)
- [x] Per-container shim owns the VM: create/start/stop/kill/wait/logs/rm, VM-level pause; exit codes survive a daemon restart
- [x] `docker run -i/-it` and attach stdin through the shim, TTY resize; healthchecks on the agent; start errors in Docker's wording
- [x] Exec, cp, stats, pause through the guest agent (the CLI backend's freezer agent and `container stats` sampler go with that backend in the last step)
- [x] pratico-net 4a: user-space switch (isolation, anti-spoofing), IPAM, gateway ARP/ping, embedded DNS (Docker names, `.pratico.internal`, `host.docker.internal`, external names via the Mac's resolver); `bridge`, `none`, custom networks
- [x] pratico-net 4b: Swift uplink to the internet and the Mac (UDP, unprivileged ping, TCP endpoint), soak-tested; internal networks stay sealed
- [x] pratico-net 4c: published ports (TCP and UDP, host IP or all interfaces, random host ports, Docker's "port is already allocated"), surviving daemon restarts
- [x] Hot connect/disconnect on running containers: 4 NIC slots per VM (the VZ maximum), disconnect cuts traffic at the switch, default route and published ports follow the primary network
- [x] `docker login` and push on the OCI client: credentials checked with the registry, kept in pratico's own Keychain items, used when a client sends none
- [x] Scans read the embedded store (exports go through the image backend)
- [x] Registry trust you choose and can see: plain HTTP for loopback (as Docker) and listed hosts, extra CAs added to the system's roots, system proxy/PAC; `docker info`, pull/push output and the menubar say so; kept logins removable from the menubar
- [x] Agent-native pratico, first step (D-48): MCP endpoint with image checks, throwaway runs, kept services, and changes limited to agent-made containers. Next with the own VM's flight recorder: what an agent's containers ran and connected to.
- [x] Agent-native pratico, the rest (closed 2026-11-20): whether an image is safe (`image_check`), throwaway isolated runs, scan results and SBOMs (`image_sbom`), use from Claude Code (docs/agents.md). New agent work comes as its own items
- [x] Egress visibility and protection (D-51): flows named (DNS, SNI, Host) and recorded, threat feeds (Feodo, SSLBL, Spamhaus DROP; URLhaus and ThreatFox with a key), allowlists
- [x] Own VM, self-contained (last in the Features discussion; decided 2026-11-15): pratico stops depending on upstream releases and binaries for what runs in and drives a VM. Containerization (Apache-2.0) is forked whole, host package and guest `vminitd`/`vmexec` at one pinned commit, since both speak one agent protocol; LICENSE, NOTICE, and modified files marked; upstream security fixes merged by us, as for the kernel.
  - [x] Build VM: `scripts/build-kernel.sh` builds in a VM of the installed pratico (the previous release's kernel and init) from pinned inputs only; `REPRO=1` builds twice and compares, and the result must match `vm/kernel/vmlinux.sha256`
  - [x] Own kernel (D-52): Linux 6.18.63 LTS with containerization's configuration plus BPF/BTF, tracepoints, uprobes, Landlock (balloon and seccomp filter were already on); configuration shipped in the app, GPL source offer in the acknowledgements; boots ≈30 ms slower than Kata's
  - [x] Own init (D-53): `vminitd` and `vmexec` built from the vendored source with Swift 6.3.3's static Linux SDK, reproducible, tagged by content; the daemon rebuilds `initfs.ext4` when it changes
  - [x] Seccomp (D-54): `vmexec` installs a filter pratico compiles itself (no runc, no libseccomp); Docker's default profile on, `seccomp=<file>` in Docker's or the OCI format, `unconfined` and `--privileged` unfiltered
  - [x] Live limits: `docker update` writes the container's cgroup in the guest (`cpu.max`, `cpu.weight`, `cpuset.cpus`, `memory.max`, `memory.low`, `memory.swap.max`, `pids.max`) within the VM's size; more vCPUs or memory than the VM booted with still needs a restart (Virtualization.framework has no vCPU hotplug, memory cannot grow past boot size)
  - [x] Memory balloon: measured and not kept (D-63, 2026-11-20). Idle VMs do hold memory the Mac needs (16 alpine containers that each touched 512 MiB: 13,179 MiB held against 4,810 MiB, unchanged after 5 min idle, guests reporting it free), but Virtualization.framework's traditional balloon does not give it back: 767 MiB held in a guest's balloon for 100 s left the VM's footprint unchanged (4 KiB guest pages on 16 KiB host pages). 16 KiB guest pages would break software built for 4 KiB (jemalloc). A container gives its memory back when it stops
  - [x] eBPF in the guest (decided 2026-11-15): kernel with BPF syscall, JIT, BTF, BPF LSM (`lsm=…,bpf`), `unprivileged_bpf_disabled=1`; probes in restricted C built with clang in the build VM against the shipped kernel's types, loaded by `vminitd` (Swift, its own loader: no libbpf, no CO-RE) before the container's process starts; events through a bounded ring buffer over vsock, overflow dropped and counted. Network policy stays in the Mac's switch (it holds if a guest kernel falls); eBPF is for what only the guest sees
    - [x] Flight recorder: every exec and exit (argv, uid, parent, code) and the process behind each connection, joined with the switch's flows; in the API, events, the menubar, and the MCP server. Done (D-56): exec/exit/TCP connect probes, loader in vminitd (no libbpf), per-container log, `GET /pratico/containers/{id}/activity`. Done (D-57): connections joined with the switch's flows (names, blocks), MCP `activity` tool and `run`'s activity, a short-lived container's whole record. Done (D-58): the menubar's Connections window. Done (D-59): UDP destinations. Recorder events are served by the activity endpoint, the Connections window and MCP, not Docker's `/events`
    - [x] Boot trimming (D-53): 1000 Hz and no EFI/ACPI took the kernel from 128 to 70 ms to init; agent polled every 2 ms; vmexec's cold load measured (27 ms at a container's first start, 3 ms warm); pre-loading it at boot (`vmexec --help` from vminitd) cut that to 12 ms in the guest but showed no end-to-end gain over host noise, so it was not kept (2026-11-17), and a multi-call binary would need vmexec to run before Swift's async runtime starts threads (it unshares a user namespace); closed 2026-11-20 at ≈240 ms for `docker run --rm alpine true`, reopened only by a measured regression or a feature that adds boot cost
- [x] Embedded is the default: the app bundles `pratico-shim`, the kernel and `vminit`; acknowledgements (licenses) in the app and DMG
- [x] `container` CLI adapter, `/etc/hosts` sync, freezer agent and default-network anchor removed; SPEC and docs updated

## Networks and volumes

- [x] Default `bridge` network present at start (AC-26); networking works without restricted entitlements such as `com.apple.vm.networking` (no paid Apple Developer account)
- [x] Custom networks: create/connect/disconnect/rm, containers resolve each other by name (AC-27)
- [x] Named volumes shared between containers; create/ls/rm/prune, anonymous volumes for `-v /path` and image `VOLUME`, `rm -v`, Disk menu slice and cleanup (AC-28, D-32)

## Login

- [x] Daemon starts at login when `start_at_login = true` (AC-4); `false` removes the login job within 5 s of the change, no restart

## Menubar

- [x] Status item shows daemon state and the running-container count, updating within 2 s, including on daemon death (AC-31, AC-32, AC-35; "N Docker + M Apple" went with the `container` CLI backend)
- [x] Containers menu lists running containers with name, image, ports, health; open port, stop, restart (AC-33, D-33)
- [x] Usage measure shows total CPU % and memory of Docker containers (AC-43)
- [x] Alert on a port published on a non-loopback address; none for loopback (AC-36)
- [x] Alert on a container turning `unhealthy` (AC-52, menubar part); Alerts menu with Clear Alerts… (FR-32)
- [x] View logs: daemon log in `~/.pratico/daemon.log`, opened in Console; Status submenu and Copy Diagnostics (FR-32)
- [x] View alerts quick action (FR-32): blocks notify once per image; Scan Results shows every image and finding
- [x] Scanners menu: which scanners are found (osv-scanner, grype, trivy, `scan_custom`), versions, Homebrew install help; your own scanners through a JSON contract, managed in Settings › Scanners; Scan Now and a Scan Results window showing which scanner found what (D-24)
- [x] Disk menu: allocated sizes by kind, running vs stopped, leftovers, largest items, free space; cleanup that lists and confirms; `docker system df` / `prune` (D-31)
- [x] Preferences panel (⌘,) shows effective values and source; saving writes only the changed key (AC-37)

## Snapshot

- [x] Snapshot from the menubar writes a plain `.tar.gz` of JSON with `manifest.json` (AC-38.a)
- [x] Restore recreates containers, networks, volumes, and starts the containers that ran (AC-38)
- [x] Restore skips and reports existing names (AC-39); the menubar shows a dry run first
- [x] Restore refuses an unsupported `format_version` and changes nothing (AC-39.a)

## Bounds, performance, compatibility

- [x] Connection and request-body limits hold: 65th connection handled cleanly, RSS ≤ 100 MiB (AC-47)
- [x] 100 start/stop cycles leave idle fd count unchanged (AC-48)
- [x] Oldest allowed and current Docker CLI both pass; 20.10 rejected like Docker Engine (AC-49)
- [x] `/var/run/docker.sock` on request: help popup with the `sudo ln -s` and optional boot-job commands; pratico never asks for root (D-30)
- [x] Containers mounting `/var/run/docker.sock` reach pratico; any host Unix socket bind is relayed (D-30, embedded)
- [x] `docker run --rm alpine true` P99 ≤ 1500 ms (AC-44): 436 ms
- [x] Control calls P99 ≤ 50 ms with 100 containers (AC-45): ≤ 2 ms
- [x] 64 concurrent clients with 32 running containers: zero errors, RSS ≤ 100 MiB (AC-46): 48 MiB

## Release

- [x] `make dmg` produces an ad-hoc signed `.dmg` (with virtualization entitlement) that installs `Pratico.app` (menubar + bundled daemon helper); AC-1 and AC-10 pass on the installed build
- [x] DMG background and bundled README walk the user through Gatekeeper approval
- [x] `make release VERSION=x.y.z` refuses non-semver or mismatched versions and a dirty tree, then tags `vX.Y.Z` and publishes the DMG + SHA-256 to GitHub
- [x] `make install` copies `Pratico.app` to `/Applications` with no Gatekeeper prompt (`make run` installs and opens it)
- [x] Homebrew (2026-11-20): `brew install --cask gleicon/pratico/pratico` from the tap `gleicon/homebrew-pratico` (trusted once with `brew trust`); `make release` updates the cask from the release's SHA-256 (`scripts/cask.sh`, rerunnable); `homebrew/cask` itself waits on notarization
- [x] When a Developer ID identity and notary credentials are configured (`SIGN_IDENTITY`, `NOTARY_PROFILE`), `make release` signs, notarizes, staples, and checks with Gatekeeper; ad hoc remains the default (path written, untested until a paid Apple Developer account exists)

## Known gaps (found while building, not yet scheduled)

- [x] More than 4 networks per container: one NIC per VM with an address per network (D-43, 2026-11-15)
- [x] `--cap-add` / `--cap-drop` applied through `LinuxCapabilities`, execs included (D-45; e2e: `--cap-drop ALL`, `exec --privileged`)
- [x] `docker cp` with a stopped container: read from its ext4 rootfs on the Mac; copies in rewrite the rootfs (no VM), and the container cannot start meanwhile
- [x] `docker save` of several images at once; `docker load` (OCI archives, Docker 25+); request bodies of `cp` in and `load` stream to disk past the 64 MiB in-memory limit
- [x] `docker build` through buildx's docker-container driver: BuildKit in a pratico VM, results loaded (D-50)
- [x] Hot-connect and uplink e2e checks wait on state (`eventually`, listener and size polls), not time; pass with every core busy (the socket-mount one was a real start-order race, D-34)
- [x] Volume copy-up: a new empty volume gets the image's files at its mount path, as in Docker; `nocopy` honored
- [x] `tmpfs` mounts (`--tmpfs`, `--mount type=tmpfs`), Docker's default options, size and mode
- [x] The menubar's new windows (Settings, Scan Results, Connections) checked on a real screen (2026-11-20)

## Backlog

- [x] Image scanners work against pratico unchanged via `docker save` (osv-scanner, grype verified; trivy, snyk use the same path) (D-23)
- [x] Automatic image scanning: osv-scanner + grype + CISA KEV after each pull and daily; `scan_block` levels; serious findings stop and block the image's containers; menubar alerts and notifications (D-24)
- [x] Scanning follow-ups: EPSS, syft SBOMs, Allow This Image (D-38..D-40); spotter waits on an all-files hash mode upstream; Artifact Hub undecided

## Next (decided 2026-11-20)

- [x] Buildpacks (D-60): `pack build` verified against pratico (lifecycle container with the socket mounted, result in pratico's store); small gaps fixed, the rest documented as not working; docs/build.md and the site mention it only once it passes
- [x] Exec drift tag (D-61): each exec of a file the container added or changed, or ran from a mount, is marked `FromImage: false` in the activity endpoint and MCP `activity`/`run`; no alert (builds do this all the time) except for containers in ask mode
- [x] Ask mode at the switch (D-62): an opted-in container (label, or MCP `run` flag) holds a connection to a destination not yet allowed; the menubar asks allow / deny / always for this container, answers go into the allowlist; unanswered after 30 s it is refused and recorded ("not answered"); Docker clients unaffected unless they opt in
- [x] Memory balloon gate (D-63): measured; the balloon cannot return memory on Virtualization.framework with 4 KiB guest pages, so none is built
- [x] Host memory follows container use, measured and not built (2026-11-20; D-63): zeroing freed guest pages made the Mac slower (8 GiB filled beside 16 idle containers in 4.8 s against 4.0 s without zeroing and 3.3 s with no containers), since the guest zeroes all its memory at boot; macOS's compressor and swap already keep the Mac close to its speed. Criterion was: with many containers, the host's memory pressure rises and falls with what they use, and the rest of the machine feels as fast as before. Kept only if measured so. macOS: try freed guest pages zeroed (`init_on_free=1`) so the host's compressor holds them at almost no cost, guest page cache bounded; measure under host pressure (swap writes, compressed memory, a foreground app's latency) and the zeroing's CPU cost

## Remote Linux hosts (future, after Next; decided 2026-11-20)

Local Mac development still comes first. When pratico runs on remote hosts:

- KVM required (one VM per container, as on the Mac); hosts without it are refused, no namespaces-only fallback
- SSH only: the docker CLI through `ssh://` contexts; the menubar through a native SSH client (swift-nio-ssh), no spawned `ssh`; no TCP API port and no authentication of pratico's own
- The menubar is the one place to see every host (containers, scans, alerts, counters, connections from the `/pratico/*` endpoints) and sets the active host by writing the docker context; docker commands go straight to that host
- No call forwarding, proxy, or orchestrator; several hosts, each picked explicitly
- No pratico CLI while the docker CLI can express what pratico does
- Design and slices: docs/design/remote.md. arm64 first (built and tested on the Mac through nested KVM), then x86_64; Cloud Hypervisor as the VMM (to confirm before a VM boots); TAP NICs read by the switch, `CAP_NET_ADMIN` only
- [x] Slice 1 (2026-11-20): the daemon and shim compile for Linux; seams for VM boot (Cloud Hypervisor), registry transport (AsyncHTTPClient), secrets (0600 file), log follow (inotify), sparse copies, shim exit; unit tests pass on Linux (`scripts/linux-check.sh`). Found on the way: the Mac daemon never reaped its shims (fixed)
- [x] NIC on Linux settled (2026-11-20, docs/design/remote.md decision 3): a network namespace per VM made through a user namespace, TAP and Cloud Hypervisor in it, AF_PACKET relay to the switch; no host capability; AppArmor profile for the shim on Ubuntu. Cloud Hypervisor kept over QEMU (host vhost-vsock, larger device model) and Firecracker (no virtio-fs)
- [x] Slice 2 (2026-11-21): the test host on the Mac (`make e2e-testhost`, 11 checks): Ubuntu 24.04 on `--runtime pratico-testhost` (nested virtualization, only with `PRATICO_TESTHOST=1`; the shipped kernel's KVM stays inert elsewhere), the Linux daemon with Cloud Hypervisor v55.0 runs containers through `docker -H ssh://` (`--network none`)
- [x] Slice 3 (2026-11-21): networking and egress through the switch on Linux (a user and network namespace per VM, TAP and AF_PACKET relay, `Sources/CPratico/netns.c`); `virtiofsd` 1.15.0 built static and pinned (`scripts/build-virtiofsd.sh`) for volumes and bind mounts; `make e2e-testhost` 21 checks; `e2e/run.sh` runs in the test host, slow under nesting (a boot takes about 15 s)
- [x] Slice 4 (2026-11-22): `sudo pratico-daemon install` from the release's Linux tarball (`make linux-dist`): hardened systemd unit as the `pratico` user with no capability, sysusers, AppArmor profile for the shim, upgrade keeps containers, `uninstall` (keeps images unless `--purge`); static (musl) daemon and shim, no libcurl, libarchive and codecs at current releases (`scripts/build-libs.sh`); the test host boots systemd and a non-root user installs, uses, upgrades and uninstalls (docs/linux-hosts.md)
- [x] Slice 5 (2026-11-23): Docker Host menu over the docker contexts; each Linux host's version, containers and alerts through pratico's own SSH (swift-nio-ssh, key files, known_hosts only); ssh-agent when swift-nio-ssh supports it (#230)
- [x] Slice 6 (2026-11-25): x86_64 hosts: kernel, probes, init reproducible and pinned; seccomp for x86_64 (x32 refused); static daemon, shim, virtiofsd and C libraries from upstream sources; `make e2e-worker` on a real x86_64 host with AppArmor, required by `make release`; nothing from Docker on hosts (pratico answers `docker system dial-stdio`)
- [ ] ssh-agent for the menubar's SSH, once apple/swift-nio-ssh ships agent signing (#189, #230, PR #220)
- [ ] Swift 6.4: checked 2026-11-23, staying on 6.3.3 (the newest 6.3 patch) while apple/containerization builds vminitd with 6.3.0 and Xcode ships 6.3.3; the static SDK's C libraries pratico links come from `scripts/build-libs.sh` at current releases. Move when upstream or Xcode moves to 6.4
- Memory follows use there too, through virtio-balloon free page reporting (KVM returns pages the guest frees); same criterion as on the Mac

## Components as their own projects (backlog, after the Linux hosts slices; planned 2026-11-20)

Pratico grew pieces that stand alone. Review each before extracting any: who else would use
it, how clean its boundary is, whether it has its own tests, and whether a separate project
would get it more review (most are security-sensitive). Extraction costs a release process
and upkeep per project, so only pieces that pass the review move out.

- [ ] Review the candidates and decide which to extract, which to keep in pratico, and in what order:
  - Userspace switch and egress control (`Net/`, ~2,500 lines): L2 switch, NAT uplink, named flows, allowlists, threat feeds, ask mode
  - Guest BPF loader and flight recorder (`VminitdCore/BPFObject.swift`, `Recorder.swift`, `vm/bpf`, ~600 lines): loads CO-RE-free probes with no libbpf
  - Seccomp compiler (`ContainerizationOCI/LinuxSeccomp+BPF.swift`, ~250 lines): Docker and OCI profiles to classic BPF
  - Registry client with a visible trust policy (`RegistrySession`, `RegistryTransport`, ~900 lines): tokens, realm checks, digests, plain-HTTP and extra-CA rules, two transports
  - Image scanning orchestration (`Scan*`, ~750 lines): osv-scanner, grype, trivy, KEV, EPSS merged into one report
  - Safe archive handling (`Tar`, `Archive`, `DockerArchive`, ~600 lines): extraction that never writes through links, legacy `docker save` conversion
  - MCP server for containers (`MCP*`, ~470 lines)
  - Reproducible kernel and init builds (`scripts/build-*.sh`, `vm/`)
  - The vendored containerization fork (`Vendor/containerization`)
- [ ] For each one kept for extraction: its own package and tests, pratico depending on it by version, its own release with a proper tag

## Won't do (decided 2026-11-20)

- TLS inspection and a per-install CA: egress names every flow from DNS, SNI, or Host; a man-in-the-middle CA is a key to protect and new attack surface
- BPF LSM file audit and exec/write prevention: +63 ms on every boot; the exec drift tag covers downloaded-and-run binaries
- Seccomp `user_notif` ask mode: `execve`/`openat` prompts would be noise; `connect` is asked at the switch
- On-demand `perf_event` profiling: stacks need unwinding and symbols across arbitrary images; language profilers work in containers
- `docker build` with no setup: needs a BuildKit of pratico's own to maintain, for two lines typed once
- A memory balloon or zeroed freed pages on macOS: the balloon releases nothing and zeroing made the Mac slower (D-63); a stopped container gives its memory back
- Backup and restore with volume data, IPv6 on pratico-net (refused with an error), a local OCI registry: none serves local development
