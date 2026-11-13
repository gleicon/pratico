# Specification: pratico v0.1.0

*Prático* (Portuguese): the harbour pilot who guides ships through narrow, complex channels as they come and go. The project was formerly named "cocker".

Previous long-form spec preserved in `SPEC.v0.md` (still under the old name). Where the two disagree, this file wins; it folds in the decisions recorded in `DS-HANDOFF.md`.

## Problem

Developers on Apple silicon Macs want the Docker toolchain (`docker`, `docker compose`, tools that expect a Docker socket) without running Docker Desktop's shared Linux VM. Apple's `container` runtime gives each container its own lightweight VM, but it speaks its own CLI, not the Docker Remote API. Pratico bridges the two: a local daemon that serves the Docker Remote API and runs every container as an Apple container, plus a menubar app that shows Docker-created and `container`-created workloads in one place.

## Scope

In scope (v0.1.0):
- `pratico-daemon`: Docker Remote API server on a Unix socket, backed by Apple's containerization runtime.
- Docker API groups: system (ping, version, info, events), containers (create, start, stop, restart, kill, pause, unpause, wait, rm, list, inspect, logs, exec, cp/archive, stats, healthcheck), images (pull, push, list, inspect, tag, rm, prune), networks (create, list, inspect, connect, disconnect, rm), volumes (create, list, inspect, rm).
- `pratico-menubar`: SwiftUI status item with a daemon status indicator, usage measure, unified Docker + Apple view, quick actions, alerts, and a preferences panel.
- `Pratico.app`: a menubar app bundling the daemon as a background helper (a launch agent the menubar installs). Pratico ships no CLI; `docker` and Apple `container` are the CLIs.
- Configuration via `~/.pratico/config.toml` with built-in defaults; the file holds overrides only.
- Snapshot: export and restore of container metadata and configuration as a `.tar.gz` file (not memory or disk state).

Out of scope (v0.1.0):
- Any `pratico` CLI, including `pratico system start|stop|status` and Docker-compatible commands (`pratico run`, `pratico ps`, ...). Users run `docker` with `DOCKER_HOST`, or `container` directly; daemon control lives in the menubar.
- `docker build` / BuildKit (v0.2.0).
- Local endpoint gateway: internal API / MCP server that attaches a container to a local endpoint so requests run it as an on-demand worker (v0.2.0, see `ROADMAP.md`).
- Docker Compose orchestration beyond what plain API coverage gives (v1.1).
- Swarm, plugins API, Kubernetes, GPU passthrough, Windows, Intel Macs.
- Remote TCP listener.
- Multi-user isolation.

## Users

- **Developer using Docker tooling**: runs existing `docker` commands and scripts against pratico without changing them, beyond setting `DOCKER_HOST`.
- **Developer using Apple `container`**: keeps using `container` directly and sees those containers in the menubar next to Docker-created ones.
- **Menubar user**: starts and stops the daemon, checks what is running, reads logs and alerts without opening a terminal.

## Functional Requirements

Daemon lifecycle
- FR-1: The app shall start the daemon helper and create the socket at `~/.pratico/docker.sock` when the user picks Start in the menubar, and on app launch when the daemon is not running.
- FR-2: The app shall stop the daemon helper and remove the socket when the user picks Stop in the menubar.
- FR-3: When pratico's runtime cannot open (kernel, init, or `pratico-shim` missing or unusable), the daemon shall not start (exit 3) and the menubar shall show the reason.
- FR-4: The app shall install the daemon's launch agent so it starts at user login when `start_at_login` is true (default true).
- FR-5: The menubar shall show daemon state (running/stopped), socket path, and API version.

Docker API compatibility
- FR-6: The daemon shall answer `GET /_ping` and `GET /version` with the fields Docker CLI uses for API version negotiation (`ApiVersion`, `MinAPIVersion`, `Os`, `Arch`).
   - FR-6.a: `ApiVersion` shall be the latest Docker Engine API version published when implementation starts; the version is pinned in source and its endpoint behaviour follows that version's spec.
   - FR-6.b: `MinAPIVersion` shall equal the `MinAPIVersion` advertised by the Docker Engine release that ships that API version.
- FR-7: The daemon shall return Docker-format JSON errors (`{"message": "..."}`) with the HTTP status Docker returns for the same condition (404 no such container/image, 409 conflict, 400 bad parameter, 500 internal).
- FR-8: The daemon shall pull OCI and Docker v2 images from a registry when it receives `POST /images/create`, streaming progress as JSON lines.
- FR-9: The daemon shall forward the `X-Registry-Auth` header to the registry on pull and push.
- FR-10: The daemon shall create and run each Docker container as an Apple container (one VM per container). (On the embedded runtime, D-26, the VM is run by pratico itself through apple/containerization.)
- FR-11: The daemon shall persist the Docker-side metadata for each container (name, labels, Docker config, port bindings, mounts, restart policy) under `~/.pratico/containers/`.
- FR-12: The daemon shall support container create, start, stop (with timeout), restart, kill (with signal), pause, unpause, wait, remove (with `force`), list (with `all` and label/name/status filters), and inspect.
   - FR-12.a: A paused container shall execute no process instructions until unpaused, and `docker inspect` shall report `State.Paused = true`.
