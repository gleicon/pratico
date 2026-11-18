# Tooling

What pratico's own VM is built with: scripts and code written for it, kept in this
repository. None of it is part of the app; the app ships what these produce.

## Builds

| Tool | What it does |
|---|---|
| [`scripts/build-kernel.sh`](../scripts/build-kernel.sh) | Builds the guest kernel in a pratico VM: kernel.org tarball checked against its SHA-256, Debian image by digest, packages from a fixed snapshot.debian.org date. `REPRO=1` builds twice and compares; `UPDATE=1` records a new hash. |
| [`vm/kernel/build.sh`](../vm/kernel/build.sh) | Runs inside that VM: merges the configuration, fails if an option does not survive `olddefconfig`, builds with a fixed timestamp, user, host and path. |
| [`vm/kernel/config-pratico`](../vm/kernel/config-pratico) | pratico's kernel options on top of apple/containerization's, each with the reason (and, for boot time, the measurement). |
| [`vm/kernel/vmlinux.sha256`](../vm/kernel/vmlinux.sha256) | The kernel the source must build into; `make assets` checks it. |
| [`scripts/build-init.sh`](../scripts/build-init.sh) | Builds the guest init (`vminitd`, `vmexec`) in a pratico VM with Swift 6.3.3 and its static Linux SDK (image by digest, SDK by SHA-256). Same `REPRO` and `UPDATE`. |
| [`vm/init/build.sh`](../vm/init/build.sh) | Runs inside that VM: builds from `Vendor/containerization`, removes what differs between builds of the same source (build ID, `.swift_modhash`), writes the image as an OCI layout tagged by its content. |
| [`vm/init/vminit.sha256`](../vm/init/vminit.sha256) | The init image's manifest the source must build into. |
| [`scripts/fetch-runtime-assets.sh`](../scripts/fetch-runtime-assets.sh) | `make assets`: builds both once (then uses `.cache`), checks them against their hashes, and puts them where the app and tests take them. |
| [`scripts/acknowledgements.sh`](../scripts/acknowledgements.sh) | The app's Acknowledgements: licenses, and the kernel's GPL-2.0 source offer naming the tarball, its hash, and these build files. |
| [`Vendor/README.md`](../Vendor/README.md) | Where apple/containerization comes from, how upstream fixes are merged, and every file pratico changed. |

Both builds need a running pratico (they build in its VMs): the first build of each
takes 10 to 30 minutes, later ones reuse the build volume's caches.

## Seccomp

Written for pratico in `Vendor/containerization/Sources/ContainerizationOCI` (Apache-2.0,
like the code around it):

| Tool | What it does |
|---|---|
| `LinuxSeccomp+BPF.swift` | Compiles a seccomp profile to a classic BPF filter for arm64: the call found by number through a balanced tree, its rules tried in order, arguments compared as 64-bit values; refuses what it cannot install (notification listeners, errno out of range). |
| `LinuxSeccomp+Docker.swift` | Reads Docker's profile format and resolves its `includes`/`excludes` (capabilities, architectures, `minKernel`) for one container, as moby does; the OCI format is read as it is. |
| `LinuxSeccomp+SyscallsARM64.swift` | arm64's system call numbers, generated from Linux 6.18's `scripts/syscall.tbl` with the ABIs arm64 builds. |
| `Tests/PraticoDaemonKitTests/SeccompTests.swift` | A BPF interpreter that runs a compiled filter as the kernel would, checked against the profile read directly: every arm64 call, every operator at 32/64-bit boundaries, Docker's conditions, the refusals. |

`vmexec` installs the compiled filter (`installSeccomp`, through `CZ_seccomp_set_filter`
in the C shim, as musl has no wrapper), so the guest needs no runc and no libseccomp.

## Measuring

| Tool | What it shows |
|---|---|
| `PRATICO_TRACE=1` | Step timings of every start in the daemon log and each container's `shim.log`, and the guest console (kernel and `vminitd`, timestamped) in `boot.log`. |
| `initcall_debug` | Not wired in: boot profiling added it to the kernel command line for a run, to time each kernel initcall (how the 8 ms virtio resets were found). |
| `make bench` | Start latency, memory and daemon bounds against their targets. |
