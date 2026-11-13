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

Nothing else needs installing: Pratico runs containers on Apple's
Virtualization.framework, and the app carries the Linux kernel and init it uses.

## 2. Start

Open Pratico. Its menubar item shows the daemon state; pick **Start** if it is stopped.
If it does not come up, **Status › View Daemon Log** opens `~/.pratico/daemon.log` in
Console, and **Copy Diagnostics** puts version, config, and the log's tail on the
clipboard for an issue.
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

Or for tools that only look at `/var/run/docker.sock` (Testcontainers, some IDE
plugins): pick **Use /var/run/docker.sock…** in the menubar. It explains why that path
needs an administrator and shows the commands to run in Terminal, with a Copy button:

```sh
sudo ln -s ~/.pratico/docker.sock /var/run/docker.sock   # until the next restart
```

plus an optional startup job (a root-owned plist that runs only `/bin/ln -s`) and the
undo. Pratico never asks for your password. If Docker Desktop or Colima owns the path,
leave it to them.

Containers that mount the Docker socket (`-v /var/run/docker.sock:/var/run/docker.sock`)
reach pratico, with or without the link.

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
`scan_allow` in **Settings…** (⌘,), or in `~/.pratico/config.toml`:

```toml
scan_allow = ["sha256:…"]
```

## Running from source

```sh
make run          # builds, fetches the kernel and init, installs and opens the app
```

Or a throwaway daemon with its own state:

```sh
make assets build
.build/arm64-apple-macosx/release/pratico-daemon --home /tmp/pratico-try
export DOCKER_HOST=unix:///tmp/pratico-try/docker.sock
docker run --rm alpine uname -a
```

`PRATICO_RUNTIME=container` selects the old backend on Apple's `container` CLI, until it
is removed. Progress: [docs/design/runtime.md](docs/design/runtime.md).

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| "Pratico can't be opened" | Gatekeeper; approve it as in step 1 |
| `Cannot connect to the Docker daemon` | daemon stopped: start it from the menubar; the reason it stopped is in `~/.pratico/daemon.err` and **Status › View Daemon Log** |
| menubar says the embedded runtime is unavailable | the kernel or `pratico-shim` is missing from the app; reinstall it. Status › View Daemon Log has the details |
| daemon refuses to start, naming a key and line | `~/.pratico/config.toml` has an unknown key or bad value |
| `docker start` fails naming `MAL-…` or a CVE | the image scan blocked it; see Image scanning |
| `docker cp`, `exec`, healthcheck fail on one image | it lacks `/bin/sh` or `tar` (`PRATICO_RUNTIME=container` only) |
