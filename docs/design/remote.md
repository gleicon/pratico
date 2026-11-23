# Remote Linux hosts (design, 2026-11-20)

Status: in progress, slices 1 to 5 done (below): installable on arm64 hosts
([linux-hosts.md](../linux-hosts.md)). The
roadmap's "Remote Linux hosts" section holds what is decided.

## Settled (roadmap, 2026-11-20)

- KVM required: one VM per container, as on the Mac. A host without `/dev/kvm` is refused.
- SSH only. The docker CLI reaches a host through an `ssh://` context; the menubar reads
  hosts through a native SSH client (swift-nio-ssh), never a spawned `ssh`. No TCP API port,
  no authentication of pratico's own.
- The menubar shows every host and sets the active one by writing the docker context.
  No forwarding, proxy, or orchestrator; no pratico CLI.

## What runs on the host

`pratico-daemon` built for Linux with the Swift static Linux SDK (as `vminitd` already is),
one binary with no runtime dependencies, run by systemd as an unprivileged `pratico` user.
It serves the same API on `/run/pratico/docker.sock`, which members of the `pratico` group
use (`/run/docker.sock` links to it when no other engine has that); `/pratico/*`, the
switch, egress, scanning, and the flight recorder are the same code. How to install it:
[linux-hosts.md](../linux-hosts.md).

## Measured facts

- The vendored containerization has a Linux backend: `CHVirtualMachineManager` drives
  Cloud Hypervisor on KVM, with `virtiofsd` for shared directories and TAP devices.
- This Mac (M5, macOS 26.4) supports nested virtualization
  (`VZGenericPlatformConfiguration.isNestedVirtualizationSupported`), so a Linux VM here
  can run KVM: the Linux host can be built and tested on the Mac. arm64 only.
- pratico's kernel has KVM built in (`CONFIG_KVM=y`, from upstream's `config-arm64`), but
  Virtualization.framework boots a VM without hypervisor mode unless it asks for nested
  virtualization: the guest logs `kvm: HYP mode not available` and has no `/dev/kvm`, even
  with `--privileged`. The test host is the one VM that asks, through
  `--runtime pratico-testhost`, which only a daemon started with `PRATICO_TESTHOST=1`
  accepts; its guest logs `Hyp nVHE mode initialized successfully` (2026-11-21).
- Nested virtualization is slow: in the test host a VM boots in about 15 s and starts its
  process in about 9 more (`PRATICO_TRACE=1`), against well under a second on the Mac.
  A `docker run alpine true` takes 23 to 36 s (twenty in a row, test host at 4 CPUs, the
  Mac otherwise idle); other work on the Mac stretches one to 100 s, and past Cloud
  Hypervisor's 60 s wait for the agent once several boot at once. It proves behavior, not
  speed: timing checks there (CPU sampled within 5 s, a boot within 60 s) measure the
  nesting.
- Shims outlive their daemon, as containers do, so an e2e run killed outright leaves its
  VMs holding memory: seven left test hosts (6 GB each) made a later VM fail to start
  (`VZErrorDomain Code=1`). `e2e/reap.sh` stops those of earlier runs whose daemon is gone.
- `docker` over `ssh://` runs `docker system dial-stdio` on the host. pratico answers it
  itself (`pratico-daemon dial-stdio`, linked as `/usr/local/bin/docker` where no docker is
  installed): a host gets nothing from Docker (decided with the user, 2026-11-23).
- Most VPSes do not expose `/dev/kvm`. KVM is there on bare-metal servers and on clouds
  that enable nested virtualization; most cheap VPSes are x86_64.

## What does not port as is

