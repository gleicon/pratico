# pratico on a Linux host

pratico runs on a Linux server too: the same Docker API, one VM per container, driven from
your Mac's docker CLI over SSH. The design and its reasons are in
[design/remote.md](design/remote.md).

## What the host needs

- arm64 (aarch64) or x86_64: each has its own release tarball, `linux-arm64` or
  `linux-x86_64`. Containers run images of the host's architecture.
- KVM: `/dev/kvm`, open to its group (Ubuntu's `kvm` group). Bare-metal servers have it,
  and clouds that enable nested virtualization; most VPSes do not. pratico refuses a host
  without it.
- systemd.

Nothing else, and nothing from Docker: pratico's binaries are static, and the docker CLI
stays on your Mac. Over `ssh://` it runs `docker system dial-stdio` on the host, which
pratico answers itself (below).

## Install

Download `pratico-<version>-linux-<arch>.tar.gz` (`arm64` or `x86_64`) and its `.sha256` from the
[releases](https://github.com/gleicon/pratico/releases), on the host:

```sh
sha256sum -c pratico-<version>-linux-<arch>.tar.gz.sha256
tar -xzf pratico-<version>-linux-<arch>.tar.gz
sudo ./pratico-<version>-linux-<arch>/pratico-daemon install
```

It shows everything it will write and run, and asks before it changes anything (`--yes`
answers for scripts). It:

- copies the release to `/usr/lib/pratico`: the daemon and shim, Cloud Hypervisor,
  virtiofsd, the guest kernel and init, and `THIRD_PARTY_NOTICES`
- writes a systemd unit, `pratico.service`, that runs as the `pratico` user with no
  capability on the host: of the devices only `/dev/kvm` and `/dev/net/tun`, and of the
  namespaces only user and network ones (each VM's network) and mount and pid ones
  (virtiofsd's sandbox, for bind mounts), all made inside its own user namespace
- creates the `pratico` user and group (systemd-sysusers), adds the `pratico` user to the
  group that owns `/dev/kvm`, and adds the user who ran `sudo` to the `pratico` group
- links `/run/docker.sock` to pratico's socket, `/run/pratico/docker.sock`, unless
  another engine already has it (then it says so and leaves it alone)
- links `/usr/local/bin/docker` to `pratico-daemon`, which then answers
  `docker system dial-stdio`, what the Mac's docker CLI runs over `ssh://`, and refuses
  anything else (`docker ps` on the host says to use the docker CLI on your Mac). It is
  made only where no docker is installed; uninstall removes it
- on hosts with AppArmor (Ubuntu), writes and loads a profile that lets `pratico-shim`
  make user namespaces, which Ubuntu 24.04 allows only to programs with a profile
- enables and starts the service, and waits until it answers

The commands it runs are `systemd-sysusers`, `systemd-tmpfiles`, `apparmor_parser`, and
`systemctl`, each started directly, never through a shell. With `--files-only` it writes
the files and prints those commands for you to run instead.

## Use it from the Mac

Members of the `pratico` group use its socket. A new group takes effect at your next
login, so open a new SSH session after the install. Then, on the Mac:

```sh
docker -H ssh://you@host run --rm alpine echo hello
docker context create myhost --docker host=ssh://you@host
```

## The menubar

**Docker Host** lists your docker contexts, the current one checked; picking another is
`docker context use`, so the docker CLI and Compose go there. A shell with `DOCKER_HOST`
or `DOCKER_CONTEXT` set goes where those say instead.

Under each `ssh://` host it shows that host's pratico version, how many containers run,
and its open alerts, refreshed each minute (or with Refresh Linux Hosts). pratico fetches
them itself, over SSH, without running `ssh`:

- It reads `~/.ssh/config` for `HostName`, `Port`, `User`, `IdentityFile`,
  `UserKnownHostsFile`, and `Include`. A host reached through `ProxyJump` or
  `ProxyCommand` is not reached; `Match` blocks are not evaluated.
- It signs with key files: ed25519 and ECDSA, without a passphrase (`~/.ssh/id_ed25519`,
  `~/.ssh/id_ecdsa`, or the host's `IdentityFile`). Keys with a passphrase and keys that
  live only in an agent (1Password, Secretive, the macOS keychain) need ssh-agent
  support, which pratico adds when the SSH library it uses has it
  ([swift-nio-ssh#230](https://github.com/apple/swift-nio-ssh/issues/230)); until then the
  host shows why it was not reached, and the docker CLI, which runs your `ssh`, still
  works there.
- The host's key must already be in `known_hosts`: pratico never trusts a key on first
  use. Connect once with `ssh` to check and trust it. A changed or revoked key is refused.

## Differences from a Docker host

- The engine runs as the `pratico` user, not root. Being in the `pratico` group is not
  root on the host, as being in the `docker` group is.
- So bind mounts are read and written as the `pratico` user: a directory you mount has to
  be readable (and writable, to write to it) by the `pratico` group, for example
  `chgrp pratico ~/project/data && chmod 2770 ~/project/data`. Your home directory is
  usually not open to other users, so mount directories inside it only after sharing
  them this way.
- Containers outlive the daemon: a restart or an upgrade keeps them running. A reboot
  stops them.

## Upgrade

Extract the new release and run its `pratico-daemon install` again. The service restarts
on the new version and adopts the running containers.

## Uninstall

```sh
sudo /usr/lib/pratico/pratico-daemon uninstall
```

It lists what it stops and removes and asks first. It stops pratico's containers, disables
the service, and removes the files the install wrote. `/var/lib/pratico` (images, volumes,
logs) stays unless you add `--purge`. The `pratico` user and group stay
(`sudo userdel pratico` removes them).

## How it is tested

Two suites, the same checks (`e2e/host-checks.sh`): install, use through the docker CLI
over `ssh://` (networking, published ports, bind mounts, volumes), hardening, an upgrade
that keeps a running container, and the uninstall.

- `make e2e-testhost`, on the Mac: arm64, an Ubuntu 24.04 container with systemd and
  nested KVM, where a non-root user installs the release payload. It also runs the
  menubar's own SSH client against the service.
- `make e2e-worker WORKER=user@host LINUX_ARCH=x86_64`, on a real x86_64 Ubuntu 24.04 host
  with KVM and AppArmor, where the shim's AppArmor profile is loaded and in force. Every
  release runs it before the x86_64 tarball ships.

Not covered: other distributions, and arm64 on real hardware rather than nested KVM.
