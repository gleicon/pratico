# Sourced by e2e/testhost.sh (the test host on the Mac) and e2e/worker.sh (a real Linux
# host): pratico installed from a release payload, used through the service, upgraded, and
# uninstalled, the same checks wherever the host is. The caller defines:
#   onhost CMD…     a command on the host as root      asuser CMD…  as the installing user
#   remote ARGS…    the Mac's docker CLI over ssh://, as that user
#   check/expect_eq/eventually_eq/ok/bad, and PAYLOAD (the extracted release on the host),
#   SERVER_ARCH (linux/arm64 or linux/amd64), USER_NAME, INSTALL_LOG, and optionally
#   before_install (a function) and MENUBAR_SSH (a function: the menubar's own SSH check).

not() { ! "$@"; }

check "host: reachable over ssh" onhost true
check "host: systemd" onhost test -d /run/systemd/system
check "host: /dev/kvm" onhost test -c /dev/kvm
# Static (musl): a host installs nothing for pratico, and none of its libraries are there.
check "host: nothing from Docker is installed" onhost "! dpkg -l docker.io docker-ce docker-ce-cli containerd runc 2>/dev/null | grep -q '^ii'"
check "host: pratico is statically linked" onhost "for b in pratico-daemon pratico-shim; do ldd $PAYLOAD/\$b 2>&1 | grep -q 'not a dynamic executable' || exit 1; done"
if declare -F before_install >/dev/null; then before_install; fi
asuser sudo "$PAYLOAD/pratico-daemon" install --yes >"$INSTALL_LOG" 2>&1
expect_eq "install: sudo pratico-daemon install --yes" "$?" "0"
expect_eq "install: every installed file is root's, writable by root only" "$(onhost "find /usr/lib/pratico \\( ! -user root -o ! -group root -o -perm /022 -o -type l \\) | wc -l" 2>&1)" "0"
expect_eq "install: the service runs" "$(onhost systemctl is-active pratico.service 2>&1)" "active"
expect_eq "install: as the pratico user, not root" "$(onhost ps -o user= -C pratico-daemon 2>&1 | sort -u)" "pratico"
expect_eq "install: its socket is the pratico group's" "$(onhost "stat -c '%U:%G %a' /run/pratico/docker.sock" 2>&1)" "pratico:pratico 660"
expect_eq "install: docker system dial-stdio is pratico's" "$(onhost readlink /usr/local/bin/docker 2>&1)" "/usr/lib/pratico/pratico-daemon"
expect_eq "install: and answers nothing else of Docker's" "$(asuser docker ps >/dev/null 2>&1; echo $?)" "1"
expect_eq "install: the docker CLI's default socket points at it" "$(onhost readlink /run/docker.sock 2>&1)" "/run/pratico/docker.sock"
expect_eq "install: $USER_NAME is in the pratico group" "$(asuser id -nG 2>&1 | tr ' ' '\n' | grep -x pratico)" "pratico"
# Hardening (HostHardening): the plan's kernel settings, security packages, firewall.
expect_eq "harden: kernel settings applied" "$(onhost sysctl -n kernel.kptr_restrict net.core.bpf_jit_harden 2>&1 | xargs)" "2 2"
expect_eq "harden: fail2ban runs" "$(onhost systemctl is-active fail2ban.service 2>&1)" "active"
expect_eq "harden: security updates on" "$(onhost apt-config dump APT::Periodic::Unattended-Upgrade 2>&1 | grep -o '"1"')" '"1"'
check "harden: the firewall is on and lets SSH in" onhost "ufw status | grep -q 'Status: active' && ufw status | grep -qE '^22/tcp +ALLOW'"
caps='grep CapEff /proc/$(pgrep -o pratico-daemon)/status | cut -f2'
expect_eq "install: no capability on the host" "$(onhost "$caps" 2>&1)" "0000000000000000"
if declare -F MENUBAR_SSH >/dev/null; then check "menubar SSH: pratico's own client reaches the service" MENUBAR_SSH; fi
expect_eq "ssh://: server is pratico on Linux" "$(remote version --format '{{.Server.Os}}/{{.Server.Arch}}' 2>&1)" "$SERVER_ARCH"
check "ssh://: pull alpine" remote pull -q alpine
expect_eq "ssh://: run alpine true" "$(remote run --rm --network none alpine sh -c 'echo ran' 2>&1)" "ran"
expect_eq "ssh://: exit code comes back" "$(remote run --rm --network none alpine sh -c 'exit 3' >/dev/null 2>&1; echo $?)" "3"
expect_eq "net: DNS from the switch" "$(remote run --rm alpine sh -c 'nslookup -type=a example.com >/dev/null && echo resolved' 2>&1)" "resolved"
expect_eq "net: out to the internet" "$(remote run --rm alpine sh -c 'wget -q -T 10 -O /dev/null http://example.com && echo fetched' 2>&1)" "fetched"
check "net: user network" remote network create th-net
remote run -d --name th-server --network th-net alpine sh -c 'while true; do echo hello | nc -l -p 8080; done' >/dev/null 2>&1
expect_eq "net: containers reach each other by name" "$(remote run --rm --network th-net alpine sh -c 'for i in 1 2 3 4 5; do nc -w 2 th-server 8080 && break; sleep 1; done' 2>&1)" "hello"
remote run -d --name th-published -p 18080:8080 alpine sh -c 'while true; do echo published | nc -l -p 8080; done' >/dev/null 2>&1
eventually_eq "net: a published port on the host" published onhost "echo | timeout 3 nc -q 1 127.0.0.1 18080"
remote rm -f th-server th-published >/dev/null 2>&1
check "net: network rm" remote network rm th-net