- FR-13: The daemon shall publish container ports the way Docker does: `-p <host_port>:<container_port>` binds all host interfaces (`0.0.0.0`); `-p <host_ip>:<host_port>:<container_port>` binds only `<host_ip>`.
- FR-14: The daemon shall bind-mount a host directory into the container when created with `-v <host_path>:<container_path>[:ro|:rw]`.
   - FR-14.a: A mount with no mode suffix shall be read-write, matching Docker.
- FR-15: The daemon shall pass `-e` environment variables, working directory, entrypoint, and command through to the container process.
- FR-16: The daemon shall return container stdout/stderr via `GET /containers/{id}/logs`, supporting `tail`, `follow`, and `timestamps`.
- FR-17: The daemon shall run a command in a running container via the exec API, with and without a TTY.
- FR-18: The daemon shall copy files into and out of a container via `PUT|GET /containers/{id}/archive` as tar streams.
- FR-19: The daemon shall report CPU, memory, and network usage via `GET /containers/{id}/stats`, both one-shot and streamed.
- FR-20: The daemon shall emit container lifecycle events (create, start, die, stop, pause, unpause, destroy, health_status) on `GET /events`.
- FR-21: The daemon shall support image list, inspect, tag, remove, and prune.
- FR-22: The daemon shall push a tagged image to a registry via `POST /images/{name}/push`.
- FR-23: The daemon shall support network create, list, inspect, connect, disconnect, and remove, with a default `bridge` network present at start.
- FR-24: Containers on the same network shall resolve each other by container name.
- FR-25: The daemon shall support named volume create, list, inspect, and remove, and mount named volumes into containers.
- FR-26: The daemon shall return HTTP 501 with a Docker-format error naming the endpoint for any Docker API endpoint it does not implement.

Apple `container` integration
- FR-27: The daemon shall label every container it creates so containers created via Docker API can be told apart from containers created by `container` CLI.
- FR-28: The daemon shall not list, modify, or delete containers created by `container` CLI through the Docker API.

Menubar
- FR-29: The menubar status item shall show a daemon status indicator (running/stopped) and a count split into "Docker" (FR-27 labelled) and "Apple" (all other) running containers, e.g. `2 Docker + 1 Apple`.
- FR-30: The menubar app shall refresh the indicator and counts within 2 s of the daemon or a container starting or stopping, including the daemon dying unexpectedly.
- FR-31: Clicking the status item shall list each running container with its origin (Docker/Apple), name, and image.
- FR-32: The menubar app shall offer quick actions: start daemon, stop daemon, snapshot, restore snapshot, view logs, view alerts. It shall not offer a pause action.
- FR-33: The menubar app shall raise an alert only for:
   - FR-33.a: a Docker-created container publishing a port on a non-loopback address (FR-13 default `0.0.0.0` included), naming container, host address, and port;
   - FR-33.b: a container whose Docker healthcheck reports `unhealthy` (FR-41), naming the container.
- FR-34: The preferences panel (⌘,) shall show each config key with its effective value and whether it comes from the default or an override; saving a change shall write only that key to `config.toml`.

Snapshot
- FR-35: Snapshot shall write the FR-11 metadata of all Docker-created containers, plus network and volume definitions, to a single `.tar.gz` under `~/.pratico/snapshots/`, named `pratico-snapshot-<UTC timestamp>.tar.gz`.
   - FR-35.a: The tarball shall hold plain JSON files (one per container, network, volume) and a `manifest.json` with a `format_version` integer, readable with `tar` and a text editor.
- FR-36: Restore shall recreate the containers, networks, and volumes described in a snapshot tarball, skipping (and reporting) any whose name already exists.
   - FR-36.a: Restore shall refuse a tarball whose `format_version` it does not support, naming the version, and change nothing.

Configuration and storage
- FR-37: The daemon shall run with no `config.toml` present, using built-in defaults.
- FR-38: The daemon shall refuse to start and name the key and line when `config.toml` contains an unknown key or an invalid value.
- FR-39: The system shall exclude `~/.pratico/store/` and `~/.pratico/containers/` from Time Machine backups.

Menubar usage and health
- FR-40: The menubar app shall show a usage measure: total CPU % and memory used by running Docker-created containers, refreshed at least every 5 s.
- FR-41: The daemon shall run the `Healthcheck` from container config (test, interval, timeout, retries, start period) as Docker does, report it in `State.Health` on inspect, and emit `health_status` events.

## Non-Functional Requirements

Targets measured on an M1 with 16 GB RAM, image already pulled, daemon warm. Numbers marked (proposed) were accepted as the v0.1.0 bar (D-4).

- NFR-1: Latency: `docker run --rm alpine true` completes in ≤ 1500 ms P99 over 50 sequential runs (proposed).
- NFR-2: Latency: control calls (`/_ping`, `/version`, `GET /containers/json` with ≤ 100 containers) answer in ≤ 50 ms P99.
- NFR-3: Scale: the daemon handles 64 concurrent API connections and 32 concurrently running containers without errors (proposed).
- NFR-4: Bounds: every in-memory queue and buffer has a fixed maximum. Defaults: 64 API connections, 64 MiB request body (excluding streamed tar/image bodies), 1 MiB in-memory log ring per container. On limit the daemon returns an error; it never grows without bound.
- NFR-5: Memory: daemon resident memory ≤ 100 MiB with 32 running containers, excluding container VMs (proposed).
- NFR-6: Reliability: after Stop no daemon process and no socket file remain; after 100 start/stop cycles, file descriptor count at idle is unchanged.
- NFR-7: Reliability: daemon restart preserves all Docker-created container metadata; stopped containers can be started again.
- NFR-8: Compatibility: every Docker CLI release whose API version is ≥ the FR-6.b minimum, up to the current release, connects and negotiates an API version. (Older CLIs, e.g. 20.10 at API 1.41, are rejected the same way current Docker Engine rejects them.)
- NFR-9: Security: the socket is created with mode `0600`, owned by the user.
- NFR-10: Security: registry credentials are never written to disk in plaintext by pratico.
- NFR-11: Data retention: container logs are kept on disk until the container is removed, capped at 100 MiB per container (oldest data dropped first).

