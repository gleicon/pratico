# Run options

Every `docker run` / `docker create` option pratico accepts is applied. An option it
cannot apply is refused with an error that names it, never silently dropped. Values the
Docker CLI sends by default (zero, empty, `private`) are accepted.

## Applied

| Option | How |
|---|---|
| `--cpus` | VM vCPUs (rounded up) plus `cpu.max` in the container's cgroup, so `--cpus 0.5` is half a CPU |
| `--cpu-quota`, `--cpu-period` | `cpu.max`; the VM gets enough vCPUs to use the quota |
| `--cpu-shares` | `cpu.weight` (runc's conversion) |
| `--cpuset-cpus` | `cpuset.cpus`; IDs must exist in the VM (`--cpus`, default 4) |
| `-m`, `--memory` | guest RAM and `memory.max` |
| `--memory-reservation` | `memory.low` |
| `--memory-swap` | `memory.swap.max` (`-1` unlimited) |
| `--pids-limit` | `pids.max` |
| `--cap-add`, `--cap-drop` | capability sets, from Docker's default 14 |
| `--privileged` | every capability, no masked or read-only `/proc` paths |
| `--security-opt no-new-privileges` | `no_new_privs` on the process |
| `--security-opt systempaths=unconfined` | no masked or read-only `/proc` paths |
| `--read-only` | root filesystem mounted read-only |
| `--sysctl`, `--domainname` | guest sysctls (`kernel.domainname`) |
| `--ulimit` | process rlimits |
| `--shm-size` | size of `/dev/shm` |
| `--user`, `--group-add` | resolved against the image's `/etc/passwd` and `/etc/group` |
| `--hostname` | guest hostname and `/etc/hosts` |
| `--dns`, `--dns-search`, `--dns-option` | `/etc/resolv.conf`, kept when the primary network changes |
| `--add-host` (`host-gateway` too) | `/etc/hosts` |
| `--ip`, `--mac-address` | the address and MAC on that network (user-defined networks for `--ip`, as on Docker) |
| `--link` | `/etc/hosts` entries for the target, which must run and share a network |
| `-P` | every exposed port, image `EXPOSE` included, on a free host port |
| `--init` | an init as PID 1 that forwards signals and reaps zombies |
| `--stop-signal`, `--stop-timeout` | used by `docker stop` and when the Mac logs out (image `STOPSIGNAL` too) |
| `--restart` | `no`, `always`, `unless-stopped`, `on-failure[:N]`; see below |
| `--log-driver json-file` or `local`, `--log-opt max-size`, `max-file` | the cap of pratico's log store |

Image `USER`, `STOPSIGNAL`, `EXPOSE`, and labels apply unless the request overrides them.

`docker exec` and healthchecks run with the container's capabilities, `no-new-privileges`,
ulimits, and groups; `docker exec --privileged` gets every capability for that process.

### Restart policies

A container that exits is started again when its policy says so, after a delay that
doubles from 100 ms to a minute and resets once a run lasts 10 seconds. `docker stop` and
`docker kill` count as a stop by hand: `always` then waits for the daemon's next start,
`unless-stopped` stays down until started. When the daemon starts (at login, after the
Mac restarts), `always` and `unless-stopped` containers come back. `RestartCount` in
`docker inspect` counts policy restarts since the last start by hand.

## Refused

| Option | Why |
|---|---|
| `--device`, `--gpus`, `--device-cgroup-rule` | a VM has no host devices |
| `--blkio-weight`, `--device-read-bps` and the other blkio options | the VM's disk is not a host device |
| `--pid`, `--ipc`, `--uts`, `--cgroupns` other than private; `--userns` other than `host` | each container is its own VM, with its own namespaces |
| `--network host`, `--network container:…` | same |
| `--security-opt seccomp=<profile>`, `apparmor=<profile>`, `label=<…>` | pratico applies no seccomp, AppArmor, or SELinux policy inside the VM; `seccomp=unconfined`, `apparmor=unconfined`, and `label=disable` are accepted |
| `--oom-kill-disable`, `--kernel-memory`, `--memory-swappiness` | cgroup v2 has no such control |
| `--oom-score-adj` | the guest agent cannot set it |
| `--cpu-rt-period`, `--cpu-rt-runtime` | the guest kernel has no real-time group scheduling |
| `--cgroup-parent` | each container is its VM's only cgroup |
| `--volumes-from` | name the volumes with `-v` instead |
| `--storage-opt` | the root filesystem is a disk image per container |
| `--ip6`, `--link-local-ip`, `-p` on an IPv6 address | pratico-net is IPv4 only |
| `--log-driver` other than `json-file` and `local`; log options other than `max-size` and `max-file` | logs stay in pratico's own store |
| `--runtime`, `--isolation` other than the default | one runtime |

## Isolation

Without a seccomp filter, a container can make any system call its capabilities allow,
to its own kernel. That kernel runs in its own VM: the boundary between containers, and
between a container and the Mac, is the hypervisor, not a syscall filter.

Decisions: SPEC D-45.
