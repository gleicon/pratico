# pratico

A local container manager for Apple silicon Macs. It serves the Docker Engine API on a
Unix socket, runs every container in its own lightweight VM on Virtualization.framework,
and scans every image it pulls. A menubar app controls the daemon and shows what runs,
what it uses, and what the scans found. There is no `pratico` CLI: use `docker`,
`docker compose`, or any client of the Docker API.

Website: <https://gleicon.github.io/pratico/> · License: MIT

## Requirements

- Apple silicon Mac, macOS 26
- Nothing else. The app carries the Linux kernel (6.18.63 LTS, built by pratico) and init
  (`vminitd`) its VMs boot.

## Install

1. Download `Pratico-<version>.dmg` from
   [Releases](https://github.com/gleicon/pratico/releases) and drag `Pratico.app` to
   Applications.
2. The app is not notarized by Apple yet, so macOS stops its first launch. Approve it
   once, either way:
   - **Without Terminal:** open Pratico, click **Done** when macOS says it cannot check
     it, then in System Settings › Privacy & Security click **Open Anyway** (under
     Security), enter your password, and confirm with **Open Anyway**.
   - **With Terminal, before opening the disk image:** remove the download's quarantine,
     then open it and drag Pratico to Applications; it opens without a prompt.

     ```sh
     xattr -d com.apple.quarantine ~/Downloads/Pratico-*.dmg
     ```

     With Pratico already in Applications, `xattr -dr com.apple.quarantine
     /Applications/Pratico.app` does the same, unless macOS answers "Operation not
     permitted" (it protects apps from Terminal unless Terminal has **App Management** in
     Privacy & Security); then use the way without Terminal.

   Each release has a `.sha256` beside the DMG: `shasum -a 256 -c Pratico-<version>.dmg.sha256`
   in the download folder checks it.

3. Open Pratico. The menubar item starts the daemon, which then starts at login
   (`start_at_login`). Status › View Daemon Log opens `~/.pratico/daemon.log`.

## Use

The socket is `~/.pratico/docker.sock`. Point clients at it with a context:

```sh
docker context create pratico --docker host=unix://$HOME/.pratico/docker.sock
docker context use pratico
docker run --rm alpine echo hello
```

or with `DOCKER_HOST=unix://$HOME/.pratico/docker.sock`. Tools hard-wired to
`/var/run/docker.sock` need a root-owned link there; the menubar's
**Use /var/run/docker.sock…** shows the `sudo` commands. Pratico itself never asks for
root.

Images move to and from Apple's `container` tool as OCI archives:

```sh
container image save myapp:dev -o myapp.tar && docker load -i myapp.tar
docker save myapp:dev -o myapp.tar && container image load -i myapp.tar
```

## How it works

```
docker / compose / any API client
        │  Docker Engine API 1.55 (min 1.44) on ~/.pratico/docker.sock
pratico-daemon ── images (OCI store), networks, volumes, scans, snapshots
        │  one per container
pratico-shim ──── owns one VM (Virtualization.framework, via apple/containerization)
        │  vsock
vminitd ───────── guest agent: process, exec, cp, stats, healthchecks
```

- **[VMs](docs/vm.md).** One VM per container, each with its own kernel and init, both
  built by pratico from pinned sources, reproducibly ([tooling](docs/tooling.md)). A shim owns the
  VM and outlives the daemon, so restarts keep running containers, output, and exit
  codes. `docker run --rm alpine true`: median 237 ms, P99 243 ms; ≈ 320 MB of memory
  per running container; no VMs when nothing runs.
- **[CPU](docs/cpu.md).** `linux/arm64`, native. `--cpus` is the VM's vCPU count
  (default 4).
- **[Networking](docs/network.md).** pratico-net, a user-space switch in the daemon,
  outside every VM. One NIC per VM with an address and a MAC per network, no limit on
  networks, isolation enforced at the switch, DNS at each gateway, published ports bound
  on the Mac.
- **[Builds](docs/build.md).** `docker build` and `compose build` run BuildKit in its
  own VM through buildx and load the result; one builder setup line, once.
- **[Run options](docs/run-options.md).** Every `docker run` option pratico accepts is
  applied (cgroup limits, capabilities, seccomp profiles, restart policies, `--init`,
  `--read-only`, …); one a VM cannot honor, such as `--device` or `--pid host`, is
  refused with an error. Docker's default seccomp profile is on.
- **[Egress](docs/egress.md).** Every connection a container makes is named (DNS, TLS
  SNI, HTTP Host) and recorded on the Mac; destinations threat feeds list (Feodo
  Tracker, SSL Blacklist, Spamhaus DROP, and URLhaus and ThreatFox with a free abuse.ch
  key) are refused; a label limits a container to the names it lists.
