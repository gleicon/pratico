# pratico on a Linux host

pratico runs on a Linux server too: the same Docker API, one VM per container, driven from
your Mac's docker CLI over SSH. The design and its reasons are in
[design/remote.md](design/remote.md).

## What the host needs

- arm64 (aarch64). x86_64 hosts are not supported yet.
- KVM: `/dev/kvm`, open to its group (Ubuntu's `kvm` group). Bare-metal servers have it,
  and clouds that enable nested virtualization; most VPSes do not. pratico refuses a host
  without it.
- systemd.
- The docker CLI, for `docker -H ssh://` (it runs `docker system dial-stdio` on the
  host). Only the CLI: pratico is the engine.

Nothing else: pratico's binaries are static.

## Install

Download `pratico-<version>-linux-arm64.tar.gz` and its `.sha256` from the
[releases](https://github.com/gleicon/pratico/releases), on the host:

```sh
sha256sum -c pratico-<version>-linux-arm64.tar.gz.sha256
tar -xzf pratico-<version>-linux-arm64.tar.gz
sudo ./pratico-<version>-linux-arm64/pratico-daemon install
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

`make e2e-testhost` runs on the Mac: an Ubuntu 24.04 container with systemd and KVM
(nested virtualization) where a non-root user installs the release payload with
`sudo pratico-daemon install --yes`, then drives the service from the Mac's docker CLI over
`ssh://`: networking, published ports, bind mounts and volumes, an upgrade that keeps a
running container, and the uninstall. Not covered there: loading the AppArmor profile,
since pratico's own kernel, which that test host runs, has no AppArmor (the Linux unit
tests check that Ubuntu's `apparmor_parser` accepts it); real hardware, since its KVM is
nested; and other distributions.
