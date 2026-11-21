# Remote Linux hosts (design, 2026-11-20)

Status: proposed. Nothing here is built; the roadmap's "Remote Linux hosts" section holds
what is decided. This note sizes the work and lists what still needs a decision.

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
It serves the same API on `/var/run/pratico/docker.sock`; `/pratico/*`, the switch, egress,
scanning, and the flight recorder are the same code.

## Measured facts

- The vendored containerization has a Linux backend: `CHVirtualMachineManager` drives
  Cloud Hypervisor on KVM, with `virtiofsd` for shared directories and TAP devices.
- This Mac (M5, macOS 26.4) supports nested virtualization
  (`VZGenericPlatformConfiguration.isNestedVirtualizationSupported`), so a Linux VM here
  can run KVM: the Linux host can be built and tested on the Mac. arm64 only.
- pratico's kernel has no KVM (`config-pratico`), so the test host needs a kernel with
  `CONFIG_KVM`.
- `docker` over `ssh://` runs `docker system dial-stdio` on the host: the host needs the
  docker CLI (only the CLI package, no engine), with `DOCKER_HOST` pointing at pratico's socket.
- Most VPSes do not expose `/dev/kvm`. KVM is there on bare-metal servers and on clouds
  that enable nested virtualization; most cheap VPSes are x86_64.

## What does not port as is

| Area | On the Mac | On Linux |
|---|---|---|
| VM boot (`Shim.swift`) | Virtualization.framework | Cloud Hypervisor process per VM (vendored `CHVirtualMachineManager`) |
| Shared directories | virtio-fs built into VZ | one `virtiofsd` process per share |
| NIC (`Net/NIC.swift`) | socket pair to the switch | see decision 3 |
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
3. NIC: to settle before slice 3. Agreed first as "a TAP device per VM read by the switch",
   but Cloud Hypervisor owns the TAP's file descriptor (it opens the device and moves the
   guest's frames through it), so the switch cannot read that end. The options:
   - AF_PACKET on the TAP's host interface: the switch sends and receives the guest's frames
     there. Needs `CAP_NET_ADMIN` and `CAP_NET_RAW`; the host kernel sees an interface with
     no address, kept quiet (no IPv6, no ARP).
   - vhost-user-net served by the switch: Cloud Hypervisor hands the guest's virtio queues
     to pratico over a Unix socket. No capability and no host interface at all, so the
     guest's frames never meet the host's network stack; more code (the vhost-user protocol
     and virtio rings in shared guest memory).

## Slices, in order

1. Daemon compiles for Linux; platform seams for VM boot, NIC, TLS trust and logins;
   unit tests pass on Linux (`scripts/linux-check.sh`). Done 2026-11-20, against glibc in
   the pinned Swift image; the static (musl) build comes with slice 2.
2. Test host on the Mac: a Linux VM with KVM and the Linux daemon; `docker -H ssh://` runs
   `alpine true` in a Cloud Hypervisor VM.
3. Networking and egress through the switch on Linux; the e2e suite runs against the test host.
4. Install over SSH: one documented command, systemd unit, `pratico` user.
5. Menubar: hosts list over swift-nio-ssh, `/pratico/*` from each, active host written to
   the docker context.
6. x86_64: kernel, init, probes, and the seccomp syscall table; e2e on an x86_64 KVM host.
