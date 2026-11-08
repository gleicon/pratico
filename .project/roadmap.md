# Roadmap: pratico v0.1.0

Source: `SPEC.md`. Each task is done when its ACs pass in the end-to-end suite.

v0.1.0 ships functional, buildable from Makefiles, and packaged as a `.dmg`.

## Skeleton

- [x] `make` builds daemon and menubar app; `make test` and `make e2e` run unit and end-to-end suites
- [~] Menubar Start/Stop runs the bundled daemon helper (`SMAppService`); menu shows state, socket path, API version; socket answers `docker version` against a pinned API version; e2e suite drives the real `docker` CLI (AC-1, AC-2, AC-5, AC-6, AC-34, AC-40, AC-53)
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

## Networks and volumes

- [ ] Default `bridge` network present at start (AC-26); networking works without restricted entitlements such as `com.apple.vm.networking` (no paid Apple Developer account)
- [ ] Custom networks: create/connect/disconnect/rm, containers resolve each other by name (AC-27)
- [ ] Named volumes shared between containers; create/ls/rm (AC-28)

## Login

- [ ] Daemon starts at login when `start_at_login = true` (AC-4)

## Menubar

- [ ] Status item shows daemon state and `N Docker + M Apple`, updating within 2 s, including on daemon death (AC-31, AC-32, AC-35)
- [ ] Clicking lists running containers with origin, name, image (AC-33)
- [ ] Usage measure shows total CPU % and memory of Docker containers (AC-43)
- [ ] Alert on a port published on a non-loopback address; none for loopback (AC-36)
- [ ] Alert on a container turning `unhealthy` (AC-52, menubar part)
- [ ] View logs and view alerts quick actions (FR-32)
- [ ] Preferences panel shows effective values and source; saving writes only the changed key (AC-37)

## Snapshot

- [ ] Snapshot from the menubar writes a plain `.tar.gz` of JSON with `manifest.json` (AC-38.a)
- [ ] Restore recreates containers, networks, volumes (AC-38)
- [ ] Restore skips and reports existing names (AC-39)
- [ ] Restore refuses an unsupported `format_version` and changes nothing (AC-39.a)

## Bounds, performance, compatibility

- [ ] Connection and request-body limits hold: 65th connection handled cleanly, RSS ≤ 100 MiB (AC-47)
- [ ] 100 start/stop cycles leave idle fd count unchanged (AC-48)
- [ ] Oldest allowed and current Docker CLI both pass; 20.10 rejected like Docker Engine (AC-49)
- [ ] `docker run --rm alpine true` P99 ≤ 1500 ms (AC-44)
- [ ] Control calls P99 ≤ 50 ms with 100 containers (AC-45)
- [ ] 64 concurrent clients with 32 running containers: zero errors, RSS ≤ 100 MiB (AC-46)

## Release

- [~] `make dmg` produces an ad-hoc signed `.dmg` (with virtualization entitlement) that installs `Pratico.app` (menubar + bundled daemon helper); AC-1 and AC-10 pass on the installed build
- [~] DMG background and bundled README walk the user through Gatekeeper approval ("Open Anyway" or `xattr -dr com.apple.quarantine`)
- [x] `make release VERSION=x.y.z` refuses non-semver or mismatched versions and a dirty tree, then tags `vX.Y.Z` and publishes the DMG + SHA-256 to GitHub
- [ ] `make install` copies `Pratico.app` to `/Applications` with no Gatekeeper prompt
- [ ] When a Developer ID identity and notary credentials are configured, `make dmg` signs with it and notarizes; ad-hoc remains the fallback (blocked until a paid Apple Developer account exists)

## Backlog

- [x] Image scanners work against pratico unchanged via `docker save` (osv-scanner, grype verified; trivy, snyk use the same path) (D-23)
- [ ] Automatic image scanning: scan pulled and built images (OSV for vulnerabilities and OpenSSF `MAL-` malicious-package advisories, plus a Snyk-like check), keep results per image, surface findings in menubar alerts — design pending
- [ ] Discuss and design a container manager geared towards agents: not just an MCP server, but a way for developers to use containers for tests, agents, and builds from Claude Code