## Interfaces

App ↔ daemon helper
- `Pratico.app` bundles `pratico-daemon`; Start spawns the bundle's daemon in its own session and writes `~/Library/LaunchAgents/dev.pratico.daemon.plist`, which launchd reads at login; Stop sends the daemon SIGTERM and removes the plist. No `launchctl` or other external program is run. A daemon that finds another answering on its socket exits, leaving it alone. Its output goes to `~/.pratico/daemon.log` (timestamped lines, one 10 MB rotation), which the menubar's Status › View Daemon Log opens in Console; `GET /pratico/status` gives the Status menu version, runtime, start time, socket, and container counts. No pratico CLI ships.

Docker Remote API (HTTP/1.1 over `unix://~/.pratico/docker.sock`)
- System: `/_ping`, `/version`, `/info`, `/events`
- Containers: `/containers/create`, `/containers/json`, `/containers/{id}/{json,start,stop,restart,kill,pause,unpause,wait,logs,stats,archive,exec}`, `DELETE /containers/{id}`
- Exec: `/exec/{id}/{start,resize,json}`
- Images: `/images/create`, `/images/json`, `/images/{name}/{json,tag,push}`, `DELETE /images/{name}`, `/images/prune`
- Networks: `/networks`, `/networks/create`, `/networks/{id}`, `/networks/{id}/{connect,disconnect}`
- Volumes: `/volumes`, `/volumes/create`, `/volumes/{name}`

Menubar ↔ daemon
- Menubar reads state through the same Docker API socket, plus the Apple container runtime for non-Docker containers. No private channel needed for v0.1.0.

External systems
- Apple containerization runtime / `container` system service.
- OCI/Docker v2 registries (Docker Hub default).
- launchd, Time Machine (`tmutil` / exclusion xattr).

Data formats at boundaries
- Docker API JSON; tar streams for archive; JSON-lines progress streams; Docker multiplexed stdout/stderr stream framing for logs and attach.
- OCI image manifests and layers.
- `config.toml` (TOML), snapshot tarballs (`.tar.gz` of JSON files).

## Constraints

- Language: Swift, built on Apple's `Containerization` package.
- Platform: Apple silicon only, macOS 26 or later.
- No external hypervisor; Virtualization framework only.
- Engineering rules: Tiger Style (bounded loops and buffers, assertions on entry/exit, no allocation growth after init in hot paths).
- Dependencies: Apple `Containerization` plus a TOML parser and an HTTP server only if justified in writing; each one is a liability.
- Distribution: no paid Apple Developer Program account. Builds are ad-hoc signed; no restricted entitlements (e.g. `com.apple.vm.networking`) that need a provisioning profile.
- Forbidden: a shared Linux VM hosting multiple containers; sharing the host kernel; storing registry passwords in `config.toml` (the `[auth]` section in `SPEC.v0.md` is dropped).

## Acceptance Criteria

