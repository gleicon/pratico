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
- [ ] Egress intercept: sandwich-proxy engine on container HTTP/HTTPS flows, per-container opt-in, log/replay/HAR/threat feeds
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
- [ ] Optional volume data in snapshots (definitions only today)

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
- [~] DMG background and bundled README walk the user through Gatekeeper approval ("Open Anyway" or `xattr -dr com.apple.quarantine`)
- [x] `make release VERSION=x.y.z` refuses non-semver or mismatched versions and a dirty tree, then tags `vX.Y.Z` and publishes the DMG + SHA-256 to GitHub
- [x] `make install` copies `Pratico.app` to `/Applications` with no Gatekeeper prompt (`make run` installs and opens it)
- [ ] When a Developer ID identity and notary credentials are configured, `make dmg` signs with it and notarizes; ad-hoc remains the fallback (blocked until a paid Apple Developer account exists)

## Known gaps (found while building, not yet scheduled)

- [ ] More than 4 networks per container (Virtualization.framework allows 4 NICs per VM)
- [ ] IPv6 on pratico-net
- [ ] `docker cp` with a stopped container (the guest agent needs a running VM)
- [ ] `docker save` of several images at once
- [ ] A per-install CA for egress interception (with the egress task)
- [ ] `docker build` (BuildKit or an equivalent)
- [ ] Hot-connect and uplink e2e checks are flaky (the socket-mount one was a real start-order race, fixed in D-34) when the Mac is under load; make them wait on state, not time
- [ ] Volume copy-up: a new empty volume gets the image's files at its mount path, as in Docker
- [ ] `tmpfs` mounts (`--tmpfs`, `--mount type=tmpfs`)
- [ ] The menubar's new windows (Settings, Scan Results) need a visual pass on a real screen

## Backlog

- [x] Image scanners work against pratico unchanged via `docker save` (osv-scanner, grype verified; trivy, snyk use the same path) (D-23)
- [x] Automatic image scanning: osv-scanner + grype + CISA KEV after each pull and daily; `scan_block` levels; serious findings stop and block the image's containers; menubar alerts and notifications (D-24)
- [ ] Scanning follow-ups: spotter on image filesystems (needs an all-files hash mode upstream), EPSS, Artifact Hub, syft SBOMs, menubar "allow image" action
- [ ] Discuss and design a container manager geared towards agents: not just an MCP server, but a way for developers to use containers for tests, agents, and builds from Claude Code