- **[Flight recorder](docs/vm.md#flight-recorder).** Each VM records every program
  started in its container (path and arguments), every exit, and the process behind each
  TCP connection and UDP destination, named from the egress record, from BPF probes pratico builds for its
  kernel; kept after the container stops (`GET /pratico/containers/{id}/activity`, and
  the MCP server's `activity` tool).
- **[Agents](docs/agents.md).** An MCP endpoint on 127.0.0.1 (off until `mcp = true`,
  bearer token): agents check images before using them, run commands in throwaway VMs,
  and start services, and can change only the containers they made.
- **[Storage](docs/storage.md).** Images unpacked once into ext4 and cloned per
  container (APFS), so `create` takes milliseconds for any image. Volumes are journaled
  ext4 disks, so postgres, mysql, redis, and mongo run on their default volumes; bind
  mounts over virtiofs; `docker cp` on stopped containers; snapshots of definitions.

Design notes: [docs/design/runtime.md](docs/design/runtime.md).

## Compatibility

Supported:

- Containers: create, start, stop, restart, kill, pause, rm, rename, update, logs
  (`-f`, `--tail`, `-t`, `--since`, `--until`), attach, exec (`-it`, `--privileged`,
  resize), top, diff, export, commit (`-c` changes too), cp (running or stopped containers), stats, wait, inspect
  and `ps` (`--size` too), healthchecks, events, prune.
- Images: pull, push, tag, rm, inspect, history, prune, save (one or several), load (OCI archives),
  list filters (`reference`, `dangling`, `label`, `before`, `since`).
- Networks: create (bridge, `--internal`), connect and disconnect running containers,
  aliases, DNS by name, prune.
- Volumes: named and anonymous (`-v /path`, image `VOLUME`), copy-up of image files into
  new volumes, `nocopy`, `rm -v`, prune (`-a`), `tmpfs` mounts, bind mounts.
- `docker login`, private registries, plain-HTTP and custom-CA registries (config).
- `docker system df`, `docker system prune`, Compose projects with private networks.
- Docker CLI 25.0 and later. Older clients get Docker Engine's "client version is too old".

Limits:

- Images without an arm64 variant do not run ([CPU](docs/cpu.md)).
- IPv4 only; a container sees one interface, `eth0`, for all its networks
  ([networking](docs/network.md#limits)).
- `docker update` changes a running container's limits up to the vCPUs and memory its VM
  booted with; more takes a restart ([update](docs/run-options.md#docker-update)).
- A disk volume serves one running container at a time; files on bind mounts and share
  volumes are owned by the Mac user ([storage](docs/storage.md#volumes)).
- Host devices, host namespaces, blkio limits, and AppArmor profiles are refused
  ([run options](docs/run-options.md#refused)). Seccomp is on, with Docker's default
  profile ([seccomp](docs/run-options.md#seccomp)).

## Image scanning

Each pulled or loaded image is scanned in the background, and again daily, with every
scanner found in Homebrew or Go paths:

| Tool | Source | Matching |
|---|---|---|
| osv-scanner | Google | package names and versions sent to the OSV.dev API |
| grype | Anchore | local vulnerability database |
| trivy | Aqua Security | local vulnerability database |
| syft | Anchore | writes SPDX and CycloneDX SBOMs, no findings |
| CISA KEV | U.S. CISA | catalog of exploited CVEs, cached daily |
| EPSS | FIRST | exploitation probability per CVE, cached daily (only CVE IDs sent) |

Image contents do not leave the Mac. Findings from all scanners are merged; each lists
the scanners that reported it.

- `scan_block` sets what blocks an image: `off`, `malware`, `kev` (default), or
  `critical`. A blocked image's containers are stopped and cannot start; a notification
  says why.
- Scan Results (menubar) lists findings per image with severity, CVSS, EPSS, KEV and
  malware flags, fixed versions, and the reporting scanners. It exports SBOMs and offers
  **Allow This Image…**, which adds the image ID to `scan_allow` and unblocks it.
- The menubar's mark turns its fourth tile into a dot for a blocked image (and for refused
  destinations and unhealthy containers). Other findings are listed in the menu and Scan
  Results, not flagged on the icon.
- The Scanners menu shows what is installed and gives the Homebrew command for the rest.

### Custom scanners

Any executable listed in `scan_custom` runs as `<path> <image.tar>` (a Docker archive),
with `PRATICO_IMAGE_ID` and `PRATICO_IMAGE_REFS` set. It exits 0 and prints:

```json
{"findings": [
  {"id": "CVE-2024-0001", "package": "openssl", "version": "3.0.1",
   "severity": "high", "fixed": ["3.0.2"], "cvss": 7.5},
  {"id": "MAL-ACME-7", "package": "evil-pkg", "version": "6.6.6",
   "severity": "critical", "malicious": true}
]}
```

`id` and `package` are required; `severity` is `critical`, `high`, `medium`, `low`, or
`unknown`; `aliases`, `fixed`, `cvss`, and `malicious` are optional. A non-zero exit or
other output is a failed run and keeps that scanner's earlier findings. Design:
[docs/design/image-scanning.md](docs/design/image-scanning.md).

## Menubar

- **Containers**: running containers with image, CPU, memory, health, and ports; open a
  published port, stop, restart.
- **The icon**: pratico's mark, outlined when the daemon is stopped, filled when it runs,
  its fourth tile a dot when something needs action (a blocked image, a refused
  destination, an unhealthy container). Nothing is drawn beside it.
- **Connections**: where every container connected, which process opened each
  connection, and what pratico refused and why ([egress](docs/egress.md)).
- **Alerts**: blocked images, ports published beyond loopback, containers turning
  unhealthy. Each becomes one notification; a container's alerts end when it is removed.
- **Disk**: allocated size of images, leftover layers, running and stopped containers,
  logs, volumes, and scan data, adding up to the total. Cleanup actions list what they
  remove, ask, then call the matching prune endpoint.
- **Snapshot**: writes every container, network, and volume definition to
  `~/.pratico/snapshots/`, and restores them after showing what each container would
  get ([storage](docs/storage.md#snapshots)). Volume data is not included.
- **Settings** (⌘,): `config.toml` as a form.

## Configuration

`~/.pratico/config.toml` holds overrides only; Settings writes one key at a time and
keeps comments. Unknown keys stop the daemon with the key and line named.

| Key | Default | |
|---|---|---|
| `start_at_login` | `true` | start the daemon at login |
| `default_cpus` | `4` | vCPUs when `--cpus` is not given |
| `default_memory` | `1024` | MiB when `--memory` is not given |
| `scan` | `true` | scan images in the background |
| `scan_block` | `"kev"` | `off`, `malware`, `kev`, or `critical` |
| `scan_allow` | `[]` | image IDs allowed despite findings |
| `scan_custom` | `[]` | executables used as scanners |
| `registry_http_loopback` | `true` | plain HTTP to localhost registries |
| `registry_http` | `[]` | other registries allowed plain HTTP (`host`, `host:port`, IPv4 CIDR) |
| `registry_ca` | `[]` | PEM files added to the trusted roots |
| `registry_system_roots` | `true` | `false` trusts only `registry_ca` |
| `volume_size` | `64` | GiB a new disk volume can hold (sparse) |
| `egress_block` | `true` | refuse destinations threat feeds list; `false` only alerts |
| `mcp` | `false` | serve MCP for agents on 127.0.0.1 ([agents](docs/agents.md)) |
| `mcp_port` | `7728` | its port |
| `registry_keep_logins` | `true` | keep `docker login` credentials in the Keychain for clients that send none |

## Files

`~/.pratico/`: `docker.sock`, `config.toml`, `daemon.log`, `store/` (images),
`containers/` (rootfs, logs, shim state), `volumes/<name>/_data`, `networks/`, `scans/`
(reports, SBOMs), `scan-db/` (KEV, EPSS caches), `snapshots/`, `alerts.json`, `run/`.

## Build and test

Requires Xcode 26 (Swift 6.2).

```sh
make assets          # kernel and vminitd, pinned and verified, cached in .cache/assets
make build           # swift build; signs pratico-shim with the virtualization entitlement
make app             # dist/Pratico.app
make dmg             # dist/Pratico-<version>.dmg
make install         # copy to /Applications

make test            # unit tests
make e2e             # Docker API against a throwaway daemon, real docker CLI
make e2e-embedded    # runtime: shims, guest agent, pratico-net, volumes, snapshots
make e2e-tools       # real tools: Testcontainers (Go), Compose with postgres (needs Go)
make bench           # AC-44..49: latency, memory, connection limits, CLI versions
```

The e2e suites use `/opt/homebrew/bin/docker` (`DOCKER=` to override), an isolated
`DOCKER_CONFIG`, and fake scanners. `make release VERSION=x.y.z` runs the tests, builds
and verifies the DMG, tags `vX.Y.Z`, and publishes the release; with `SIGN_IDENTITY` and
`NOTARY_PROFILE` set it signs with a Developer ID and notarizes.

Runnable examples of each feature, and pratico's own API endpoints: [examples/](examples/).
Requirements, acceptance criteria, and design decisions: [SPEC.md](SPEC.md).

## Acknowledgements

- [apple/containerization](https://github.com/apple/containerization) (Apache-2.0) and
  its Swift package dependencies are linked into the daemon and shim.
- The guest kernel is Linux 6.18.63 (GPL-2.0), built by pratico from the unmodified
  kernel.org source with apple/containerization's configuration plus
  [pratico's additions](vm/kernel/config-pratico); how: [docs/vm.md](docs/vm.md#kernel).
  Its configuration ships in the app, next to the kernel.
- The guest init, `vminitd` and `vmexec`, is built by pratico from apple/containerization's
  source (Apache-2.0, [Vendor/](Vendor/README.md)).
  These static binaries include musl (MIT), the Swift runtime, Foundation, libdispatch
  (Apache-2.0 with Runtime Library Exception), and ICU data (Unicode License V3).
- osv-scanner, grype, trivy, and syft are installed separately and are not shipped with
  pratico.
- Egress threat data, fetched on your Mac and not redistributed: Feodo Tracker, SSL
  Blacklist, URLhaus, and ThreatFox by [abuse.ch](https://abuse.ch); the DROP list by
  [The Spamhaus Project](https://www.spamhaus.org/drop/).

`Acknowledgements.txt` in the app and DMG carries every license text and the kernel's
GPL-2.0 source offer.
