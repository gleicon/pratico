# CPU

Containers run `linux/arm64` natively on Apple silicon: no emulation, no translation.
Images without an arm64 variant do not run; pull picks the arm64 variant of a
multi-platform image.

## vCPUs

A container's CPU limit is its VM's vCPU count.

- `--cpus N` gives the VM `N` vCPUs, rounded up to a whole number: `--cpus 0.5` and
  `--cpus 1` both get one.
- Without `--cpus`, a VM gets `default_cpus` (4) from `~/.pratico/config.toml`.
- A vCPU is a thread on the Mac, scheduled by macOS. An idle guest's vCPUs sleep.
- `--cpu-shares`, `--cpu-quota`, `--cpu-period`, and `--cpuset-cpus` are accepted and not
  applied. The vCPU count is the only CPU control; VMs compete for the Mac's cores as
  any other processes do.

## Stats

`docker stats` reads CPU time from the guest agent. `online_cpus` is the VM's vCPU
count, and 100% is one vCPU busy, as on Docker 100% is one host CPU: a container using
all of a two-vCPU VM shows 200%. The menubar samples every
4 seconds without a client.

## Pause

`docker pause` pauses the VM: its vCPUs stop, with no freezer cgroup involved.
`docker unpause` resumes them.

Decisions: SPEC D-26, D-33, D-35.
