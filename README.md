# pratico

A Docker daemon for Apple silicon Macs, with a menubar app. Every container runs in its
own lightweight VM: no shared Linux VM, no Docker Desktop. Existing tools keep working:
`docker`, `docker compose`, and anything that talks to a Docker socket.

*Prático* (Portuguese): the harbour pilot who guides ships through narrow channels.

Status: **v0.1.0-alpha**. Each container runs in its own small VM on Apple's
Virtualization.framework; nothing else needs installing (see [How it runs](#how-it-runs)).

## Use it

1. Download `Pratico-<version>.dmg` from
   [Releases](https://github.com/gleicon/pratico/releases), drag `Pratico.app` to
   Applications, and approve it once in Gatekeeper ("Open Anyway" in System Settings →
   Privacy & Security, or `xattr -dr com.apple.quarantine /Applications/Pratico.app`).
   The build is ad-hoc signed; `READ ME FIRST.txt` in the DMG walks through it.
2. Start the daemon from the menubar item. **Status › View Daemon Log** shows what it is
   doing (`~/.pratico/daemon.log`).
3. Point `docker` at it once, so you never type `-H`. Either a Docker context, which the
   CLI and Compose remember:

   ```sh
   docker context create pratico --docker host=unix://$HOME/.pratico/docker.sock
   docker context use pratico
   docker run --rm alpine echo hello
   ```

   or `DOCKER_HOST`, which every Docker client reads (add it to `~/.zshrc` to keep it):

   ```sh
   echo 'export DOCKER_HOST=unix://$HOME/.pratico/docker.sock' >> ~/.zshrc
   ```

   The menubar's **Use with docker…** shows both with a Copy button. The socket is
   `~/.pratico/docker.sock`, the default, and needs no password. For tools that only know
   `/var/run/docker.sock`, the menubar's **Use /var/run/docker.sock…** explains why that
   path needs an administrator and gives the `sudo` commands to copy into Terminal (link
   now, optionally at every startup, undo). Pratico itself never asks for root.

The menubar's **Disk** menu shows what pratico uses, sized by blocks actually allocated
and with shared layers counted once: images (and how much is unused), leftover image
data, running and stopped containers, logs, the guest init, scan data, the largest items,
and the Mac's free space. Its cleanup actions list what they remove and ask first;
running containers and the images they use are kept. `docker system df` and
`docker system prune` work too.

Pratico has no CLI of its own: `docker` is the CLI, the menubar is the control panel.

## How it runs

Pratico runs each container in its own small VM on Apple's Virtualization.framework,
through [apple/containerization](https://github.com/apple/containerization). The app
carries the Linux kernel and init, so nothing else needs installing.

- Each VM has its own `pratico-shim`, so containers and their exit codes survive a daemon
  restart.
- A guest agent runs exec, cp, stats and healthchecks, so images need no tools of their
  own; pause freezes the whole VM.
- pratico-net, a user-space switch in pure Swift, gives isolated networks, DNS by name,
  internet and Mac access (`host.docker.internal`), published ports, and connect or
  disconnect of running containers (disconnect cuts traffic at the switch).
- `-v /var/run/docker.sock:...` and other host Unix sockets are relayed into the VM.

Design: [docs/design/runtime.md](docs/design/runtime.md); checklist:
[.project/roadmap.md](.project/roadmap.md).

## Build from source

Requires an Apple silicon Mac with macOS 26 and Xcode 26 (Swift 6.2+).

```sh
make assets        # kernel + vminit, pinned and verified (once; cached)
make build         # swift build, then signs pratico-shim with the virtualization entitlement
make app           # dist/Pratico.app
make dmg           # dist/Pratico-<version>.dmg (ad-hoc signed)
make install       # copies Pratico.app to /Applications
```

`make assets` downloads the Kata Containers 3.28.0 release once (about 600 MB, checked
against the digest GitHub publishes) to extract its 16 MB kernel, and the
`vminit:0.54.0` image from ghcr.io. Both land in `.cache/assets/`; later builds are offline.

## Test

```sh
make test           # unit tests (Swift Testing)
make e2e            # the real docker CLI against a throwaway daemon: the Docker API
make e2e-embedded   # the runtime underneath: shims, guest agent, pratico-net, registries
make e2e-registry   # test harness only: a throwaway private registry for login/pull/push
make probe ARGS="docker.io/library/alpine:latest uname -a"   # boot one VM directly
```

The e2e suites use `/opt/homebrew/bin/docker` (override with `DOCKER=`), an isolated
`DOCKER_CONFIG`, and fake image scanners, so they never touch your Docker login or the
network beyond image pulls.

## Configure

**Settings…** (⌘, from the menubar) is a standard settings window over
`~/.pratico/config.toml`, with General, Scanning and Registries tabs. A change is written
at once and only to its own key, keeping your comments; a key set in the file says so,
with **Use Default** to remove it. The daemon reads the file when it
starts; Settings offers the restart. The file holds overrides only; unknown keys stop
the daemon with the key and line named.

| Key | Default | Meaning |
|---|---|---|
| `start_at_login` | `true` | start the daemon at login |
| `default_cpus` | `4` | CPUs for a container with no `--cpus` |
| `default_memory` | `1024` | MiB for a container with no `--memory` |
| `scan` | `true` | scan pulled images in the background |
| `scan_block` | `"kev"` | `off`, `malware`, `kev`, or `critical`: what stops and blocks an image |
| `scan_allow` | `[]` | image IDs allowed despite findings |
| `scan_custom` | `[]` | your own scanners: executables run as `<path> <image.tar>` that print pratico's findings JSON |
| `registry_http_loopback` | `true` | plain HTTP, credentials included, to localhost registries, as Docker |
| `registry_http` | `[]` | other registries (`host`, `host:port`, or an IPv4 CIDR such as `10.0.0.0/8`) allowed plain HTTP, Docker's insecure-registries |
| `registry_ca` | `[]` | PEM files of extra CAs, added to the system's trusted roots |
| `registry_system_roots` | `true` | `false` trusts only `registry_ca` |
| `registry_keep_logins` | `true` | keep `docker login` credentials in pratico's Keychain items for clients that send none; `false` only checks them, as `dockerd` does, and never reads the Keychain |

## Image scanners

Every pulled image is scanned in the background, and again daily, with each scanner
pratico finds, plus CISA's list of exploited vulnerabilities. An image with malware or an
exploited CVE (`scan_block`) is stopped and blocked, and the menubar says why.

- **Menubar**: the icon becomes a filled shield when an image is blocked and an outline
  shield when images have vulnerabilities. One **Scan Results…** line says how many, however
  many images there are; a block also raises a notification, once per image.
- **Scanners menu**: which scanners are found, with versions; **Install Missing
  Scanners…** gives the Homebrew command (or how to get Homebrew); **Scan All Images Now**.
- **Scan Results** window: per image, which scanners ran (or why not), and every finding
  with the scanners that reported it, severity, KEV and malware flags, and fixed versions.
- **Settings › Scanners**: the built-in ones (osv-scanner, grype, trivy) and your own. **+**
  adds any executable, **−** removes one (after asking), **Format…** shows the contract
  below. Your scanners are `scan_custom` in `config.toml`; the daemon picks up changes when
  it restarts.

### Your own scanner

pratico runs it as `<path> <image.tar>`, where the archive is a Docker archive of the
image, with `PRATICO_IMAGE_ID` and `PRATICO_IMAGE_REFS` set. It must exit 0 and print:

```json
{"findings": [
  {"id": "CVE-2024-0001", "package": "openssl", "version": "3.0.1",
   "severity": "high", "fixed": ["3.0.2"], "cvss": 7.5},
  {"id": "MAL-ACME-7", "package": "evil-pkg", "version": "6.6.6",
   "severity": "critical", "malicious": true}
]}
```

`id` and `package` are required. `severity` is `critical`, `high`, `medium`, `low` or
`unknown`; `aliases`, `fixed`, `cvss` and `malicious` are optional. A non-zero exit, or
output that is not this JSON, counts as a failed run: earlier findings from that scanner
are kept, so an outage never lifts a block. Its findings merge with the other scanners'
and follow `scan_block`. Design: [docs/design/image-scanning.md](docs/design/image-scanning.md).

## Layout

| Path | Holds |
|---|---|
| `Sources/PraticoDaemonKit` | Docker API server and services (containers, images, networks, exec, logs, events, health, stats, scanning, runtime, shim) |
| `Sources/pratico-daemon` | daemon executable (`--home <dir>` relocates state) |
| `Sources/pratico-shim` | one per running container; owns its VM |
| `Sources/pratico-menubar` | SwiftUI menubar app |
| `Sources/PraticoCore` | config, paths, version |
| `e2e/` | end-to-end suites and fakes |
| `scripts/` | `fetch-runtime-assets.sh`, `release.sh` |
| `Support/` | Info.plist, entitlements, launch agent, DMG readme |
| `SPEC.md` | requirements, acceptance criteria, decisions (D-n) |
| `docs/design/` | design documents |

State lives in `~/.pratico/`: `docker.sock`, `config.toml`, `containers/`, `store/`
(images), `networks/`, `scans/`, `alerts.json`, `run/` (shim sockets).

## Release

`make release VERSION=x.y.z` (see `scripts/release.sh`) checks the version, runs the
tests and e2e, builds and verifies the DMG, tags `vX.Y.Z`, and publishes a GitHub
release with the DMG and its SHA-256.

## License

MIT, see [LICENSE](LICENSE).

## Acknowledgements

pratico embeds [apple/containerization](https://github.com/apple/containerization)
(Apache-2.0) and its Apache-2.0 dependencies, ships the Kata Containers kernel
(GPL-2.0; source and config at the
[3.28.0 release](https://github.com/kata-containers/kata-containers/releases/tag/3.28.0))
and `vminitd` (Apache-2.0). Planned: parts of
[sandwich-proxy](https://github.com/gleicon/sandwich-proxy) (MIT). The app and DMG carry
`Acknowledgements.txt` with every license notice.
