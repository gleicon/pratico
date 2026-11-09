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
2. Start the daemon from the menubar item.
3. Point Docker clients at it:

   ```sh
   export DOCKER_HOST=unix://$HOME/.pratico/docker.sock
   docker run --rm alpine echo hello
   ```

Pratico has no CLI of its own: `docker` is the CLI, the menubar is the control panel.

## Runtimes

| | Apple `container` CLI (default today) | Embedded (`PRATICO_RUNTIME=embedded`) |
|---|---|---|
| Needs installed | Apple `container` 1.0 | nothing; kernel and init ship in the app |
| VMs | Apple's services | pratico, via [apple/containerization](https://github.com/apple/containerization) |
| Exit codes after a daemon restart | lost (reported as 0) | kept (each VM has its own `pratico-shim`) |
| Pause | cgroup freezer agent | whole-VM pause |
| stdin (`-i`, `-it`), healthchecks, exec, cp, stats | yes | yes (guest agent; no tools needed in the image) |
| `docker login` | yes | not yet (HTTP 501 with a reason) |
| Networks, DNS by name | yes ([D-25](SPEC.md), `/etc/hosts`) | yes: pratico-net switch and DNS, isolated networks |
| Internet and Mac access (`host.docker.internal`) | yes | yes: pure-Swift uplink, no extra binaries |
| Published ports | yes | next (pratico-net 4c) |

The embedded runtime is the target: once it covers every operation it becomes the
default and the CLI backend is removed. Design and progress:
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

`~/.pratico/config.toml` holds overrides only; unknown keys stop the daemon with the
key and line named.

| Key | Default | Meaning |
|---|---|---|
| `start_at_login` | `true` | start the daemon at login |
| `default_cpus` | `4` | CPUs for a container with no `--cpus` |
| `default_memory` | `1024` | MiB for a container with no `--memory` |
| `scan` | `true` | scan pulled images in the background |
| `scan_block` | `"kev"` | `off`, `malware`, `kev`, or `critical`: what stops and blocks an image |
| `scan_allow` | `[]` | image IDs allowed despite findings |

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
