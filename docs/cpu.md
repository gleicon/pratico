# CPU

Containers run `linux/arm64` natively on Apple silicon: no emulation, no translation.
Images without an arm64 variant do not run; pull picks the arm64 variant of a
multi-platform image.

## vCPUs

A container's VM has `--cpus` vCPUs, rounded up to a whole number, and the container's
cgroup in the guest holds the exact limit.

- `--cpus 0.5` boots one vCPU and sets `cpu.max` to `50000 100000`: half of it.
- `--cpu-quota` and `--cpu-period` set `cpu.max` directly; the VM gets enough vCPUs for
  the quota. `--cpus` and `--cpu-period` together are refused, as on Docker.
- `--cpu-shares` sets `cpu.weight`. The container is the only workload in its VM, so the
  weight only matters against processes it starts in other cgroups.
- `--cpuset-cpus` pins to vCPUs, which must exist: `--cpuset-cpus 0-7` needs `--cpus 8`.
- Without `--cpus`, a VM gets `default_cpus` (4) from `~/.pratico/config.toml`.
- A vCPU is a thread on the Mac, scheduled by macOS, competing for cores with every other
  process. An idle guest's vCPUs sleep.

## Stats

`docker stats` reads CPU time from the guest agent. `online_cpus` is the VM's vCPU
count, and 100% is one vCPU busy, as on Docker 100% is one host CPU: a container using
all of a two-vCPU VM shows 200%. The menubar samples every
4 seconds without a client.

## Pause

`docker pause` pauses the VM: its vCPUs stop, with no freezer cgroup involved.
`docker unpause` resumes them.

All run options: [run-options.md](run-options.md). Decisions: SPEC D-26, D-33, D-35, D-45.
