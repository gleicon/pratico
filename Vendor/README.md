# Vendored code

## containerization

`containerization/` is [apple/containerization](https://github.com/apple/containerization)
(Apache-2.0) at tag `0.54.0`, commit `baf212e5a8e432e539beee325050aa26443a154d`, added
with `git subtree --squash`. It holds the host Swift package pratico links (VMs,
images, EXT4, the agent's client) and the guest init that runs in every VM (`vminitd/`:
`vminitd` and `vmexec`). Both are kept at one commit, as they speak one agent protocol.

pratico changes it for its own VM (roadmap: "Own VM, self-contained"): each changed
file says so in its header, as Apache-2.0 asks, and the changes are listed here.
Upstream fixes are merged with:

```sh
git subtree pull --prefix Vendor/containerization https://github.com/apple/containerization.git <tag> --squash
```

### Changes

- `Sources/Containerization/VZVirtualMachine+Helpers.swift` (2026-11-16): the guest
  agent is polled every 2 ms instead of 20 ms (a VM is ready about 9 ms sooner on
  average), each vsock connection attempt gives up after 1 s and the whole wait after
  10 s. Virtualization calls back only when the guest answers, so a guest that halted at
  boot used to hang the start for good.
- `Sources/ContainerizationOCI/LinuxSeccomp+BPF.swift`, `LinuxSeccomp+Docker.swift`,
  `LinuxSeccomp+SyscallsARM64.swift` (added, 2026-11-17): the seccomp compiler, Docker's
  profile format resolved per container, and arm64's call numbers.
- `Sources/ContainerizationOCI/LinuxSeccomp+Decode.swift`: `dockerFormatMarker` is
  internal, for the Docker-format reader.
- `Sources/Containerization/LinuxContainer.swift`: a seccomp profile no longer needs an
  OCI runtime, as vmexec installs it; it is compiled at init, so one that cannot be
  installed fails before a VM boots.
  `copyIn(archive:into:)` (2026-11-20) streams a tar+gzip the caller made to the guest's
  extraction as it is, so `docker cp` keeps the archive's links and owners.
- `vminitd/Sources/vmexec/vmexec.swift`, `RunCommand.swift`, `ExecCommand.swift`:
  `installSeccomp`, where runc installs it; `exec` takes `--bundle-path` for the
  container's filter.
- `vminitd/Sources/VminitdCore/ManagedProcess.swift`: passes the bundle to `vmexec exec`.
- `vminitd/Sources/LCShim/syscall.c`, `include/syscall.h`: `CZ_seccomp_set_filter`.
- `vminitd/Sources/VminitdCore/BPFObject.swift`, `Recorder.swift` (added, 2026-11-19): the
  flight recorder: reads pratico's probe object, loads and attaches it, and serves its
  ring buffer on vsock port 1028. `AgentCommand.swift` starts it at boot;
  `LCShim/syscall.c`, `include/syscall.h` add `CZ_bpf` and the ring buffer's atomics.
- `Sources/Containerization/VirtualMachineAgent.swift` (2026-11-18): `WriteFileFlags` has a
  public initializer, so pratico writes a running container's cgroup files (`docker update`).
- `Sources/CShim/exec_command.c`, `include/exec_command.h`, `Sources/ContainerizationOS/Command.swift`
  (2026-11-21): the child joins a user and a network namespace given as fds
  (`Attrs.userNamespace`, `netNamespace`) before exec; only a single-threaded process can
  join a user namespace, which the forked child is.
- `Sources/Containerization/CHVirtualMachineManager.swift`, `CHVirtualMachineInstance.swift`,
  `CHProcess.swift` (2026-11-21): `namespaces`, which cloud-hypervisor joins, so it opens
  the VM's TAP devices in pratico's per-VM network namespace (docs/design/remote.md).
  The instance pauses and resumes (`vm.pause`, `vm.resume`), for `docker pause`.
- `Sources/CloudHypervisor/Types/DeviceConfigs.swift` (2026-11-21): `NetConfig`'s
  `offload_tso`, `offload_ufo` and `offload_csum`, so pratico's switch gets plain frames.