| Area | On the Mac | On Linux |
|---|---|---|
| VM boot (`Shim.swift`) | Virtualization.framework | Cloud Hypervisor process per VM (vendored `CHVirtualMachineManager`) |
| Shared directories | virtio-fs built into VZ | one `virtiofsd` process per share, 1.15.0 built static by `scripts/build-virtiofsd.sh` (done) |
| NIC (`Net/NIC.swift`) | socket pair to the switch | TAP in a namespace of the VM's own, AF_PACKET to the switch: decision 3 (done) |
| Socket calls (`Darwin.*`) | Darwin | Glibc/Musl: mechanical |
| Registry TLS trust, proxies | Security, CFNetwork | AsyncHTTPClient with BoringSSL: the system bundle plus `registry_ca` (which root vouched is not reported); `HTTPS_PROXY`/`NO_PROXY` (done) |
| Registry logins, abuse.ch key | Keychain | `<home>/secrets/<domain>.json`, 0600 in a 0700 directory (done) |
| Log follow, free space, image copies | kqueue, resource keys, `clonefile` | inotify, `statvfs`, data-extent copies that keep holes (done) |
| Shim exit | kqueue process source | a waiting thread per child; an earlier daemon's shims checked each second (done) |
| Login job | launchd | systemd unit |
| Kernel, init, probes, seccomp | arm64 | arm64, and x86_64 for most hosts: second kernel and init build, x86_64 syscall table for the seccomp compiler, probes against x86_64 kernel types |

## Decisions (2026-11-20)

1. Architectures: both. arm64 first, built and tested on the Mac; then x86_64, tested on
   a fresh x86_64 Ubuntu VM with KVM (the cheapest, most available hosts).
2. VMM: Cloud Hypervisor (proposed; confirmed before slice 2 boots a VM). Rust on the
   rust-vmm crates, virtio devices only, used by Kata Containers and Azure; the vendored
   backend already drives it. QEMU's C device model is far larger and carries most of the
   hypervisor CVEs; Firecracker lacks virtio-fs and hotplug. Shipped as a pinned,
   latest-release binary with pratico's Linux build, spawned directly, never through a shell,
   in the role Virtualization.framework has on the Mac; `virtiofsd` likewise.