# Bind mounts are read and written as the pratico user: the user shares the directory with
# the group, as docs/linux-hosts.md says to.
asuser "rm -rf /tmp/th-share && mkdir -p /tmp/th-share && chgrp pratico /tmp/th-share && chmod 2770 /tmp/th-share && echo from-host >/tmp/th-share/in && chmod 640 /tmp/th-share/in"
expect_eq "fs: a bind mount reads the host's files" "$(remote run --rm -v /tmp/th-share:/share alpine cat /share/in 2>&1)" "from-host"
remote run --rm -v /tmp/th-share:/share alpine sh -c 'echo from-vm >/share/out' >/dev/null 2>&1
expect_eq "fs: and writes them" "$(asuser cat /tmp/th-share/out 2>&1)" "from-vm"
remote run --rm -v th-vol:/data alpine sh -c 'echo kept >/data/f' >/dev/null 2>&1
expect_eq "fs: a named volume outlives its container" "$(remote run --rm -v th-vol:/data alpine cat /data/f 2>&1)" "kept"
check "fs: volume rm" remote volume rm th-vol
asuser "rm -rf /tmp/th-share"

remote run -d --name sleeper --network none alpine sh -c 'echo up; sleep 600' >/dev/null 2>&1
check "host: the container is a Cloud Hypervisor VM" onhost pgrep -f /usr/lib/pratico/cloud-hypervisor
expect_eq "ssh://: ps lists it" "$(remote ps --format '{{.Names}}' 2>&1)" "sleeper"
eventually_eq "ssh://: logs" up remote logs sleeper
# An upgrade is the same install again: the service restarts and adopts its containers.
asuser sudo "$PAYLOAD/pratico-daemon" install --yes >>"$INSTALL_LOG" 2>&1
expect_eq "upgrade: install again" "$?" "0"
expect_eq "upgrade: the container kept running" "$(remote inspect sleeper --format '{{.State.Running}}' 2>&1)" "true"
check "ssh://: rm -f" remote rm -f sleeper
check "host: its VM is gone" not onhost pgrep -f /usr/lib/pratico/cloud-hypervisor

remote run -d --name left --network none alpine sleep 600 >/dev/null 2>&1
asuser sudo /usr/lib/pratico/pratico-daemon uninstall --yes >>"$INSTALL_LOG" 2>&1
expect_eq "uninstall: sudo pratico-daemon uninstall --yes" "$?" "0"
check "uninstall: the service is gone" not onhost systemctl cat pratico.service
check "uninstall: its files are gone" onhost "! test -e /usr/lib/pratico && ! test -e /run/docker.sock && ! test -e /usr/lib/sysusers.d/pratico.conf && ! test -L /usr/local/bin/docker"
eventually_eq "uninstall: its containers stopped" 0 onhost "pgrep -c -f /usr/lib/pratico/[c]loud-hypervisor || true"
check "uninstall: images and volumes kept" onhost test -d /var/lib/pratico/store
check "uninstall: its firewall off, its settings files gone" onhost "ufw status | grep -q 'Status: inactive' && ! test -e /etc/sysctl.d/90-pratico-hardening.conf && ! test -e /etc/apt/apt.conf.d/21pratico-auto-upgrades"
