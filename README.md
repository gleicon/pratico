# pratico

A Docker daemon for Apple silicon Macs, with a menubar app. Every container runs in its
own lightweight VM: no shared Linux VM, no Docker Desktop. Existing tools keep working:
`docker`, `docker compose`, and anything that talks to a Docker socket.

*Prático* (Portuguese): the harbour pilot who guides ships through narrow channels.

Status: **v0.1.0-alpha**. The Docker API is served today on Apple's `container` runtime;
pratico's own embedded runtime, which needs nothing else installed, is being phased in
behind a flag (see [Runtimes](#runtimes)).

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

Pratico has no CLI of its own: `docker` is the CLI, the menubar is the control panel.

## Runtimes

| | Embedded (default) | Apple `container` CLI (`PRATICO_RUNTIME=container`, to be removed) |
|---|---|---|
| Needs installed | nothing; kernel and init ship in the app | Apple `container` 1.0 |
| VMs | pratico, via [apple/containerization](https://github.com/apple/containerization) | Apple's services |
| Exit codes after a daemon restart | kept (each VM has its own `pratico-shim`) | lost (reported as 0) |
| Pause | whole-VM pause | cgroup freezer agent |
| stdin (`-i`, `-it`), healthchecks, exec, cp, stats | yes (guest agent; no tools needed in the image) | yes |
| `docker login` | yes: checked with the registry, kept in pratico's own Keychain items | yes |
| Networks, DNS by name | yes: pratico-net switch and DNS, isolated networks | yes ([D-25](SPEC.md), `/etc/hosts`) |
| Connect/disconnect a running container | yes: disconnect cuts traffic at the switch | connect 409; disconnect drops names only |
| Internet and Mac access (`host.docker.internal`) | yes: pure-Swift uplink, no extra binaries | yes |
| Published ports (`-p`) | yes | yes |
| `-v /var/run/docker.sock:...`, other host Unix sockets | yes: relayed over vsock to pratico's API or the host socket | no |

The embedded runtime is the default: Pratico runs each container in its own small VM on
Apple's Virtualization.framework, and the app carries the kernel and init, so nothing
else needs installing. The CLI backend stays behind `PRATICO_RUNTIME=container` until it
is removed. Design and progress:
[docs/design/runtime.md](docs/design/runtime.md); checklist:
[.project/roadmap.md](.project/roadmap.md).

## Build from source

Requires an Apple silicon Mac with macOS 26 and Xcode 26 (Swift 6.2+).

```sh
make assets        # kernel + vminit for the embedded runtime, pinned and verified (once; cached)
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
make e2e            # the real docker CLI against a throwaway daemon (CLI backend)
make e2e-embedded   # the same on the embedded runtime; fails if Apple's CLI is ever called
make e2e-registry   # test harness only: a throwaway private registry for login/pull/push
make probe ARGS="docker.io/library/alpine:latest uname -a"   # boot one VM directly
```

The e2e suites use `/opt/homebrew/bin/docker` (override with `DOCKER=`), an isolated
`DOCKER_CONFIG`, and fake image scanners, so they never touch your Docker login or the
network beyond image pulls.

## Configure

**Settings…** (⌘, from the menubar) edits `~/.pratico/config.toml` as a form: each key
shows its value and whether it comes from the file or the default, and saving rewrites
only the keys you changed, keeping your comments. The daemon reads the file when it
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
| `registry_http_loopback` | `true` | embedded runtime: plain HTTP, credentials included, to localhost registries, as Docker |
| `registry_http` | `[]` | embedded runtime: other registries (`host`, `host:port`, or an IPv4 CIDR such as `10.0.0.0/8`) allowed plain HTTP, Docker's insecure-registries |
| `registry_ca` | `[]` | embedded runtime: PEM files of extra CAs, added to the system's trusted roots |
| `registry_system_roots` | `true` | embedded runtime: `false` trusts only `registry_ca` |
| `registry_keep_logins` | `true` | embedded runtime: keep `docker login` credentials in pratico's Keychain items for clients that send none; `false` only checks them, as `dockerd` does, and never reads the Keychain |

Image scanning uses osv-scanner and grype when installed, plus CISA's KEV list; see
[docs/design/image-scanning.md](docs/design/image-scanning.md).

## Layout

| Path | Holds |
|---|---|
| `Sources/PraticoDaemonKit` | Docker API server and services (containers, images, networks, exec, logs, events, health, stats, scanning, embedded runtime, shim) |
| `Sources/pratico-daemon` | daemon executable (`--home <dir>` relocates state) |
| `Sources/pratico-shim` | one per running container on the embedded runtime; owns its VM |
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
[sandwich-proxy](https://github.com/gleicon/sandwich-proxy) (MIT). An acknowledgements
file ships in the app before the embedded runtime becomes the default.
