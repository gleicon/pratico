# pratico quick start

pratico is a Mac app: a menubar item plus a background daemon that serves the Docker
API on `~/.pratico/docker.sock`. Every container gets its own lightweight VM. There is
no `pratico` command; you use `docker` (and, if you have it, Apple's `container`).

## 1. Install

You need an Apple silicon Mac with macOS 26.

1. Download `Pratico-<version>.dmg` from
   [Releases](https://github.com/gleicon/pratico/releases).
2. Drag `Pratico.app` to Applications.
3. Approve it once. The build is ad-hoc signed (no paid Apple account), so Gatekeeper
   blocks the first launch. Either:
   - open System Settings → Privacy & Security and click **Open Anyway**, or
   - run `xattr -dr com.apple.quarantine /Applications/Pratico.app`.

Today's default runtime also needs Apple's
[`container`](https://github.com/apple/container/releases) 1.0 installed and started
(`container system start`). The embedded runtime (below) removes that requirement.

## 2. Start

Open Pratico. Its menubar item shows the daemon state; pick **Start** if it is stopped.
The daemon is a background helper inside the app, so containers keep running when the
menubar quits.

## 3. Point Docker at it

```sh
export DOCKER_HOST=unix://$HOME/.pratico/docker.sock   # add to ~/.zshrc to keep it
docker version            # Server: pratico
docker run --rm alpine echo hello
```

Or as a Docker context, which leaves `DOCKER_HOST` alone:

```sh
docker context create pratico --docker host=unix://$HOME/.pratico/docker.sock
docker context use pratico
```

Everyday commands work as usual: `run`, `ps`, `logs -f`, `exec -it`, `cp`, `stats`,
`pause`, `stop`, `rm`, `pull`, `push`, `login`, `images`, `rmi`, `save`, `tag`,
`network create/connect/disconnect`, `events`, healthchecks. `docker build` and volumes
are not there yet; see [.project/roadmap.md](.project/roadmap.md).

## Apple's `container` alongside

pratico labels the containers it creates and never lists, changes, or deletes the ones
you start with Apple's `container` CLI through the Docker API. Showing both in the
menubar is planned.

## Image scanning

Pulled images are scanned in the background with osv-scanner and grype if they are
installed (`brew install osv-scanner grype`). An image with a known-malicious package or
a CVE in CISA's exploited list is stopped and blocked: starting it fails with the
finding named, and the menubar shows an alert. To run it anyway, add its ID to
`~/.pratico/config.toml`:

```toml
scan_allow = ["sha256:…"]
```

## Trying the embedded runtime

Developers building from source can run the daemon on pratico's own runtime, which
needs no `container` install:

```sh
make assets build
PRATICO_RUNTIME=embedded .build/arm64-apple-macosx/release/pratico-daemon --home /tmp/pratico-try
export DOCKER_HOST=unix:///tmp/pratico-try/docker.sock
docker run --rm alpine uname -a
```

It covers pull, images, run (`-d`, `-i`, `-it`, `-p`), logs, exec, cp, stats,
healthchecks, networks with DNS by name, internet and `host.docker.internal` access,
stop, kill, pause, rm, tag, save, login, push, and connecting or disconnecting running
containers (disconnect cuts traffic at the switch). Progress:
[docs/design/runtime.md](docs/design/runtime.md).

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| "Pratico can't be opened" | Gatekeeper; approve it as in step 1 |
| `Cannot connect to the Docker daemon` | daemon stopped: start it from the menubar; the reason it stopped is in `~/.pratico/daemon.err` |
| menubar names the Apple container runtime | default runtime only: install Apple `container` and run `container system start` |
| daemon refuses to start, naming a key and line | `~/.pratico/config.toml` has an unknown key or bad value |
| `docker start` fails naming `MAL-…` or a CVE | the image scan blocked it; see Image scanning |
| `docker cp`, `exec`, healthcheck fail on one image | it lacks `/bin/sh` or `tar` (default runtime) |
