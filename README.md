# pratico

A local container manager for Apple silicon Macs. It serves the Docker Engine API on a
Unix socket, runs every container in its own lightweight VM on Virtualization.framework,
and scans every image it pulls. A menubar app controls the daemon and shows what runs,
what it uses, and what the scans found. There is no `pratico` CLI: use `docker`,
`docker compose`, or any client of the Docker API.

Website: <https://gleicon.github.io/pratico/> · License: MIT

## Requirements

- Apple silicon Mac, macOS 26
- Nothing else. The app carries the Linux kernel (6.18.56, from Kata Containers 4.3.1) and init
  (`vminitd`) its VMs boot.

## Install

1. Download `Pratico-<version>.dmg` from
   [Releases](https://github.com/gleicon/pratico/releases) and drag `Pratico.app` to
   Applications.
2. The app is ad-hoc signed, not notarized. Approve the first launch with **Open Anyway**
   in System Settings › Privacy & Security, or:

   ```sh
   xattr -dr com.apple.quarantine /Applications/Pratico.app
   ```

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

- **One VM per container.** Each container boots its own kernel. Nothing is shared
  between containers except volumes you share. CPU and memory limits are the VM's size.
- **Shims outlive the daemon.** A daemon restart reattaches to running containers; their
  output and exit codes are kept.
- **Start order.** The shim creates the VM and waits; the daemon attaches networks,
  publishes ports, and records the container as running, then tells the shim to start
  the process.
- **pratico-net.** A user-space switch in the daemon, outside every VM. Each VM has one
  virtual NIC, `eth0`, with an address per network it joins, so there is no limit on the
  number of networks. The switch tells a VM's networks apart by source address and drops
  frames from any address it has not assigned to that VM on that network. Networks are
  separated at the switch; each gateway answers DNS for
  its containers and aliases and forwards other names to the Mac's resolver. `--internal`
  networks have no route out; the default route goes through the first network that is
  not internal. Published ports bind on the Mac (`0.0.0.0` unless an address is given).
  `host.docker.internal` reaches the Mac. Disconnect cuts that address at the switch.
- **Root filesystem.** Each image is unpacked once into an ext4 disk image; every
  container gets an APFS clone of it, so `create` takes the same few milliseconds for any
  image size and a container's disk use is only what it writes. Bind mounts and volumes
  are shared over virtiofs; host Unix sockets (including
  `/var/run/docker.sock` inside a container) are relayed over vsock.

Details: [docs/design/runtime.md](docs/design/runtime.md).

## Resource use

Measured on an Apple silicon Mac with idle `alpine` containers (`make bench` covers the
latency and daemon-memory bounds):

| | |
|---|---|
| `docker run --rm alpine true` | P99 316 ms over 50 runs, VM boot included |
| Memory per running container | ≈ 250 MB (VM process ≈ 215 MB, shim ≈ 33 MB) |
| No containers running | no VMs |
| Daemon | ≈ 45 MB; 48 MB with 32 containers running |
| `/_ping`, `/version`, `ps -a` with 100 containers | P99 ≤ 3 ms |

`--memory` (default 1 GiB, plus 128 MiB for the guest) is a ceiling: the Mac backs only
pages the guest touches. The VM has no memory balloon, so page cache the guest fills is
returned when the container stops, not while it runs.

## Compatibility

Supported:

- Containers: create, start, stop, restart, kill, pause, rm, logs (`-f`, `--tail`,
  `-t`), attach, exec (`-it`, resize), cp (running or stopped containers), stats, wait,
  inspect, healthchecks, events, prune.
- Images: pull, push, tag, rm, inspect, prune, save (one or several), load (OCI archives),
  list filters (`reference`, `dangling`, `label`, `before`, `since`).
- Networks: create (bridge, `--internal`), connect and disconnect running containers,
  aliases, DNS by name, prune.
- Volumes: named and anonymous (`-v /path`, image `VOLUME`), copy-up of image files into
  new volumes, `nocopy`, `rm -v`, prune (`-a`), `tmpfs` mounts, bind mounts.
- `docker login`, private registries, plain-HTTP and custom-CA registries (config).
- `docker system df`, `docker system prune`, Compose projects with private networks.
- Docker CLI 25.0 and later. Older clients get Docker Engine's "client version is too old".

Limits:

- `docker build` is not supported.
- Containers run `linux/arm64`; images without an arm64 variant do not run.
- IPv4 only on pratico-net.
- A container has one interface for all its networks, with one MAC, where Docker gives
  each network its own `ethN` and MAC. Software that binds to `eth1` by name sees only
  `eth0`.
- Files on volumes and bind mounts are owned by the Mac user, so images that `chown`
  their data to another uid see the volume's owner.

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
- The menubar icon changes for blocked images and for images with critical or high
  findings, malware, or KEV entries. Medium and low findings are listed, not flagged.
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
  published port, stop, restart. The icon shows the count.
- **Alerts**: blocked images, ports published beyond loopback, containers turning
  unhealthy. Each becomes one notification.
- **Disk**: allocated size of images, leftover layers, running and stopped containers,
  logs, volumes, and scan data, adding up to the total. Cleanup actions list what they
  remove, ask, then call the matching prune endpoint.
- **Snapshot**: writes every container, network, and volume definition to
  `~/.pratico/snapshots/pratico-snapshot-<time>.tar.gz` (JSON files and a
  `manifest.json`). Restore shows each container's image, command, mounts, ports, and
  privileges before asking, skips names that exist, and starts containers only if asked.
  Volume data is not included.
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
- The guest kernel is Linux 6.18.56 (GPL-2.0), unmodified, as built by
  [Kata Containers](https://katacontainers.io) for their
  [4.3.1 release](https://github.com/kata-containers/kata-containers/releases/tag/4.3.1);
  source and configuration are published there.
- The guest init, `vminitd` and `vmexec`, comes from Apple's `vminit` image (Apache-2.0).
  These static binaries include musl (MIT), the Swift runtime, Foundation, libdispatch
  (Apache-2.0 with Runtime Library Exception), and ICU data (Unicode License V3).
- osv-scanner, grype, trivy, and syft are installed separately and are not shipped with
  pratico.

`Acknowledgements.txt` in the app and DMG carries every license text and the kernel's
GPL-2.0 source offer.