3. NIC (settled 2026-11-20, simple and fast first): each VM gets a network namespace of its
   own, made through a user namespace. In it the shim creates the TAP device, runs Cloud
   Hypervisor, and opens an AF_PACKET socket on the TAP's interface; it relays frames between
   that socket and the switch as the Mac's relay does with its socket pair. The namespace has
   no routes, no addresses, and no forwarding, so a guest's frames reach only pratico's switch
   (egress holds even on a host with `ip_forward=1`). The shim holds `CAP_NET_ADMIN` and
   `CAP_NET_RAW` only inside its own user namespace: the service needs no capability on the
   host. Ubuntu 24.04 limits unprivileged user namespaces through AppArmor, so the install
   ships a profile for `pratico-shim`. Not taken: vhost-user-net (about a thousand lines of
   virtio rings over guest memory, all of it attack surface) and a TAP on the host's own
   network (guest frames meet the host's stack and forwarding).

   VMM, looked at again for this: QEMU's `-netdev dgram` would match the Mac's socket pair,
   but its vsock needs the host kernel's `/dev/vhost-vsock` (more privilege, host-wide CIDs)
   and its device model is far larger; Firecracker has no virtio-fs, so no bind mounts or
   shares. Cloud Hypervisor stays: vsock over a Unix socket, virtio-fs through `virtiofsd`,
   already vendored.

## Slices, in order

1. Daemon compiles for Linux; platform seams for VM boot, NIC, TLS trust and logins;
   unit tests pass on Linux (`scripts/linux-check.sh`). Done 2026-11-20, against glibc in
   the pinned Swift image.
2. Test host on the Mac: a Linux VM with KVM and the Linux daemon; `docker -H ssh://` runs
   `alpine true` in a Cloud Hypervisor VM. Done 2026-11-21 (`make e2e-testhost`): an
   Ubuntu 24.04 container on `--runtime pratico-testhost` with sshd and the docker CLI;
   the daemon and shim built in the pinned Swift image with the Swift runtime linked in
   (`scripts/linux-check.sh host`; static since slice 4), Cloud
   Hypervisor v55.0 pinned by SHA-256. Containers run with `--network none` until slice 3.
3. Networking and egress through the switch on Linux; `virtiofsd`, pinned, for volumes and
   bind mounts; the e2e suite runs against the test host. Done 2026-11-21: `pratico_vm_netns`
   (`Sources/CPratico/netns.c`) makes each VM's user and network namespaces, TAPs and packet
   sockets in a forked child; Cloud Hypervisor joins them before exec (vendored
   `exec_command`), with offloads off so frames reach the switch whole; its sockets live in
   `<home>/run/ch`, not a directory every daemon on the host shares. `make e2e-testhost`
   checks DNS, egress, user networks, published ports, bind mounts and volumes (21 checks);
   `e2e/run.sh` runs inside the test host as well, as a record rather than a gate: its
   failures there were Mac-only checks (Time Machine) and nesting's timing (below), each
   looked at. A shim that has not booted its VM within 120 s is killed and the start fails,
   instead of the daemon going on to a shim not yet listening.
4. Install: done 2026-11-22. `sudo pratico-daemon install`, from the extracted
   `pratico-<version>-linux-arm64.tar.gz` (`make linux-dist`, attached to each release),
   checks the host (arm64, `/dev/kvm` open to its group, systemd), shows what it writes and
   runs, and asks; then copies the release to `/usr/lib/pratico` by rename, writes the
   unit, sysusers, tmpfiles and (with AppArmor) the shim's profile, and runs
   `systemd-sysusers`, `systemd-tmpfiles`, `apparmor_parser` and `systemctl`, exec'd from
   fixed paths, never a shell (`--files-only` prints them instead). The unit runs as
   `pratico` with no capability, `NoNewPrivileges`, `DevicePolicy=closed` with `/dev/kvm`
   and `/dev/net/tun`, `RestrictNamespaces=user net mnt pid`, and `KillMode=process` so a
   restart or upgrade keeps containers. Found on the way: `ProtectKernelTunables`,
   `ProtectKernelLogs` and `ProtectHostname` each mount over part of `/proc`, and then
   virtiofsd's sandbox cannot mount its own (`MountProc`, EPERM) and the shim cannot turn
   IPv6 off in a VM's namespace: left out. Bind mounts are read and written as `pratico`,
   so shared directories need its group. `uninstall` stops the containers (SIGTERM, then
   SIGKILL after 30 s), removes what install wrote, keeps `/var/lib/pratico` unless
   `--purge`. `make e2e-testhost` boots systemd in the test host, where a non-root user
   installs, uses, upgrades and uninstalls pratico. The daemon and shim are static (musl, the Swift static Linux SDK), with no
   FoundationNetworking and so no libcurl; the test host image installs none of their
   libraries, and checks they are static. The SDK's own libarchive (3.8.1) trailed
   upstream by ten releases, and a static binary takes no distribution's fixes:
   `scripts/build-libs.sh` builds libarchive (tar with gzip, bzip2 and xz only), zlib,
   bzip2 and xz at their current releases, pinned by SHA-256, and the build fails unless
   the binary carries that libarchive. Every Swift package is at its latest release
   (swift-crypto 5.1.2, past the vendored containerization's `<5.0.0`).
5. Menubar: done 2026-11-23. Docker Host lists the docker contexts (pratico keeps no
   list) and makes one current by writing `currentContext` in `config.json`, 0600 from
   creation, through a symlink. Each `ssh://` context shows its daemon's version,
   containers, and alerts (`GET /pratico/alerts`, added for it), from PraticoRemote:
   swift-nio-ssh, `docker system dial-stdio` on the host, one request per channel.
   swift-nio-ssh reads no key files and signs with no agent (#94, #189, #230, PR #220), so
   pratico parses `openssh-key-v1` ed25519 and ECDSA keys itself and refuses passphrase and
   agent-only keys with that reason; ssh-agent comes when upstream has it (decided with
   the user: data now from key files, the agent later, no patched fork). Host keys only
   from `known_hosts`, hashed entries included, never trust on first use; `~/.ssh/config`
   for HostName, Port, User, IdentityFile, UserKnownHostsFile, Include; ProxyJump and
   ProxyCommand refused. `make e2e-testhost` runs PraticoRemote against the installed
   service as `dev`.
6. x86_64: kernel, init, probes, and the seccomp syscall table; e2e on an x86_64 KVM host.