- AC-1: Given the daemon is stopped, when the user picks Start in the menubar, then `~/.pratico/docker.sock` exists with mode `0600`.
- AC-2: Given the daemon is running, when the user picks Stop in the menubar, then the socket file is gone and no daemon process remains.
- AC-3: Given the runtime's kernel is missing, when the daemon starts, then it exits 3, creates no socket, and leaves a reason naming the runtime for the menubar.
- AC-4: Given `start_at_login = true`, when the user logs out and in, then the daemon is running and `docker version` succeeds.
- AC-5: Given the daemon is running, when the user opens the menubar, then it shows running, the socket path, and an API version.
- AC-6: Given `DOCKER_HOST=unix://$HOME/.pratico/docker.sock`, when the user runs `docker version`, then both Client and Server sections print and exit code is 0.
- AC-7: Given the daemon is running, when the user runs `docker inspect nope`, then exit is non-zero and stderr contains `no such object: nope` (case-insensitive; Docker CLI 29 prints it lowercase).
- AC-8: Given no local image, when the user runs `docker pull alpine`, then progress prints and `docker images` lists `alpine:latest`.
- AC-9: Given a private registry needing auth and `docker login` done, when the user runs `docker pull <private-image>`, then pull succeeds.
- AC-10: Given `alpine` is pulled, when the user runs `docker run --rm alpine echo hello`, then stdout is `hello` and exit code is 0.
- AC-11: (Removed 2026-11-12 with the `container` CLI backend; each container is its own VM, D-26.)
- AC-12: Given container `web` exists, when the daemon is restarted, then `docker inspect web` returns the same name, labels, port bindings, and mounts as before.
- AC-13: Given `docker run -d --name t1 alpine sleep 300`, when the user runs `docker stop -t 2 t1`, `docker start t1`, `docker restart t1`, `docker pause t1`, `docker unpause t1`, `docker kill -s KILL t1`, `docker rm t1`, then each exits 0 and `docker ps -a` no longer lists `t1`. (Docker rejects one-character names, so `t` is not a valid name.)
- AC-13.a: Given a container printing a counter every 100 ms, when it is paused for 2 s, then `docker inspect` reports `State.Paused` true, no lines are logged during the pause, and lines resume after `docker unpause`.
- AC-14: Given running containers with labels `a=1` and `a=2`, when the user runs `docker ps --filter label=a=1`, then only the first is listed.
- AC-15: Given `docker run -d -p 8080:80 nginx`, when the user runs `curl -s localhost:8080` and `curl -s <host LAN IP>:8080`, then both return the nginx welcome page.
- AC-15.a: Given `docker run -d -p 127.0.0.1:8081:80 nginx`, then `curl -s localhost:8081` returns the page and `curl -s <host LAN IP>:8081` fails to connect.
- AC-16: Given a host file `/tmp/x/f` containing `hi`, when the user runs `docker run --rm -v /tmp/x:/x alpine cat /x/f`, then stdout is `hi`.
- AC-17: Given the same mount with `:ro`, when the container runs `touch /x/g`, then it fails; without a suffix, it succeeds.
- AC-18: Given `docker run --rm -e FOO=bar -w /tmp alpine sh -c 'echo $FOO; pwd'`, then stdout is `bar` then `/tmp`.
- AC-19: Given a container printing one line per second, when the user runs `docker logs --tail 2 -f <id>`, then two lines print and new lines keep arriving.
- AC-20: Given a running container, when the user runs `docker exec <id> echo ok` and `docker exec -it <id> sh -c 'tty'`, then the first prints `ok` and the second prints a `/dev/pts/` path.
- AC-21: Given a running container, when the user runs `docker cp <id>:/etc/hostname ./h` and `docker cp ./h <id>:/tmp/h`, then both succeed and contents match.
- AC-22: Given a running container, when the user runs `docker stats --no-stream`, then a row shows non-empty CPU %, MEM USAGE, and NET I/O.
- AC-23: Given `docker events` running, when a container is created, started, paused, unpaused, and removed, then `create`, `start`, `pause`, `unpause`, `die`, and `destroy` events appear in order.
- AC-24: Given `alpine` pulled, when the user runs `docker tag alpine me/a:1`, `docker image inspect me/a:1`, `docker rmi me/a:1`, `docker image prune -f`, then each exits 0.
- AC-25: Given a reachable test registry, when the user runs `docker push localhost:5000/a:1`, then push succeeds and a fresh pull returns the same digest.
- AC-26: Given the daemon just started, when the user runs `docker network ls`, then `bridge` is listed.
- AC-27: Given `docker network create n` and two containers `a` and `b` on `n`, when `a` runs `ping -c1 b`, then it succeeds; after `docker network disconnect n b` it fails; `docker network rm n` succeeds once both are removed.
- AC-28: Given `docker volume create v`, when one container writes `/v/f` and a second container mounting `v` reads it, then contents match; `docker volume rm v` succeeds after both are removed.
- AC-29: Given the daemon is running, when a client calls an unimplemented endpoint (e.g. `GET /swarm`), then the response is 501 with a JSON `message` naming the endpoint.
- AC-30: (Removed 2026-11-12 with the `container` CLI backend: pratico no longer shares a runtime with Apple's `container`.)
- AC-31: Given the daemon running with 2 Docker-created and 1 `container`-created running containers, when the menubar is shown, then the indicator shows running and the status reads `2 Docker + 1 Apple`.
- AC-32: Given the menubar is shown, when a Docker container is stopped, then the count updates within 2 s.
- AC-33: Given running containers, when the user clicks the status item, then each container is listed with origin, name, and image.
- AC-34: Given the daemon is running, when the user picks Stop then Start from the menubar, then `docker version` fails then succeeds and the indicator shows stopped then running.
- AC-35: Given the daemon is running, when its process is killed with `SIGKILL`, then the menubar indicator shows stopped within 2 s and no alert is raised.
- AC-36: Given `docker run -d -p 8080:80 nginx`, then the menubar raises one alert naming the container, `0.0.0.0`, and `8080`; given `docker run -d -p 127.0.0.1:8081:80 nginx`, then no alert is raised.
- AC-37: Given no `config.toml`, when the user changes `default_memory` in preferences and saves, then `config.toml` contains only that key.
- AC-38: Given 2 Docker containers, 1 custom network, 1 volume, when the user takes a snapshot, removes them all, and restores, then `docker ps -a`, `docker network ls`, `docker volume ls` show them again.
- AC-38.a: Given a snapshot file, when the user runs `tar -tzf` on it, then it lists `manifest.json` and one JSON file per container, network, and volume.
- AC-39: Given a snapshot containing container `web` and an existing `web`, when restoring, then the existing `web` is unchanged and the restore report names `web` as skipped.
- AC-39.a: Given a snapshot whose `manifest.json` has `format_version: 999`, when restoring, then restore fails naming `999` and `docker ps -a` is unchanged.
- AC-40: Given no `~/.pratico/config.toml`, when the daemon starts, then AC-1 passes.
- AC-41: Given `config.toml` with `bogus_key = 1`, when the daemon starts, then it refuses and the menubar error names `bogus_key` and its line number.
- AC-42: Given the daemon has started once, when the user runs `tmutil isexcluded ~/.pratico/store ~/.pratico/containers`, then both report excluded.
- AC-43: Given one Docker container running `yes > /dev/null` with `--cpus 1`, when the menubar is shown, then within 5 s the usage measure reports total CPU between 80 % and 120 % and non-zero memory; after `docker stop`, it drops to near 0 % within 5 s.
- AC-44: Given the benchmark rig in NFR preamble, when 50 `docker run --rm alpine true` runs are timed, then P99 ≤ 1500 ms.
- AC-45: Given 100 containers exist, when `/_ping`, `/version`, `/containers/json` are each called 1000 times, then P99 ≤ 50 ms each.
- AC-46: Given 64 concurrent clients hitting `/containers/json` with 32 containers running, then zero errors return and daemon RSS ≤ 100 MiB.
- AC-47: Given 65 concurrent connections, then the 65th gets a clean error or waits; the daemon does not crash and stays ≤ 100 MiB RSS.
- AC-48: Given 100 daemon Start/Stop cycles, then the idle open-file count of the daemon after cycle 100 equals cycle 1.
- AC-49: Given the oldest Docker CLI allowed by FR-6.b and the current Docker CLI, when each runs AC-6 and AC-10, then both pass; given Docker CLI 20.10, then `docker version` reports the server API version as too old, matching current Docker Engine.
- AC-50: Given `docker login` has been run, when `~/.pratico` is grepped for the password, then there is no match.
- AC-51: Given a container that writes 200 MiB of logs, then its on-disk log is ≤ 100 MiB and `docker logs --tail 1` returns the latest line.
- AC-52: Given `docker run -d --name h --health-cmd 'test -f /ok' --health-interval 1s --health-retries 2 alpine sleep 300`, then within 5 s `docker inspect h` reports `State.Health.Status` `unhealthy`, a `health_status: unhealthy` event is emitted, and the menubar raises one alert naming `h`; after `docker exec h touch /ok`, status becomes `healthy` within 3 s.
- AC-53: Given `docker version` against pratico, then `Server.ApiVersion` equals the pinned version from FR-6.a and `MinAPIVersion` equals FR-6.b.

Coverage:
- FR-1 → AC-1, AC-40
- FR-2 → AC-2
- FR-3 → AC-3
- FR-4 → AC-4
- FR-5 → AC-5
- FR-6, FR-6.a, FR-6.b → AC-6, AC-49, AC-53
- FR-7 → AC-7, AC-30
- FR-8 → AC-8
- FR-9 → AC-9, AC-25
- FR-10 → AC-10, AC-11
- FR-11 → AC-12
- FR-12 → AC-13, AC-14
- FR-12.a → AC-13.a
- FR-13 → AC-15, AC-15.a
- FR-14, FR-14.a → AC-16, AC-17
- FR-15 → AC-18
- FR-16 → AC-19
- FR-17 → AC-20
- FR-18 → AC-21
- FR-19 → AC-22
- FR-20 → AC-23
- FR-21 → AC-24
- FR-22 → AC-25
- FR-23 → AC-26, AC-27
- FR-24 → AC-27
- FR-25 → AC-28
- FR-26 → AC-29
- FR-27 → AC-11, AC-31
- FR-28 → AC-30
- FR-29 → AC-31
- FR-30 → AC-32, AC-35
- FR-31 → AC-33
- FR-32 → AC-34, AC-38
- FR-33, FR-33.a → AC-36
- FR-33.b → AC-52
- FR-34 → AC-37
- FR-35, FR-35.a → AC-38, AC-38.a
- FR-36 → AC-38, AC-39
- FR-36.a → AC-39.a
- FR-37 → AC-40
- FR-38 → AC-41
- FR-39 → AC-42
- FR-40 → AC-43
- FR-41 → AC-52
- NFR-1 → AC-44; NFR-2 → AC-45; NFR-3, NFR-5 → AC-46; NFR-4 → AC-47; NFR-6 → AC-2, AC-48; NFR-7 → AC-12; NFR-8 → AC-49; NFR-9 → AC-1; NFR-10 → AC-50; NFR-11 → AC-51

## Technical Profile

- Language: Swift 6.x
- Runtime target: macOS 26+ on Apple silicon
- Build toolchain: Swift Package Manager; `make app` assembles `Pratico.app` (no Xcode project)
- Testing: Swift Testing for unit tests; an end-to-end suite driving the real `docker` CLI against the socket for every AC

## Decisions (closed 2026-11-08)

- D-1: Minimum platform is macOS 26 on Apple silicon.
- D-2: The full Docker API scope from `DS-HANDOFF.md` stays in v0.1.0. No feature moves to a later version without the owner's approval.
- D-3: The menubar has no pause action. It offers daemon start/stop, a status indicator, and a usage measure (FR-29, FR-32, FR-40).
- D-4: The NFR-1, NFR-3, NFR-5 numbers are accepted as the v0.1.0 bar. They may be tightened later; behaviour must not change when they are.
- D-5: Advertise the latest Docker Engine API version (FR-6.a/b). Container pause/unpause is in the Docker spec, so it is implemented (FR-12, FR-12.a).
- D-6: Snapshots are plain `.tar.gz` files of JSON (FR-35.a).
- D-7: Alerts cover only ports published on non-loopback addresses and Docker-healthcheck `unhealthy` status (FR-33). "Frozen container" maps to Docker's healthcheck, the mechanism Docker implements for it.
- D-8: Where Docker has a default, pratico uses it. Published ports bind `0.0.0.0` unless a host IP is given (FR-13); FR-33.a alerts on it.
- D-9: v0.1.0 builds from Makefiles (`make`, `make test`, `make e2e`, `make install`, `make dmg`) and ships as a `.dmg`.
- D-10: No paid Apple Developer account for now. `make dmg` ad-hoc signs with the virtualization entitlement; users approve the app via Gatekeeper ("Open Anyway" or `xattr -dr com.apple.quarantine`), guided by the DMG background and a bundled README. `make install` from source avoids Gatekeeper. Developer ID signing and notarization run only when an identity is configured.
- D-11: Networking must work without restricted entitlements, since none can be granted without a paid account (D-10).
- D-12: Pratico ships no CLI (supersedes `pratico system start|stop|status`). It is a Mac app: menubar item, config window, and listeners serving `docker` and Apple `container`.
- D-13: The listeners run in a background helper (`pratico-daemon`) inside `Pratico.app`, started by a per-user launch agent the menubar writes, so containers survive the menubar UI quitting and the app can detect the helper dying (AC-35). Not `SMAppService` (2026-11-12): with ad-hoc signing (D-10) its record pins the daemon's code signature, and launchd refuses the daemon after any rebuild or update. A start that does not answer within 30 s is reported, pointing at the daemon log.
- D-14: `config.toml` v0.1.0 keys are flat (no tables): `start_at_login` (bool, default `true`), `default_cpus` (int 1–64, default `4`), `default_memory` (int MiB 64–1048576, default `1024`). CPU and memory defaults apply when a Docker request sets no limit. Parsed by a built-in subset parser, not a TOML dependency. The daemon exits 4 on a config error and writes the reason to `~/.pratico/daemon.err`.
- D-15: Pause uses the guest kernel's cgroup2 freezer, because the Apple runtime has no pause. On pause, the daemon opens a root `container exec -i` agent. The agent moves itself to the namespace root cgroup and moves every other process into `/sys/fs/cgroup/pratico`. Then it freezes that group. A new exec joins PID 1's cgroup, so only an agent started before the freeze can thaw it. Unpause sends the agent a line. Paused state lives only in the daemon, not on disk. If the daemon exits, the agent's stdin closes and the container thaws. A frozen VM ignores `container stop`, `kill`, and `rm`, so a container must never stay frozen with no agent. Stop, kill, and force-remove thaw first. Pause needs `/bin/sh` in the image.
- D-16: Bind mounts follow Docker. `-v` creates a missing host directory, and `--mount type=bind` refuses a missing source. Both map to the Apple runtime's `-v src:dst[:ro]`. Named volumes, `tmpfs`, and other mount types return 400 until the volumes task. `docker inspect` reports `Mounts` from the stored HostConfig.
- D-17: The Apple runtime has no exec or file API, so `docker exec` and `docker cp` go through `container exec`. A TTY exec gets a raw pty that the daemon owns, and `/exec/{id}/resize` sets that pty's size. Exec instances live in memory only, as in Docker. `cp` runs `stat` and `tar` inside the container, so it needs a running, unpaused container with `tar` and `sh`. On a stopped container it returns 409. The `PUT` body counts against the 64 MiB request limit.
- D-18: Stats come from a background sampler, not from each request. One `container stats --format json` call takes about 2 s, and the Docker CLI drops a `--no-stream` reply that takes longer than 2 s. The sampler runs every 10 s while Docker containers run, back to back while a client reads stats within the last 60 s, and at once after a container starts. Paused containers are skipped. CPU % comes from the delta between the two latest samples. `system_cpu_usage` is wall time since daemon start times the container's CPUs (the `--cpus` limit, else host CPUs), so 100% means one busy CPU. The first sample of a container reports 0%. A container with no sample yet reports zeros.
- D-19: Events are kept in memory: the last 1000, for `since` replay. They do not survive a daemon restart. Container events follow Docker's order and attributes. Stop emits `kill` (signal 15), `die` (exitCode), then `stop`. Force-remove emits `kill` (9), `die`, then `destroy`. Image events are not emitted yet.
- D-20: Apple keeps one image record per reference. Docker's view groups the records by ID, which is the image index digest, and lists all their tags. `rmi <ref>` deletes that reference only, and the image goes with its last reference. `rmi <id>` deletes every reference, and needs `force` when the ID has more than one. Removing an image's last reference needs `force` while any Apple container uses it, Docker-created or not. Apple images always have a reference, so nothing is ever dangling. The default `image prune` therefore removes nothing, and `prune -a` removes every image no container uses.
- D-21: Apple `container` reads registry credentials only from its own Keychain entries and takes none per pull. So `POST /auth` (`docker login`) and the pull's `X-Registry-Auth` header both become `container registry login --password-stdin` for the image's registry. Credentials go to the Keychain, never to a file. Like Docker, pratico treats `localhost` and `127.0.0.0/8` registries as plain HTTP (`--scheme http`). `make e2e-registry` checks AC-9 and AC-50 against a throwaway local registry. It is a test harness only, not part of pratico's setup or of `make e2e`. Docker Hub logins map to `docker.io`, which has not been verified against a real Hub account.
- D-22: Releases go through `make release VERSION=x.y.z` (`scripts/release.sh`) only. The version must be semver and must equal `Pratico.version`. Info.plist's `CFBundleShortVersionString` must equal it without the `-pre` suffix, because Apple requires plain x.y.z there. The tree must be clean, and the tag must not exist locally or on `origin`. The script then runs the unit and e2e suites, builds and verifies `dist/Pratico-x.y.z.dmg`, writes its SHA-256, creates and pushes the annotated tag `vx.y.z`, and publishes a GitHub release with both files. A version with a `-pre` suffix is published as a pre-release. The DMG holds `Pratico.app`, an `/Applications` link, and `READ ME FIRST.txt`, which explains the Gatekeeper steps.
- D-23: `docker save` (`GET /images/{name}/get`, and `/images/get` for one name) runs `container image save` for the image's platform. It adds Docker's `manifest.json` to the OCI layout and writes tar entries without a `./` prefix. Image scanners export images that way over `DOCKER_HOST`. Verified: `osv-scanner scan image <name:tag>` and `grype docker:<name>` work against pratico unchanged.
- D-24: Image scanning (design: `docs/design/image-scanning.md`). After each pull, and for unscanned or day-old local images, the daemon exports the image in the background. It runs osv-scanner (vulnerabilities, OpenSSF `MAL-` advisories, full package list as the bill of materials), grype and trivy, if they are installed, and every executable in `scan_custom` (2026-11-12: run as `<path> <image.tar>` with `PRATICO_IMAGE_ID` and `PRATICO_IMAGE_REFS`, printing `{"findings": [...]}`). Scanners are external programs by design; `GET /pratico/scanners` reports which are found, where, and their versions, and the menubar's Scanners menu turns that into install help (Homebrew, else its installer and each project's page). `POST /pratico/scans` rescans every image now and `GET /pratico/scans` returns each image's report, verdict, and which scanner reported each finding; the menubar shows them in a Scan Results window. Settings › Scanners lists the built-in scanners and manages `scan_custom` (add by file picker, remove after asking). It marks CVEs listed in CISA KEV (feed cached for a day) and stores `~/.pratico/scans/<id>.json`. New `config.toml` keys: `scan` (bool, default `true`); `scan_block` (`off|malware|kev|critical`, default `kev`, so a Critical CVE only warns); `scan_allow` (array of image IDs). A serious verdict stops the image's running Docker containers and blocks starts with 409 until the image is allowed. It also writes `~/.pratico/alerts.json`, one alert per blocked image (a rescan replaces it), which the menubar turns into notifications. The menubar icon shows a filled shield for a blocked image and an outline one for images with a critical or high finding, malware, or a KEV CVE short of a block (medium and low findings are listed but never flagged), and one Scan Results line counts them, from `GET /pratico/scans/summary` (verdicts kept in memory). Verdicts are recomputed from stored findings when the daemon starts. A rescan where no scanner ran changes nothing. When one scanner fails, every earlier finding it contributed to is carried over and merged at its strictest values, so an outage cannot lift a block. osv-scanner sends package names and versions to osv.dev. `make e2e` uses fake scanners and a local KEV file.
- D-25: Networks map onto Apple networks. `bridge` is Apple's `default`, `none` is Apple's `none`, `host` and `container:` modes return 400. Each custom network is an Apple network `pratico-<id12>` with an explicit /24 from 172.18.0.0/16 that overlaps no other network or host interface, because Apple 1.0.0's auto-allocated subnets get no host bridge. Name resolution: Apple's DNS needs an admin-created domain, so the daemon rewrites `/etc/hosts` (via `container exec … sh`) in every running member whenever membership changes; images without `/bin/sh` get no name resolution. Apple fixes a container's networks at create and the guest lacks `CAP_NET_ADMIN`, so connect/disconnect on a container that never ran recreates its Apple container; on one that has run, connect returns 409 (except rejoining a network it was disconnected from), and disconnect removes it from Docker's view and from name resolution while its interface stays until the container is recreated. Apple vmnet bug: `default` always reclaims `bridge100`, breaking any custom network that took it while `default` was idle; so when a custom network activates with `default` idle, a short-lived `registry.k8s.io/pause:3.10` container (`pratico-anchor`) holds `default` up until the member runs.
- D-26: Embedded runtime (2026-11-09; design `docs/design/runtime.md`; the only runtime since 2026-11-12, when the `container` CLI backend, its `/etc/hosts` sync, freezer agent and network anchor were removed; the app bundles `pratico-shim`, the kernel and `vminit` in `Contents/Resources/runtime`). pratico stops depending on Apple's `container` CLI. It links apple/containerization 0.54.0 and bundles the Kata Containers 3.28.0 kernel and `vminit:0.54.0`, pinned by SHA-256 and fetched at build time (`make assets`), so users install nothing. Images live in `~/.pratico/store`. Each running container's VM is owned by a `pratico-shim` process in its own session. The shim writes the container's log and `exit.json`, and serves `<home>/run/<short id>.sock` (a path under `containers/<id>` exceeds the 104-byte socket limit). The daemon reattaches to live shims after a restart and reads `exit.json` for the rest, so exit codes and output are never lost. Docker `create` unpacks the image into the container's own sparse `rootfs.ext4`, which keeps changes across restarts. Pause pauses the VM. Operations not yet ported answer 501 naming the operation. D-15, D-17, D-18, D-21, D-23, and D-25 describe the CLI backend and are superseded as their runtime steps land.
- D-27: Networking on the embedded runtime (2026-11-09): pratico-net, a user-space switch in the daemon. Networks are isolated at the switch. DNS is answered at each network's gateway with Docker's semantics (bare names do not resolve on `bridge`); beyond Docker, `<name>.pratico.internal` resolves on every network the asker shares, and `host.docker.internal` and `gateway.docker.internal` resolve as on Docker Desktop. Each VM boots with 4 NIC slots (`eth0`–`eth3`, the Virtualization.framework maximum), spares link-down with no switch port, so connect and disconnect work on running containers and cut traffic at the switch, not just names; a disconnected slot keeps its address reserved until the container restarts (vminitd cannot delete addresses), and every pratico gateway answers DNS. `docker login` on this runtime checks the credentials against the registry and keeps them in pratico's own Keychain items (security domain `dev.pratico.registry`), used for pulls and pushes that send no `X-Registry-Auth`. The uplink to the internet is pure Swift (ARP, ICMP, UDP relay, a TCP endpoint), with no extra binaries; egress interception reuses parts of sandwich-proxy (MIT).
- D-28: Before the embedded runtime becomes the default, the app and DMG ship acknowledgements (done 2026-11-12: `scripts/acknowledgements.sh` writes `Contents/Resources/Acknowledgements.txt` from the resolved packages' license and notice files at `make app`; the DMG carries a copy): Apache-2.0 notices for apple/containerization, `vminitd`, and their dependencies; the GPL-2.0 source offer for the shipped kernel (the Kata 3.28.0 release); MIT notices for embedded sandwich-proxy parts.
- D-29: Registry trust on the embedded runtime (2026-11-10). pratico has its own registry client on URLSession, the `ContentClient` Containerization's import and export use, so the system's proxy and PAC settings and its trusted roots (MDM-installed ones included) apply. `HTTPS_PROXY`, `HTTP_PROXY` and `NO_PROXY` take precedence, as for Docker's daemon. New `config.toml` keys:
  - `registry_http_loopback` (bool, default `true`): plain HTTP, credentials included, to `localhost` and `127.0.0.0/8`, as Docker allows.
  - `registry_http` (array of `host`, `host:port`, or IPv4 CIDR): other registries allowed plain HTTP, Docker's `insecure-registries`. A bare host covers all its ports; a CIDR covers registries named by an address in it.
  - `registry_ca` (array of PEM paths): extra CAs, added to the system's roots. `SSL_CERT_FILE` is read the same way, as an addition.
  - `registry_system_roots` (bool, default `true`): `false` trusts only `registry_ca`.
  - `registry_keep_logins` (bool, default `true`, 2026-11-12): keep `docker login` credentials in pratico's Keychain items for clients that send none. `false` checks them with the registry and keeps nothing, as `dockerd` does; the Keychain is never read, and logins kept earlier stay listed so they can be removed.
  An allowed host still gets HTTPS when it answers TLS. A TLS registry whose certificate is not trusted fails, with no fallback to HTTP. An unreadable CA file, or `registry_system_roots = false` with no CA, stops the daemon with exit 4, on either runtime; the policy is read once, at startup, so it never falls back to a default. Everything beyond "HTTPS verified by the system's roots" is stated so it is not mistaken for interception: `docker info` lists insecure registries and a WARNING per `registry_http` host and per extra CA (subject and SHA-256); pull and push output says when a registry was reached over plain HTTP and which extra CA vouched for it; the daemon log repeats both. `~/.pratico/registries.json` (policy and kept logins, never passwords) feeds the menubar's Registries menu. That menu removes a kept login, the `docker logout` the CLI never sends to a daemon, through `DELETE /pratico/registries/logins/{server}`; `GET /pratico/registries` returns the same state. Credentials never follow a redirect to another host, and a plain-HTTP registry takes tokens only from itself.
- D-31: Disk use and cleanup (2026-11-12). Sizes are allocated blocks (rootfs images are sparse), and a layer two images share counts once. `GET /pratico/disk` gives the menubar's Disk menu slices that add up to the total: images, leftover image data no image references, running and stopped containers, their logs, the guest init filesystem, scan data; plus the Mac's free space and the largest items. Cleanup lists what goes with sizes and asks first; running containers and the images they use are never touched. It uses Docker's own `POST /containers/prune` and `POST /images/prune`, and image prune also collects unreferenced blobs. `GET /system/df` answers with the legacy lists and the per-type summaries newer CLIs read; `POST /build/prune` and `/volumes/prune` answer with nothing removed, so `docker system prune` completes.
- D-30: Docker's default socket path (2026-11-10). The daemon stays unprivileged and listens on `~/.pratico/docker.sock`. `~/.pratico/docker.sock` is the default and needs nothing. pratico never asks for root: the menubar's "Use /var/run/docker.sock…" opens a help popup that says why the path needs an administrator and gives the Terminal commands, with a Copy button: `sudo ln -s ~/.pratico/docker.sock /var/run/docker.sock` for now; optionally a root-owned launchd job, `/Library/LaunchDaemons/dev.pratico.socket.plist`, that runs only `/bin/ln -s` at boot, because macOS empties `/var/run`; and the undo. A root job running a binary from the user-owned app bundle would let anything running as that user become root, and ad-hoc signing (D-10) gives launchd nothing to verify, so there is none. `ln -s` without `-f` never replaces a link someone else made (Docker Desktop's, Colima's); the Status menu names the owner of the path. It is a single-user feature: another user whose tools use `/var/run/docker.sock` reaches this user's socket, which is `0600`, so they are refused. Separately, on the embedded runtime a container that bind-mounts `/var/run/docker.sock` (or `/run/docker.sock`) gets pratico's API whether or not the link exists, as on Docker Desktop. Any host Unix socket mounted with `-v` or `--mount` is relayed into the guest over vsock, because virtiofs shares files but not the connections behind a socket.

## Open Questions

None.
