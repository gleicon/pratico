#!/usr/bin/env bash
# End-to-end checks for pratico's runtime (docs/design/runtime.md): the real `docker` CLI
# against pratico-daemon, covering shims, the guest agent, pratico-net, and registries.
# Usage: e2e/embedded.sh <bin-dir>     (or: make e2e-embedded)
set -uo pipefail

BIN="${1:?usage: e2e/embedded.sh <bin-dir>}"
DOCKER="${DOCKER:-/opt/homebrew/bin/docker}"
[ -x "$DOCKER" ] || { echo "e2e needs the docker CLI at $DOCKER"; exit 1; }
docker() { "$DOCKER" "$@"; }
ASSETS="${PRATICO_RUNTIME_ASSETS:-$(pwd)/.build/runtime-assets}"
[ -f "$ASSETS/vmlinux" ] || { echo "runtime assets missing: run make assets"; exit 1; }

HOME_DIR="$(mktemp -d -t pratico-emb)"
SOCK="$HOME_DIR/docker.sock"
export DOCKER_HOST="unix://$SOCK"
export DOCKER_CONFIG="$HOME_DIR/docker-config"
mkdir -p "$DOCKER_CONFIG"
echo '{"auths":{"pratico.invalid":{}}}' >"$DOCKER_CONFIG/config.json"
export PRATICO_RUNTIME_ASSETS="$ASSETS"
export PRATICO_SYFT_BIN=/nonexistent PRATICO_OSV_BIN=/nonexistent PRATICO_GRYPE_BIN=/nonexistent PRATICO_TRIVY_BIN=/nonexistent  # no scanning here
DAEMON_PID=""

pass=0
fail=0
ok() { echo "ok   $1"; pass=$((pass + 1)); }
bad() { echo "FAIL $1${2:+ — $2}"; fail=$((fail + 1)); }
check() { local name="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$name"; else bad "$name"; fi; }
expect_has() { if grep -qF -- "$3" <<<"$2"; then ok "$1"; else bad "$1" "want [$3] in [$2]"; fi; }
# A check on state that settles (a NIC coming up, ARP, a listener): retried for up to 5 s,
# so it waits on the state, not on a guess at how long it takes.
eventually() { local name="$1"; shift; for _ in $(seq 25); do "$@" >/dev/null 2>&1 && { ok "$name"; return; }; sleep 0.2; done; bad "$name"; }
expect_eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "want [$3] got [$2]"; fi; }

start_daemon() {
    "$BIN/pratico-daemon" --home "$HOME_DIR" >>"$HOME_DIR/daemon.log" 2>&1 &
    DAEMON_PID=$!
    for _ in $(seq 100); do [ -S "$SOCK" ] && return 0; sleep 0.1; done
    echo "daemon did not start"; cat "$HOME_DIR/daemon.log"; exit 1
}
stop_daemon() {
    [ -n "$DAEMON_PID" ] && kill "$DAEMON_PID" 2>/dev/null && wait "$DAEMON_PID" 2>/dev/null
    DAEMON_PID=""
}
cleanup() {
    if [ -S "$SOCK" ]; then
        ids=$(docker ps -aq 2>/dev/null)
        [ -n "$ids" ] && docker rm -f $ids >/dev/null 2>&1
    fi
    stop_daemon
    rm -rf "$HOME_DIR"
}
trap cleanup EXIT

start_daemon
out=$(docker run --rm alpine sh -c 'echo hello; exit 7' 2>&1)
rc=$?
expect_eq "run --rm prints output" "$(tail -1 <<<"$out")" "hello"
expect_eq "run --rm returns the exit code" "$rc" "7"
check "image is listed" test "$(docker images --format '{{.Repository}}:{{.Tag}}' | grep -c '^alpine:latest$')" = 1
# The kernel the app bundles: its Linux version, from the pinned asset's name.
kernel=$(sed -n 's|^KERNEL_MEMBER=.*/vmlinux-\([0-9.]*\)-.*|\1|p' scripts/fetch-runtime-assets.sh)
expect_eq "kernel is pratico's ($kernel)" "$(docker run --rm alpine uname -r)" "$kernel"

# stdin and terminals
expect_eq "run -i pipes stdin" "$(printf 'a\nb\nc\n' | docker run -i --rm alpine wc -l | tr -d ' ')" "3"
PTY="python3 -I $(dirname "$0")/pty.py"
expect_eq "run -it gets a sized tty" "$($PTY 33 111 "$DOCKER" run -it --rm alpine sh -c 'sleep 1; tty; stty size' | tr -d '\r' | xargs)" "/dev/pts/0 33 111"
typed=$( (sleep 3; printf 'echo typed-$((6*7))\n'; sleep 1; printf 'exit 5\n') | $PTY 24 80 sh -c "$DOCKER run -it --rm alpine sh; echo rc=\$?" | tr -d '\r')
check "an interactive shell runs what is typed" grep -q 'typed-42' <<<"$typed"
expect_eq "it returns the shell's exit code" "$(tail -1 <<<"$typed")" "rc=5"
docker run --rm alpine /nonexistent >/dev/null 2>&1
expect_eq "a missing executable exits 127" "$?" "127"

# healthchecks run through the shim's agent
docker run -d --name e-hc --health-cmd 'test -f /tmp/ok' --health-interval 1s --health-retries 2 \
    alpine sh -c 'sleep 4; touch /tmp/ok; sleep 300' >/dev/null
sleep 3.5
expect_eq "healthcheck reports unhealthy" "$(docker inspect e-hc --format '{{.State.Health.Status}}')" "unhealthy"
sleep 3
expect_eq "and recovers to healthy" "$(docker inspect e-hc --format '{{.State.Health.Status}}')" "healthy"
docker rm -f e-hc >/dev/null

# exec, cp, stats through the guest agent
docker run -d --name e-box alpine sleep 600 >/dev/null
expect_eq "exec prints output" "$(docker exec e-box echo ok)" "ok"
docker exec e-box sh -c 'exit 3'
expect_eq "exec returns the exit code" "$?" "3"
expect_eq "exec keeps stderr separate" "$(docker exec e-box sh -c 'echo out; echo err >&2' 2>/dev/null)" "out"
expect_eq "exec -i pipes stdin" "$(echo piped | docker exec -i e-box cat)" "piped"
expect_eq "exec -it gets a sized tty" "$($PTY 33 111 "$DOCKER" exec -it e-box sh -c 'sleep 1; tty; stty size' | tr -d '\r' | xargs)" "/dev/pts/0 33 111"
docker exec -d e-box sh -c 'echo d > /tmp/d'
sleep 1
expect_eq "exec -d runs detached" "$(docker exec e-box cat /tmp/d)" "d"
expect_eq "exec -e -w -u" "$(docker exec -e FOO=bar -w /tmp -u nobody e-box sh -c 'echo $FOO $(pwd) $(id -un)')" "bar /tmp nobody"
docker exec e-box /nonexistent >/dev/null 2>&1
expect_eq "exec of a missing command exits 127" "$?" "127"
CP="$HOME_DIR/cp"
mkdir -p "$CP/in/sub"
echo hi >"$CP/in/a.txt"
echo deep >"$CP/in/sub/b.txt"
printf '#!/bin/sh\necho ran\n' >"$CP/in/x.sh"
chmod +x "$CP/in/x.sh"
docker cp e-box:/etc/alpine-release "$CP/rel" >/dev/null
check "cp copies a file out" test -s "$CP/rel"
docker cp e-box:/etc/apk "$CP/apk" >/dev/null
check "cp copies a directory out" test -d "$CP/apk/keys"
docker cp "$CP/in" e-box:/tmp/ >/dev/null
expect_eq "cp copies a tree in, keeping modes" "$(docker exec e-box /tmp/in/x.sh)" "ran"
expect_eq "copied files are owned by root" "$(docker exec e-box stat -c %U /tmp/in/sub/b.txt)" "root"
if docker cp e-box:/nope "$CP/n" >/dev/null 2>&1; then bad "cp of a missing path is refused"; else ok "cp of a missing path is refused"; fi
# A tar's top-level symlink to a host file arrives as a symlink, never as the host file.
echo "host-secret-$$" >"$CP/secret"
ln -s "$CP/secret" "$CP/leak"
tar -cf "$CP/leak.tar" -C "$CP" leak
docker cp - e-box:/tmp/ <"$CP/leak.tar" >/dev/null 2>&1
check "cp in keeps a symlink as a symlink" test "$(docker exec e-box readlink /tmp/leak)" = "$CP/secret"
if docker exec e-box cat /tmp/leak 2>/dev/null | grep -q "host-secret-$$"; then
    bad "cp in never copies a host file through a symlink"
else
    ok "cp in never copies a host file through a symlink"
fi
mkdir -p "$CP/tree"
ln -s /etc/os-release "$CP/tree/outer"
docker cp "$CP/tree" e-box:/tmp/ >/dev/null 2>&1
check "inner symlinks leaving the tree arrive as links" test "$(docker exec e-box readlink /tmp/tree/outer)" = "/etc/os-release"
code=$(curl -s -o /dev/null -w '%{http_code}' --unix-socket "$SOCK" "http://d/containers/e-box/archive?path=/tmp/..")
expect_eq "cp of a .. path is refused" "$code" "400"
docker run -d --name e-busy alpine sh -c 'while true; do :; done' >/dev/null
busy_cpu() { test "$(docker stats --no-stream --format '{{.CPUPerc}}' e-busy | tr -d '%' | cut -d. -f1)" -gt 50; }
eventually "stats shows a busy container's CPU" busy_cpu
expect_has_mem=$(docker stats --no-stream --format '{{.MemUsage}}' e-box)
check "stats shows memory usage and limit" grep -q 'GiB' <<<"$expect_has_mem"
docker rm -f e-box e-busy >/dev/null

docker run -d --name e-tick alpine sh -c 'for i in 1 2 3; do echo tick $i; sleep 1; done' >/dev/null
expect_eq "logs -f follows to the end" "$(docker logs -f e-tick | xargs)" "tick 1 tick 2 tick 3"
expect_eq "exit 0 recorded" "$(docker inspect e-tick --format '{{.State.Status}} {{.State.ExitCode}}')" "exited 0"

docker run -d --name e-clock alpine sh -c 'while true; do echo x; sleep 0.2; done' >/dev/null
sleep 1
docker pause e-clock >/dev/null
expect_eq "pause shows as Paused" "$(docker inspect e-clock --format '{{.State.Status}}')" "paused"
n1=$(docker logs e-clock | wc -l); sleep 1; n2=$(docker logs e-clock | wc -l)
expect_eq "a paused VM runs nothing" "$n1" "$n2"
docker unpause e-clock >/dev/null
sleep 1
check "unpause resumes" test "$(docker logs e-clock | wc -l)" -gt "$n2"
docker run -d --name e-sleep alpine sleep 300 >/dev/null
docker stop -t 1 e-sleep >/dev/null
expect_eq "stop escalates to SIGKILL after the grace period" "$(docker inspect e-sleep --format '{{.State.ExitCode}}')" "137"

# A daemon restart leaves containers running and loses no exit code.
docker run -d --name e-late alpine sh -c 'sleep 3; echo late; exit 42' >/dev/null
stop_daemon
sleep 5
start_daemon
expect_eq "container still runs after a daemon restart" "$(docker inspect e-clock --format '{{.State.Status}}')" "running"
expect_eq "exit code of a container that ended while the daemon was down" \
    "$(docker inspect e-late --format '{{.State.ExitCode}}')" "42"
expect_eq "its output was kept" "$(docker logs e-late)" "late"
docker stop -t 1 e-clock >/dev/null
check "a restarted daemon still controls it" test "$(docker inspect e-clock --format '{{.State.Running}}')" = false

# pratico-net (SPEC D-27): switch, addresses, gateway, DNS, isolation
docker run -d --name e-b1 alpine sleep 600 >/dev/null
docker run -d --name e-b2 alpine sleep 600 >/dev/null
b2=$(docker inspect e-b2 --format '{{.NetworkSettings.IPAddress}}')
check "bridge containers get 172.17.0.0/16 addresses" grep -q '^172\.17\.' <<<"$b2"
check "the gateway answers ping" docker exec e-b1 ping -c1 -W2 172.17.0.1
check "bridge containers reach each other" docker exec e-b1 ping -c1 -W2 "$b2"
if docker exec e-b1 nslookup e-b2 172.17.0.1 >/dev/null 2>&1; then bad "bare names do not resolve on bridge (Docker)"; else ok "bare names do not resolve on bridge (Docker)"; fi
check "<name>.pratico.internal resolves on bridge" docker exec e-b1 ping -c1 -W2 e-b2.pratico.internal
docker network create e-n1 >/dev/null
docker run -d --name e-c1 --network e-n1 alpine sleep 600 >/dev/null
docker run -d --name e-c2 --network e-n1 --network-alias db alpine sleep 600 >/dev/null
check "names resolve on a user network" docker exec e-c1 ping -c1 -W2 e-c2
check "aliases resolve on a user network" docker exec e-c1 ping -c1 -W2 db
if docker exec e-c1 ping -c1 -W2 "$b2" >/dev/null 2>&1; then bad "networks are isolated"; else ok "networks are isolated"; fi
eventually "external names resolve through the Mac" docker exec e-c1 nslookup example.com
expect_eq "host.docker.internal is the gateway" "$(docker exec e-c1 nslookup host.docker.internal 2>/dev/null | awk '/^Address/ {a=$2} END {print a}')" \
    "$(docker network inspect e-n1 --format '{{(index .IPAM.Config 0).Gateway}}')"
# The uplink: UDP, ping, TCP to the internet and to the Mac (host.docker.internal).
WWW="$HOME_DIR/www"
mkdir -p "$WWW"
echo hello-from-mac >"$WWW/index.html"
head -c 20000000 /dev/urandom >"$WWW/big.bin"
big_sum=$(shasum -a 256 "$WWW/big.bin" | cut -d' ' -f1)
WWW_PORT=18093
(cd "$WWW" && exec python3 -m http.server "$WWW_PORT" --bind 127.0.0.1 >/dev/null 2>&1) &
WWW_PID=$!
for _ in $(seq 50); do curl -s -m 1 "http://127.0.0.1:$WWW_PORT/" >/dev/null && break; sleep 0.1; done
eventually "UDP leaves the network (DNS to 1.1.1.1)" docker exec e-c1 nslookup example.com 1.1.1.1
eventually "ping leaves the network" docker exec e-c1 ping -c1 -W3 1.1.1.1
eventually "HTTPS to the internet" docker exec e-c1 wget -qO /dev/null -T10 https://example.com
expect_eq "host.docker.internal reaches the Mac" "$(docker exec e-c1 wget -qO- -T5 "http://host.docker.internal:$WWW_PORT/")" "hello-from-mac"
if docker exec e-c1 wget -qO- -T5 http://host.docker.internal:1 >/dev/null 2>&1; then bad "a closed port is refused"; else ok "a closed port is refused"; fi
expect_eq "20 MB download arrives intact" \
    "$(docker exec e-c1 sh -c "wget -qO /tmp/big.bin http://host.docker.internal:$WWW_PORT/big.bin && sha256sum /tmp/big.bin" | cut -d' ' -f1)" "$big_sum"
(nc -l 127.0.0.1 18094 >"$HOME_DIR/up.bin" &)
for _ in $(seq 50); do lsof -nP -iTCP:18094 -sTCP:LISTEN >/dev/null 2>&1 && break; sleep 0.1; done
docker exec e-c1 sh -c 'nc host.docker.internal 18094 < /tmp/big.bin'
for _ in $(seq 50); do [ "$(wc -c <"$HOME_DIR/up.bin" | tr -d ' ')" = 20000000 ] && break; sleep 0.1; done
expect_eq "20 MB upload arrives intact" "$(shasum -a 256 "$HOME_DIR/up.bin" | cut -d' ' -f1)" "$big_sum"
kill "$WWW_PID" 2>/dev/null

docker network create --internal e-int >/dev/null
# Compose puts a service on its networks by name; an internal one may sort first.
docker network create --internal a-int >/dev/null
docker create --name e-both --network a-int alpine sleep 600 >/dev/null
docker network connect e-n1 e-both
docker start e-both >/dev/null
eventually "on an internal and a normal network, the default route goes out the normal one" docker exec e-both ping -c1 -W3 1.1.1.1
docker rm -f e-both >/dev/null
docker network rm a-int >/dev/null
docker run -d --name e-i1 --network e-int alpine sleep 600 >/dev/null
docker run -d --name e-i2 --network e-int alpine sleep 600 >/dev/null
check "internal networks resolve their containers" docker exec e-i1 ping -c1 -W2 e-i2
if docker exec e-i1 nslookup example.com >/dev/null 2>&1; then bad "internal networks do no external DNS"; else ok "internal networks do no external DNS"; fi
if docker exec e-i1 ping -c1 -W2 1.1.1.1 >/dev/null 2>&1; then bad "internal networks do not reach the internet"; else ok "internal networks do not reach the internet"; fi
gw=$(docker network inspect e-int --format '{{(index .IPAM.Config 0).Gateway}}')
if docker exec e-i1 wget -qO- -T3 "http://$gw:18093/" >/dev/null 2>&1; then bad "internal networks do not reach the Mac"; else ok "internal networks do not reach the Mac"; fi
# Hot connect and disconnect (pratico-net 5): spare NIC slots, cut at the switch.
c2=$(docker inspect e-c2 --format '{{(index .NetworkSettings.Networks "e-n1").IPAddress}}')
check "connect a running container" docker network connect e-n1 e-b1
n1=$(docker inspect e-b1 --format '{{(index .NetworkSettings.Networks "e-n1").IPAddress}}')
eventually "a hot-connected container reaches the network by name" docker exec e-b1 ping -c1 -W2 e-c2
eventually "the network resolves a hot-connected container" docker exec e-c1 ping -c1 -W2 e-b1
check "disconnect a running container" docker network disconnect e-n1 e-b1
if docker exec e-b1 ping -c1 -W2 "$c2" >/dev/null 2>&1; then bad "disconnect cuts traffic"; else ok "disconnect cuts traffic"; fi
# The guest keeps the disconnected address (vminitd cannot delete it); the switch drops it.
if docker exec e-b1 ping -c1 -W2 -I "$n1" "$c2" >/dev/null 2>&1; then bad "the disconnected address is cut at the switch"; else ok "the disconnected address is cut at the switch"; fi
if docker exec e-c1 nslookup e-b1 >/dev/null 2>&1; then bad "a disconnected container leaves DNS"; else ok "a disconnected container leaves DNS"; fi
docker network connect e-n1 e-b1
expect_eq "reconnect gets the same address back" "$(docker inspect e-b1 --format '{{(index .NetworkSettings.Networks "e-n1").IPAddress}}')" "$n1"
check "disconnect the primary network" docker network disconnect bridge e-b1
eventually "DNS survives losing the primary network" docker exec e-b1 ping -c1 -W2 e-c2
eventually "the default route moves to the next network" docker exec e-b1 wget -qO /dev/null -T10 https://example.com
if docker exec e-b1 ping -c1 -W2 "$b2" >/dev/null 2>&1; then bad "the old primary network is cut"; else ok "the old primary network is cut"; fi
stop_daemon
start_daemon
eventually "hot-connected NICs survive a daemon restart" docker exec e-b1 ping -c1 -W2 e-c2

# Off every network, then on a new one: the default route and DNS follow (the guest's
# old address stays on the card, and the switch drops what it sends from it).
docker network create e-solo >/dev/null
docker run -d --name e-alone --network e-solo alpine sleep 300 >/dev/null
docker network disconnect e-solo e-alone
docker network connect e-n1 e-alone
eventually "DNS works after reconnecting from no network" docker exec e-alone nslookup e-c2
docker rm -f e-alone >/dev/null
docker network rm e-solo >/dev/null

# One card, an address per network (D-43): no limit of 4, and no spare cards to boot.
for i in 1 2 3 4 5; do docker network create "e-many$i" >/dev/null; done
docker run -d --name e-many --network e-many1 alpine sleep 300 >/dev/null
for i in 2 3 4 5; do docker network connect "e-many$i" e-many; done
docker run -d --name e-peer5 --network e-many5 alpine sleep 300 >/dev/null
expect_eq "a container on five networks has one card" "$(docker exec e-many sh -c 'ls /sys/class/net | grep -c ^eth')" "1"
eventually "and reaches the fifth network by name" docker exec e-many ping -c1 -W2 e-peer5
expect_eq "inspect lists all five networks" "$(docker inspect e-many --format '{{len .NetworkSettings.Networks}}')" "5"
# A MAC per network, as on Docker (D-44): the switch shows each network its own, and the
# guest's card keeps the first network's.
expect_eq "each network sees its own MAC" "$(docker inspect e-many --format '{{range .NetworkSettings.Networks}}{{.MacAddress}} {{end}}' | tr ' ' '\n' | grep . | sort -u | wc -l | tr -d ' ')" "5"
expect_eq "the card keeps the first network's MAC" "$(docker exec e-many cat /sys/class/net/eth0/address)" "$(docker inspect e-many --format '{{(index .NetworkSettings.Networks "e-many1").MacAddress}}')"
docker exec e-peer5 ping -c1 -W2 e-many >/dev/null 2>&1 || true
expect_has "a peer learns the network's MAC by ARP" "$(docker exec e-peer5 ip neigh)" "$(docker inspect e-many --format '{{(index .NetworkSettings.Networks "e-many5").MacAddress}}')"
if docker exec e-peer5 ping -c1 -W2 "$(docker inspect e-many --format '{{(index .NetworkSettings.Networks "e-many1").IPAddress}}')" >/dev/null 2>&1; then
    bad "a peer on one network cannot reach the container's address on another"
else
    ok "a peer on one network cannot reach the container's address on another"
fi
# A crafted frame, not routing: a raw frame to e-many's MAC at its e-many1 address, sent
# from e-many5. The switch must not deliver it (e-many's echo counter stays put); the
# same frame at its e-many5 address is the control.
docker pull -q python:3.13-slim >/dev/null
docker run -d --name e-raw --network e-many5 -v "$(cd "$(dirname "$0")" && pwd):/e2e:ro" python:3.13-slim sleep 300 >/dev/null
net() { docker inspect "$1" --format "{{(index .NetworkSettings.Networks \"$2\").$3}}"; }
echoes() { docker exec e-many awk '/^Icmp:/ && $3 ~ /^[0-9]+$/ {print $10}' /proc/net/snmp; }
raw() { docker exec e-raw python3 -I /e2e/frame.py "$(net e-many e-many5 MacAddress)" "$1" "$(net e-raw e-many5 IPAddress)"; sleep 0.5; }
before=$(echoes)
raw "$(net e-many e-many1 IPAddress)"
expect_eq "a raw frame to the container's MAC at another network's address is dropped" "$(echoes)" "$before"
raw "$(net e-many e-many5 IPAddress)"
expect_eq "and at its address on the shared network is delivered" "$(echoes)" "$((before + 3))"
docker rm -f e-raw >/dev/null
docker rm -f e-many e-peer5 >/dev/null
for i in 1 2 3 4 5; do docker network rm "e-many$i" >/dev/null; done

docker rm -f e-b1 e-b2 e-c1 e-c2 e-i1 e-i2 >/dev/null
check "network rm" docker network rm e-n1
docker network rm e-int >/dev/null

# Published ports (pratico-net 4c)
docker pull -q busybox >/dev/null 2>&1
docker run -d --name e-web -p 18210:80 busybox sh -c 'mkdir /w; echo published > /w/index.html; httpd -f -p 80 -h /w' >/dev/null
docker run -d --name e-web2 -p 80 busybox sh -c 'mkdir /w; echo random > /w/index.html; httpd -f -p 80 -h /w' >/dev/null
docker run -d --name e-udp -p 18211:9000/udp busybox sh -c 'nc -u -l -p 9000 -e cat' >/dev/null
docker run -d --name e-lo -p 127.0.0.1:18212:80 busybox sh -c 'mkdir /w; echo lo > /w/index.html; httpd -f -p 80 -h /w' >/dev/null
sleep 1
expect_eq "AC-13 -p host:container serves on the Mac" "$(curl -s -m5 http://127.0.0.1:18210/)" "published"
random=$(docker port e-web2 80/tcp | head -1)
expect_eq "-p container gets a free host port" "$(curl -s -m5 "http://$random/")" "random"
expect_has "a taken host port fails the start" "$(docker run -d --name e-clash -p 18210:80 busybox sleep 60 2>&1)" "port is already allocated"
expect_eq "UDP ports are published" "$(echo udp-echo | nc -u -w2 127.0.0.1 18211)" "udp-echo"
check "a host IP binds only that address" sh -c "lsof -nP -iTCP:18212 -sTCP:LISTEN | grep -q 127.0.0.1:18212"
leaked=0
for p in $(pgrep -f "pratico-shim $HOME_DIR"); do
    lsof -nP -a -p "$p" -iTCP -sTCP:LISTEN >/dev/null 2>&1 && leaked=1
done
expect_eq "shims inherit no daemon sockets" "$leaked" "0"
docker network create e-pn >/dev/null
docker run -d --name e-web3 -p 18213:80 busybox sh -c 'mkdir /w; echo follows > /w/index.html; httpd -f -p 80 -h /w' >/dev/null
docker network connect e-pn e-web3
docker network disconnect bridge e-web3
expect_eq "published ports follow the primary network" "$(curl -s -m5 http://127.0.0.1:18213/)" "follows"
docker rm -f e-web3 >/dev/null
docker network rm e-pn >/dev/null
stop_daemon
start_daemon
expect_eq "published ports survive a daemon restart" "$(curl -s -m5 http://127.0.0.1:18210/)" "published"
docker stop -t1 e-web >/dev/null
check "stopping a container releases its port" sh -c "! lsof -nP -iTCP:18210 -sTCP:LISTEN >/dev/null"
docker rm -f e-web e-web2 e-udp e-lo e-clash >/dev/null 2>&1

# SIGTERM to a shim (logout, shutdown) stops its container like `docker stop`.
docker run -d --name e-term alpine sh -c 'trap "exit 9" TERM; while true; do sleep 0.1; done' >/dev/null
sleep 1
pkill -TERM -f "pratico-shim $HOME_DIR/containers/$(docker inspect e-term --format '{{.Id}}')"
sleep 2
expect_eq "SIGTERM to the shim stops the container gracefully" "$(docker inspect e-term --format '{{.State.ExitCode}}')" "9"

docker rm -f e-tick e-clock e-sleep e-late e-term >/dev/null
expect_eq "rm removes rootfs and shim files" "$(ls "$HOME_DIR/containers" | wc -l | tr -d ' ')" "0"
check "tag" docker tag alpine pratico-e2e/emb:1
check "inspect by tag" test "$(docker image inspect pratico-e2e/emb:1 --format '{{.Os}}/{{.Architecture}}')" = "linux/arm64"
docker save -o "$HOME_DIR/save.tar" alpine 2>/dev/null
check "docker save writes a Docker archive" tar -xOf "$HOME_DIR/save.tar" manifest.json
docker rmi pratico-e2e/emb:1 >/dev/null
# Registries (SPEC D-29): logins in pratico's own Keychain items, plain HTTP for
# loopback as Docker, extra CAs from config.toml added to the system's roots, and every
# departure from verified HTTPS reported. Both registries run on pratico itself.
REG="127.0.0.1:15001"   # TLS, signed by a private CA
PLAIN="127.0.0.1:15002" # plain HTTP
REG_DIR="$HOME_DIR/registry"
REG_PASS="e2e-$(openssl rand -hex 8)"
mkdir -p "$REG_DIR"
# A CA and a leaf (macOS rejects a self-signed CA certificate as a TLS server's).
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=pratico e2e CA" \
    -keyout "$REG_DIR/ca.key" -out "$REG_DIR/ca.pem" >/dev/null 2>&1
openssl req -newkey rsa:2048 -nodes -subj /CN=localhost -keyout "$REG_DIR/key.pem" -out "$REG_DIR/leaf.csr" >/dev/null 2>&1
printf 'basicConstraints=CA:FALSE\nextendedKeyUsage=serverAuth\nsubjectAltName=IP:127.0.0.1,DNS:localhost\n' >"$REG_DIR/leaf.ext"
openssl x509 -req -in "$REG_DIR/leaf.csr" -CA "$REG_DIR/ca.pem" -CAkey "$REG_DIR/ca.key" -CAcreateserial -days 1 \
    -extfile "$REG_DIR/leaf.ext" -out "$REG_DIR/cert.pem" >/dev/null 2>&1
htpasswd -Bbn e2euser "$REG_PASS" >"$REG_DIR/htpasswd"
reg_cleanup() {
    for r in "$REG" "$PLAIN"; do security delete-internet-password -s "$r" -d dev.pratico.registry >/dev/null 2>&1; done
    cleanup
}
trap reg_cleanup EXIT
wait_401() { for _ in $(seq 100); do [ "$(curl -sk -o /dev/null -w '%{http_code}' "$1/v2/")" = 401 ] && return; sleep 0.2; done; }
api() { curl -s --unix-socket "$SOCK" "$@"; }

printf 'registry_ca = ["%s"]\n' "$REG_DIR/ca.pem" >"$HOME_DIR/config.toml"
stop_daemon
start_daemon
expect_has "docker info names the extra CA" "$(docker info 2>&1)" 'extra CA, "pratico e2e CA"'
expect_has "docker info lists loopback as insecure" "$(docker info 2>&1)" "127.0.0.0/8"
check "an extra CA leaves the system's roots in place (Docker Hub verifies)" docker pull -q registry:2
docker run -d --name e-reg -p "$REG:5000" -v "$REG_DIR:/auth" \
    -e REGISTRY_AUTH=htpasswd -e REGISTRY_AUTH_HTPASSWD_REALM=e2e -e REGISTRY_AUTH_HTPASSWD_PATH=/auth/htpasswd \
    -e REGISTRY_HTTP_TLS_CERTIFICATE=/auth/cert.pem -e REGISTRY_HTTP_TLS_KEY=/auth/key.pem registry:2 >/dev/null 2>&1
docker run -d --name e-plain -p "$PLAIN:5000" -v "$REG_DIR:/auth" \
    -e REGISTRY_AUTH=htpasswd -e REGISTRY_AUTH_HTPASSWD_REALM=e2e -e REGISTRY_AUTH_HTPASSWD_PATH=/auth/htpasswd registry:2 >/dev/null 2>&1
wait_401 "https://$REG"
wait_401 "http://$PLAIN"

docker tag alpine "$REG/e2e/alpine:1"
if docker push "$REG/e2e/alpine:1" >/dev/null 2>&1; then bad "push without login is refused"; else ok "push without login is refused"; fi
expect_has "docker login with a wrong password fails" "$(echo wrong | docker login "$REG" -u e2euser --password-stdin 2>&1)" \
    "incorrect username or password"
expect_has "docker login succeeds" "$(echo "$REG_PASS" | docker login "$REG" -u e2euser --password-stdin 2>&1)" "Login Succeeded"
expect_has "push says which extra CA vouched for the registry" "$(docker push "$REG/e2e/alpine:1" 2>&1)" \
    'trusted through an extra CA, "pratico e2e CA"'
docker rmi "$REG/e2e/alpine:1" >/dev/null
check "pull from a private registry" docker pull "$REG/e2e/alpine:1"
docker rmi "$REG/e2e/alpine:1" >/dev/null
# No X-Registry-Auth: the daemon uses the login it kept.
expect_has "a kept login serves clients that send no credentials" \
    "$(api -X POST "http://d/images/create?fromImage=$REG/e2e/alpine&tag=1")" "Downloaded newer image"
docker rmi "$REG/e2e/alpine:1" >/dev/null

# Plain HTTP with credentials on loopback, as Docker allows, and said so.
expect_has "docker login to a plain-HTTP loopback registry" \
    "$(echo "$REG_PASS" | docker login "$PLAIN" -u e2euser --password-stdin 2>&1)" "Login Succeeded"
docker tag alpine "$PLAIN/e2e/alpine:1"
expect_has "push over plain HTTP says it is not encrypted" "$(docker push "$PLAIN/e2e/alpine:1" 2>&1)" "not encrypted"
docker rmi "$PLAIN/e2e/alpine:1" >/dev/null
check "pull over plain HTTP" docker pull "$PLAIN/e2e/alpine:1"
docker rmi "$PLAIN/e2e/alpine:1" >/dev/null

state=$(cat "$HOME_DIR/registries.json")
expect_has "registries.json lists the kept logins" "$state" "\"server\":\"$PLAIN\""
if grep -qF "$REG_PASS" <<<"$state"; then bad "registries.json holds no password"; else ok "registries.json holds no password"; fi
expect_eq "a kept login can be removed" "$(api -o /dev/null -w '%{http_code}' -X DELETE "http://d/pratico/registries/logins/$REG")" "204"
expect_has "a removed login no longer serves" "$(api -X POST "http://d/images/create?fromImage=$REG/e2e/alpine&tag=1")" "requires a login"

# Locked down: no plain HTTP, even on loopback.
printf 'registry_ca = ["%s"]\nregistry_http_loopback = false\n' "$REG_DIR/ca.pem" >"$HOME_DIR/config.toml"
stop_daemon
start_daemon
if echo "$REG_PASS" | docker login "$PLAIN" -u e2euser --password-stdin >/dev/null 2>&1; then
    bad "registry_http_loopback = false refuses plain HTTP"
else ok "registry_http_loopback = false refuses plain HTTP"; fi
printf 'registry_ca = ["/nonexistent/ca.pem"]\n' >"$HOME_DIR/config.toml"
stop_daemon
"$BIN/pratico-daemon" --home "$HOME_DIR" >/dev/null 2>&1
expect_eq "an unreadable registry_ca stops the daemon (exit 4)" "$?" "4"
rm -f "$HOME_DIR/config.toml"
start_daemon
docker rm -f e-reg e-plain >/dev/null
docker rmi registry:2 >/dev/null 2>&1

# Docker-in-Docker clients (Compose in a container, Testcontainers) mount the daemon socket.
docker pull -q docker:cli >/dev/null 2>&1
out=$(docker run --rm -v /var/run/docker.sock:/var/run/docker.sock docker:cli docker version --format '{{.Server.Os}}' 2>&1)
expect_eq "-v /var/run/docker.sock reaches pratico" "$out" "linux"
out=$(docker run --rm --mount "type=bind,source=$SOCK,target=/run/d.sock" docker:cli docker -H unix:///run/d.sock ps --format '{{.Image}}' 2>&1)
expect_eq "any host Unix socket can be mounted" "$out" "docker:cli"

# Disk use and cleanup: running containers and the images they use are kept.
docker pull -q busybox >/dev/null 2>&1
docker run -d --name d-keep alpine sleep 300 >/dev/null
docker run --name d-gone alpine sh -c 'head -c 5000000 /dev/urandom >/big' >/dev/null
disk=$(curl -s --unix-socket "$SOCK" http://d/pratico/disk)
check "disk use counts a stopped container's written data" python3 -c "import json,sys; d=json.loads(sys.argv[1]); assert d['Containers']['Stopped'] >= 5000000 and d['Images']['Unused'] > 0 and d['Total'] > 0" "$disk"
check "cleanup plans: both covers the stopped container and every unused image" python3 -c "import json,sys; c=json.loads(sys.argv[1])['Cleanup']; n=lambda p,k: {i['Name'] for i in p[k]}; assert 'd-gone' in n(c['Both'],'Containers') and n(c['Images'],'Images') <= n(c['Both'],'Images') and 'busybox:latest' in n(c['Images'],'Images') and c['Both']['Bytes'] >= c['Images']['Bytes'] > 0 and c['Containers']['Bytes'] >= 5000000" "$disk"
check "disk use slices add up to the total" python3 -c "import json,sys; d=json.loads(sys.argv[1]); i,c=d['Images'],d['Containers']; assert d['Total'] == i['Size']+i['Unpacked']+c['Running']+c['Stopped']+c['Logs']+d['Volumes']['Size']+d['Runtime']+d['Scans']" "$disk"
df=$(docker system df --format '{{.Type}} {{.TotalCount}} {{.Active}}' 2>&1)
expect_has "docker system df counts images" "$df" "Images $(docker images -q | sort -u | wc -l | tr -d ' ') 1"
expect_has "docker system df counts containers" "$df" "Containers 2 1"
docker create --name d-labeled -l keep=1 alpine true >/dev/null
docker container prune -f --filter 'label!=keep' >/dev/null 2>&1
check "container prune --filter label! keeps the labeled one" docker inspect d-labeled
docker container prune -f --filter until=1h >/dev/null 2>&1
check "container prune --filter until=1h keeps recent ones" docker inspect d-labeled
expect_has "an unknown prune filter is refused" "$(docker container prune -f --filter status=exited 2>&1)" "invalid filter"
docker rm d-labeled >/dev/null
docker container prune -f >/dev/null 2>&1
check "container prune removes stopped containers" sh -c "! docker inspect d-gone >/dev/null 2>&1"
check "container prune keeps running ones" docker inspect d-keep
docker image prune -a -f >/dev/null 2>&1
check "image prune -a removes unused images" sh -c "! docker image inspect busybox >/dev/null 2>&1"
check "image prune -a keeps images in use" docker image inspect alpine
check "docker system prune finishes" docker system prune -f
docker rm -f d-keep >/dev/null

# docker cp with stopped containers: the rootfs is read or rewritten on the Mac.
CPS="$HOME_DIR/cps"; mkdir -p "$CPS/conf.d"
echo hello-from-cp >"$CPS/greeting"; echo nested >"$CPS/conf.d/a.conf"
docker create --name e2e-cps alpine sh -c 'stat -c "%u %a" /etc/greeting; cat /etc/greeting /etc/conf.d/a.conf' >/dev/null
check "cp into a created container" docker cp "$CPS/greeting" e2e-cps:/etc/
check "cp a directory into a created container" docker cp "$CPS/conf.d" e2e-cps:/etc/
expect_eq "it starts with the files, owned by root" "$(docker start -a e2e-cps | tr '\n' ' ')" "0 644 hello-from-cp nested "
docker run --name e2e-cpo alpine sh -c 'echo made-inside > /out.txt' >/dev/null
check "cp out of an exited container" docker cp e2e-cpo:/out.txt "$CPS/out.txt"
expect_eq "with its contents" "$(cat "$CPS/out.txt")" "made-inside"
check "cp a directory out of an exited container" docker cp e2e-cpo:/etc/apk "$CPS/apk"
check "with what is inside it" test -s "$CPS/apk/repositories"
docker cp e2e-cpo:/bin/ls "$CPS/ls" >/dev/null 2>&1
expect_eq "a symlink comes out as a link" "$(readlink "$CPS/ls")" "/bin/busybox"
expect_has "a missing path is a 404" "$(docker cp e2e-cpo:/nope "$CPS/nope" 2>&1)" "Could not find the file /nope"
check "the exited container still starts" docker start e2e-cpo
docker rm -f e2e-cps e2e-cpo >/dev/null

# Each image is unpacked once; containers get clones that share it until they write.
docker run --rm alpine true
t0=$(python3 -c 'import time; print(time.time())')
docker create --name e2e-clone1 alpine sh -c 'echo one > /mine; cat /mine' >/dev/null
docker create --name e2e-clone2 alpine sh -c 'cat /mine 2>/dev/null || echo clean' >/dev/null
check "a create after the first is fast (a clone, not an unpack)" python3 -c "import sys,time; assert time.time() - float(sys.argv[1]) < 2" "$t0"
expect_eq "a write in one clone" "$(docker start -a e2e-clone1)" "one"
expect_eq "does not reach the other" "$(docker start -a e2e-clone2)" "clean"
check "the unpacked image is cached once" test "$(ls "$HOME_DIR/store/rootfs-cache" | grep -c 'ext4$')" -ge 1
docker rm e2e-clone1 e2e-clone2 >/dev/null

# tmpfs: memory in the VM, Docker's default options, sizes enforced.
expect_has "--tmpfs mounts a tmpfs with Docker's defaults" "$(docker run --rm --tmpfs /scratch alpine sh -c 'grep " /scratch " /proc/mounts')" "tmpfs /scratch tmpfs rw,nosuid,nodev,noexec"
expect_has "--tmpfs size is enforced" "$(docker run --rm --tmpfs /scratch:size=1m alpine sh -c 'head -c 2000000 /dev/zero >/scratch/f; echo rc=$?' 2>&1)" "rc=1"
expect_has "--mount type=tmpfs takes size and mode" "$(docker run --rm --mount type=tmpfs,dst=/t,tmpfs-size=1048576,tmpfs-mode=1777 alpine sh -c 'grep " /t " /proc/mounts; stat -c %a /t')" "1777"
expect_eq "inspect reports a tmpfs mount" "$(docker run -d --name e2e-tmp --tmpfs /run/x alpine sleep 30 >/dev/null; docker inspect e2e-tmp --format '{{range .Mounts}}{{.Type}} {{.Destination}}{{end}}')" "tmpfs /run/x"
docker rm -f e2e-tmp >/dev/null

# Compose: a project with a private network, an internal one, and a service on both.
COMPOSE="${COMPOSE:-/opt/homebrew/bin/docker-compose}"
if [ -x "$COMPOSE" ]; then
    PROJ="$HOME_DIR/proj"; mkdir -p "$PROJ"
    cat >"$PROJ/compose.yaml" <<'YAML'
services:
  web: {image: alpine, command: sleep 300, networks: [front, back]}
  api: {image: alpine, command: sleep 300, networks: [back]}
networks:
  front: {}
  back: {internal: true}
YAML
    check "compose up" "$COMPOSE" -f "$PROJ/compose.yaml" -p e2e up -d
    eventually "compose services reach each other by name on a private network" "$COMPOSE" -f "$PROJ/compose.yaml" -p e2e exec -T api ping -c1 -W2 web
    eventually "a service on a normal and an internal network reaches out" "$COMPOSE" -f "$PROJ/compose.yaml" -p e2e exec -T web ping -c1 -W3 1.1.1.1
    if "$COMPOSE" -f "$PROJ/compose.yaml" -p e2e exec -T api ping -c1 -W2 1.1.1.1 >/dev/null 2>&1; then bad "an internal-only service stays in"; else ok "an internal-only service stays in"; fi
    expect_eq "compose exec lands in the service it names" "$("$COMPOSE" -f "$PROJ/compose.yaml" -p e2e exec -T api hostname)" "$(docker inspect e2e-api-1 --format '{{.Config.Hostname}}')"
    check "compose down removes the project" "$COMPOSE" -f "$PROJ/compose.yaml" -p e2e down
    expect_eq "and its networks" "$(docker network ls --format '{{.Name}}' | grep -c '^e2e_')" "0"
else
    echo "skip compose checks: no $COMPOSE (brew install docker-compose)"
fi

# Apple's container tool: OCI archives move both ways (only where it is installed).
if command -v container >/dev/null && container system status >/dev/null 2>&1; then
    docker tag alpine pratico-e2e/interop:1
    docker save pratico-e2e/interop:1 -o "$HOME_DIR/interop.tar"
    check "container image load reads pratico's docker save" container image load -i "$HOME_DIR/interop.tar"
    expect_eq "and container runs it" "$(container run --rm pratico-e2e/interop:1 echo apple-ok 2>/dev/null | tail -1)" "apple-ok"
    container image save pratico-e2e/interop:1 -o "$HOME_DIR/from-apple.tar"
    docker rmi pratico-e2e/interop:1 >/dev/null
    check "docker load reads container image save" docker load -i "$HOME_DIR/from-apple.tar"
    container image delete pratico-e2e/interop:1 >/dev/null 2>&1
    docker rmi pratico-e2e/interop:1 >/dev/null 2>&1
else
    echo "skip Apple container checks: container not installed or not running"
fi

# AC-28, FR-25: named and anonymous volumes.
since=$(date +%s)
check "AC-28 docker volume create" docker volume create e2e-v
docker run --rm -v e2e-v:/v alpine sh -c 'echo shared >/v/f' >/dev/null
expect_eq "AC-28 a second container reads what the first wrote" "$(docker run --rm --mount type=volume,src=e2e-v,dst=/w alpine cat /w/f 2>&1)" "shared"
expect_has "docker volume ls lists it" "$(docker volume ls --format '{{.Name}} {{.Driver}}')" "e2e-v local"
expect_eq "inspect gives its host directory" "$(docker volume inspect e2e-v --format '{{.Mountpoint}}')" "$HOME_DIR/volumes/e2e-v/_data"
docker run -d --name e2e-vuser -v e2e-v:/v alpine sleep 300 >/dev/null
expect_eq "inspect reports a volume mount" "$(docker inspect e2e-vuser --format '{{range .Mounts}}{{.Type}} {{.Name}} {{.Destination}}{{end}}')" "volume e2e-v /v"
expect_has "a volume in use is not removed" "$(docker volume rm e2e-v 2>&1)" "volume is in use"
docker rm -f e2e-vuser >/dev/null
expect_has "copy-up: a new volume starts with the image's files" "$(docker run --rm -v e2e-cu:/etc alpine cat /etc/os-release)" "Alpine Linux"
expect_eq "copy-up keeps symlinks and the exec bit" "$(docker run --rm -v e2e-cubin:/bin alpine /bin/sh -c 'readlink /bin/ls; test -x /bin/busybox && echo exec' | tr '\n' ' ')" "/bin/busybox exec "
expect_eq "nocopy starts empty" "$(docker run --rm -v e2e-nocp:/lib/apk/db:nocopy alpine ls -A /lib/apk/db | wc -l | tr -d ' ')" "0"
docker run --rm -v e2e-cu:/etc alpine rm /etc/motd
expect_eq "a volume with files is not copied into again" "$(docker run --rm -v e2e-cu:/etc alpine sh -c 'test -e /etc/motd && echo back || echo gone')" "gone"
docker volume rm e2e-cu e2e-cubin e2e-nocp >/dev/null
check "run -v name:/path creates a missing volume" docker run --rm -v e2e-auto:/a alpine true
check "and keeps it after --rm (named volumes stay)" docker volume inspect e2e-auto
before=$(docker volume ls -q | wc -l | tr -d ' ')
docker run --rm -v /scratch alpine sh -c 'echo x >/scratch/x' >/dev/null
expect_eq "--rm removes the anonymous volume it made" "$(docker volume ls -q | wc -l | tr -d ' ')" "$before"
docker run --name e2e-anon -v /scratch alpine true >/dev/null
anon=$(docker inspect e2e-anon --format '{{range .Mounts}}{{.Name}}{{end}}')
expect_eq "a bare -v /path gets an anonymous volume" "$(docker volume inspect "$anon" --format '{{index .Labels "com.docker.volume.anonymous"}}|{{.Name}}')" "|$anon"
docker rm -v e2e-anon >/dev/null
check "docker rm -v removes it" sh -c "! docker volume inspect $anon >/dev/null 2>&1"
docker pull -q registry:2 >/dev/null 2>&1
docker create --name e2e-imgvol registry:2 >/dev/null
expect_has "an image VOLUME gets an anonymous volume" "$(docker inspect e2e-imgvol --format '{{range .Mounts}}{{.Type}} {{.Destination}} {{end}}')" "volume /var/lib/registry"
docker rm -v e2e-imgvol >/dev/null
expect_has "system df counts volumes" "$(docker system df --format '{{.Type}} {{.TotalCount}}')" "Local Volumes $(docker volume ls -q | wc -l | tr -d ' ')"
disk=$(curl -s --unix-socket "$SOCK" http://d/pratico/disk)
check "the volume cleanup plan lists unused volumes, named too" python3 -c "import json,sys; p=json.loads(sys.argv[1])['Cleanup']['Volumes']; n={v['Name'] for v in p['Volumes']}; assert {'e2e-v','e2e-auto'} <= n and not p['Images'] and not p['Containers']" "$disk"
docker volume create --label keep=1 e2e-keep >/dev/null
docker run --name e2e-anon2 -v /scratch alpine true >/dev/null
anon=$(docker inspect e2e-anon2 --format '{{range .Mounts}}{{.Name}}{{end}}')
docker rm e2e-anon2 >/dev/null
docker volume prune -f >/dev/null
check "volume prune removes unused anonymous volumes" sh -c "! docker volume inspect $anon >/dev/null 2>&1"
check "and keeps named ones" docker volume inspect e2e-keep
docker volume prune -a -f --filter label=keep=1 >/dev/null
check "volume prune -a with a label removes the named volumes it matches" sh -c "! docker volume inspect e2e-keep >/dev/null 2>&1"
check "AC-28 docker volume rm succeeds once no container uses it" docker volume rm e2e-v e2e-auto
vev=$(docker events --since "$since" --until "$(($(date +%s) + 1))" --filter type=volume --format '{{.Action}} {{.Actor.ID}}' | tr '\n' ' ')
expect_has "volume create is an event" "$vev" "create e2e-v "
expect_has "volume destroy is an event" "$vev" "destroy e2e-v "
expect_has "a bad volume name is refused" "$(docker volume create 'bad/name' 2>&1)" "invalid characters"
docker rmi registry:2 >/dev/null 2>&1

# AC-38, AC-39: snapshot and restore.
docker network create e2e-snet >/dev/null
docker volume create --label k=v e2e-svol >/dev/null
docker create --name e2e-s1 --network e2e-snet --network-alias api -v e2e-svol:/data -l role=api -p 127.0.0.1:18300:80 alpine sleep 300 >/dev/null
docker run -d --name e2e-s2 -e MODE=x alpine sleep 300 >/dev/null
snap=$(curl -s -X POST --unix-socket "$SOCK" http://d/pratico/snapshots | python3 -c 'import json,sys; print(json.load(sys.stdin)["Path"])')
expect_has "FR-35 the snapshot lands in ~/.pratico/snapshots with its timestamped name" "$snap" "$HOME_DIR/snapshots/pratico-snapshot-"
listing=$(python3 -I -c 'import sys,tarfile; print(" ".join(sorted(m.name for m in tarfile.open(sys.argv[1]) if m.isfile())))' "$snap")
expect_has "AC-38.a it holds manifest.json" "$listing" "manifest.json"
expect_has "AC-38.a and one JSON file per container, network, and volume" "$listing" "containers/e2e-s1.json containers/e2e-s2.json manifest.json networks/e2e-snet.json volumes/e2e-svol.json"
docker rm -f e2e-s1 e2e-s2 >/dev/null
docker network rm e2e-snet >/dev/null
docker volume rm e2e-svol >/dev/null
q=$(python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$snap")
dry=$(curl -s -X POST --unix-socket "$SOCK" "http://d/pratico/snapshots/restore?path=$q&dry_run=1")
check "a dry run lists what it would create and changes nothing" sh -c "echo '$dry' | grep -q e2e-s1 && ! docker inspect e2e-s1 >/dev/null 2>&1"
check "the dry run reviews each container: image and published ports" python3 -c "import json,sys; r={c['Name']: c for c in json.loads(sys.argv[1])['Review']}; assert r['e2e-s1']['Image']=='alpine' and any('127.0.0.1:18300' in x for x in r['e2e-s1']['Risks']) and any('volume e2e-svol at /data (a new, empty volume' in x for x in r['e2e-s1']['Risks']) and r['e2e-s2']['Running']" "$dry"
report=$(curl -s -X POST --unix-socket "$SOCK" "http://d/pratico/snapshots/restore?path=$q&start=1")
check "AC-38 restore reports everything created and the running one started" python3 -c "import json,sys; r=json.loads(sys.argv[1]); c=r['Created']; assert c['Containers']==['e2e-s1','e2e-s2'] or sorted(c['Containers'])==['e2e-s1','e2e-s2']; assert c['Networks']==['e2e-snet'] and c['Volumes']==['e2e-svol'] and r['Started']==['e2e-s2'] and not r['Failed']" "$report"
expect_has "AC-38 docker ps -a shows them again" "$(docker ps -a --format '{{.Names}} {{.State}}' | sort | tr '\n' ' ')" "e2e-s1 created e2e-s2 running"
expect_has "AC-38 docker network ls shows the network" "$(docker network ls --format '{{.Name}}')" "e2e-snet"
expect_eq "AC-38 docker volume ls shows the volume, labels kept" "$(docker volume inspect e2e-svol --format '{{.Labels.k}}')" "v"
expect_eq "restored settings: label, env, port, network alias, volume" \
    "$(docker inspect e2e-s1 --format '{{index .Config.Labels "role"}} {{(index (index .HostConfig.PortBindings "80/tcp") 0).HostPort}} {{range .Mounts}}{{.Name}}{{end}} {{index .NetworkSettings.Networks "e2e-snet" | printf "%v" | len | lt 0}}') $(docker inspect e2e-s2 --format '{{range .Config.Env}}{{.}} {{end}}' | grep -o MODE=x)" \
    "api 18300 e2e-svol true MODE=x"
docker rm -f e2e-s2 >/dev/null
docker run -d --name e2e-s2 alpine sleep 300 >/dev/null
mine=$(docker inspect e2e-s2 --format '{{.Id}}')
report=$(curl -s -X POST --unix-socket "$SOCK" "http://d/pratico/snapshots/restore?path=$q")
check "AC-39 an existing name is skipped and named in the report" python3 -c "import json,sys; r=json.loads(sys.argv[1]); assert {'Kind':'container','Name':'e2e-s2','Reason':'a container with this name exists'} in r['Skipped'] and not r['Created']['Containers']" "$report"
expect_eq "AC-39 and the existing one is unchanged" "$(docker inspect e2e-s2 --format '{{.Id}}')" "$mine"
bad999="$HOME_DIR/bad-snapshot.tar.gz"
python3 -I - "$bad999" <<'PY'
import io, json, sys, tarfile
with tarfile.open(sys.argv[1], "w:gz") as t:
    for name, body in [("manifest.json", {"format_version": 999, "containers": ["e2e-new"]}),
                       ("containers/e2e-new.json", {"Name": "e2e-new", "Create": {"Image": "alpine"}})]:
        data = json.dumps(body).encode()
        info = tarfile.TarInfo(name); info.size = len(data)
        t.addfile(info, io.BytesIO(data))
PY
before=$(docker ps -aq | sort | tr '\n' ' ')
q=$(python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$bad999")
expect_has "AC-39.a an unsupported format_version is refused, naming it" "$(curl -s -X POST --unix-socket "$SOCK" "http://d/pratico/snapshots/restore?path=$q")" "format_version 999 is not supported"
expect_eq "AC-39.a and docker ps -a is unchanged" "$(docker ps -aq | sort | tr '\n' ' ')" "$before"
bomb="$HOME_DIR/bomb-snapshot.tar.gz"
python3 -I - "$bomb" <<'PY'
import io, sys, tarfile
with tarfile.open(sys.argv[1], "w:gz") as t:
    data = b"0" * (8 << 20)  # compresses to a few KiB, unpacks past the 1 MiB member cap
    info = tarfile.TarInfo("containers/x.json"); info.size = len(data)
    t.addfile(info, io.BytesIO(data))
PY
q=$(python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$bomb")
expect_has "a member past its cap is refused unpacked size, not file size" "$(curl -s -X POST --unix-socket "$SOCK" "http://d/pratico/snapshots/restore?path=$q")" "larger than 1024 KiB"
crafted="$HOME_DIR/crafted-snapshot.tar.gz"
python3 -I - "$crafted" <<'PY'
import io, json, sys, tarfile
host = {"Binds": ["/data", "/tmp/../etc:/x:ro"], "PortBindings": {}}
with tarfile.open(sys.argv[1], "w:gz") as t:
    for name, body in [("manifest.json", {"format_version": 1, "containers": ["e2e-crafted"]}),
                       ("containers/e2e-crafted.json", {"Name": "e2e-crafted", "Create": {"Image": "alpine", "HostConfig": host}})]:
        data = json.dumps(body).encode()
        info = tarfile.TarInfo(name); info.size = len(data)
        t.addfile(info, io.BytesIO(data))
PY
q=$(python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$crafted")
dry=$(curl -s -X POST --unix-socket "$SOCK" "http://d/pratico/snapshots/restore?path=$q&dry_run=1")
risks=$(python3 -c "import json,sys; print(' | '.join(json.loads(sys.argv[1])['Review'][0]['Risks']))" "$dry")
expect_has "the review resolves a Mac folder path" "$risks" "the Mac folder /etc at /x (read-only)"
expect_has "and sees the volume create makes for a bare -v" "$risks" "at /data (a new, empty volume"
docker rm -f e2e-s1 e2e-s2 >/dev/null
docker network rm e2e-snet >/dev/null
docker volume rm e2e-svol >/dev/null

# D-45: every option accepted is applied in the guest; the rest are refused.
run() { docker run --rm "$@" 2>&1; }
expect_eq "--cpus 0.5 is a CFS quota of half a CPU" "$(run --cpus 0.5 alpine cat /sys/fs/cgroup/cpu.max)" "50000 100000"
expect_eq "--cpus 2 sizes the VM" "$(run --cpus 2 alpine nproc)" "2"
expect_eq "--cpuset-cpus pins" "$(run --cpuset-cpus 1 alpine cat /sys/fs/cgroup/cpuset.cpus.effective)" "1"
expect_eq "--cpu-shares is a cgroup weight" "$(run --cpu-shares 512 alpine cat /sys/fs/cgroup/cpu.weight)" "20"
expect_eq "--pids-limit" "$(run --pids-limit 32 alpine cat /sys/fs/cgroup/pids.max)" "32"
expect_eq "--memory, --memory-reservation, --memory-swap" "$(run -m 256m --memory-reservation 128m --memory-swap 512m alpine cat /sys/fs/cgroup/memory.max /sys/fs/cgroup/memory.low /sys/fs/cgroup/memory.swap.max | tr '\n' ' ')" "268435456 134217728 268435456 "
expect_eq "Docker's default capabilities" "$(run alpine awk '/CapEff/ {print $2}' /proc/self/status)" "00000000a80425fb"
check "--cap-add NET_ADMIN" docker run --rm --cap-add NET_ADMIN alpine ip route add 10.9.9.9/32 dev eth0
expect_eq "--cap-drop ALL" "$(run --cap-drop ALL alpine awk '/CapEff/ {print $2}' /proc/self/status)" "0000000000000000"
expect_eq "--privileged" "$(run --privileged alpine awk '/CapEff/ {print $2}' /proc/self/status)" "000001ffffffffff"
expect_has "--read-only" "$(run --read-only alpine touch /x)" "Read-only file system"
expect_eq "--sysctl" "$(run --sysctl net.ipv4.ip_forward=1 alpine cat /proc/sys/net/ipv4/ip_forward)" "1"
expect_eq "--ulimit" "$(run --ulimit nofile=1024:2048 alpine sh -c 'ulimit -n; ulimit -Hn' | tr '\n' ' ')" "1024 2048 "
expect_has "--shm-size" "$(run --shm-size 128m alpine grep /dev/shm /proc/mounts)" "size=131072k"
expect_has "--group-add by name and number" "$(run --group-add 123 --group-add wheel alpine id)" "groups=0(root),10(wheel),123"
expect_eq "--user name:group" "$(run --user nobody:nobody alpine id -u -n)" "nobody"
expect_eq "--hostname and --domainname" "$(run --hostname myhost --domainname example.com alpine sh -c 'hostname; cat /proc/sys/kernel/domainname' | tr '\n' ' ')" "myhost example.com "
expect_has "--dns, --dns-search, --dns-option" "$(run --dns 1.1.1.1 --dns-search corp --dns-option ndots:2 alpine cat /etc/resolv.conf | tr '\n' ' ')" "nameserver 1.1.1.1 search corp options ndots:2"
expect_has "--add-host, with host-gateway" "$(run --add-host foo:10.1.2.3 --add-host bar:host-gateway alpine cat /etc/hosts | tr '\n' ' ')" "10.1.2.3 foo 172.17.0.1 bar"
expect_eq "--init runs an init as PID 1" "$(run --init alpine cat /proc/1/comm | grep -c '^cat$')" "0"
expect_has "--security-opt no-new-privileges" "$(run --security-opt no-new-privileges alpine grep NoNewPrivs /proc/self/status)" "1"
expect_has "--device is refused" "$(run --device /dev/null alpine true)" "pratico: --device is not supported"
expect_has "--pid host is refused" "$(run --pid host alpine true)" "pratico: --pid=host is not supported"
docker run -d --name e-caps --cap-drop ALL alpine sleep 300 >/dev/null
expect_eq "an exec keeps the container's capabilities" "$(docker exec e-caps awk '/CapEff/ {print $2}' /proc/self/status)" "0000000000000000"
expect_eq "exec --privileged has every one" "$(docker exec --privileged e-caps awk '/CapEff/ {print $2}' /proc/self/status)" "000001ffffffffff"
docker rm -f e-caps >/dev/null
docker run -d --name e-logs alpine sh -c 'echo early; sleep 2; echo late; sleep 300' >/dev/null
sleep 3
cut=$(python3 -c 'import time; print(f"{time.time() - 1.5:.3f}")')
expect_eq "logs --since" "$(docker logs --since "$cut" e-logs)" "late"
expect_eq "logs --until" "$(docker logs --until "$cut" e-logs)" "early"
expect_eq "logs -f --until ends at until" "$(docker logs -f --until "$cut" e-logs)" "early"
docker exec e-logs sh -c 'head -c 1048576 /dev/urandom > /blob && sync'
rw=$(docker ps --size --filter name=e-logs --format '{{.Size}}')
expect_has "ps --size counts what the container wrote" "$rw" "virtual"
expect_eq "inspect --size counts the MiB it wrote" "$(docker inspect --size e-logs --format '{{.SizeRw}}' | awk '{print ($1 > 1000000)}')" "1"
docker rm -f e-logs >/dev/null
# rename, top, diff, export, history, update.
docker run -d --name e-ops alpine sh -c 'echo hi > /added; rm /etc/motd; sleep 300' >/dev/null
sleep 1
check "rename" docker rename e-ops e-ops2
expect_eq "and the new name answers" "$(docker inspect e-ops2 --format '{{.Name}}')" "/e-ops2"
expect_has "top lists the container's processes" "$(docker top e-ops2)" "sleep 300"
expect_eq "and not the ps that answered" "$(curl -s --unix-socket "$SOCK" http://d/containers/e-ops2/top | python3 -c 'import json,sys; print([r[-1] for r in json.load(sys.stdin)["Processes"]])')" "['sleep 300']"
expect_eq "diff shows what changed, not pratico's own files" "$(docker diff e-ops2 | tr '\n' ' ')" "A /added C /etc D /etc/motd "
expect_eq "export of a running container" "$(docker export e-ops2 | tar -xOf - added)" "hi"
expect_eq "and it keeps running, unpaused" "$(docker inspect e-ops2 --format '{{.State.Status}} {{.State.Paused}}')" "running false"
expect_has "image history" "$(docker history alpine)" "CMD [\"/bin/sh\"]"
check "update --restart on a running container" docker update --restart unless-stopped e-ops2
expect_eq "takes effect" "$(docker inspect e-ops2 --format '{{.HostConfig.RestartPolicy.Name}}')" "unless-stopped"
expect_has "update of limits while running is refused" "$(docker update --cpus 1 e-ops2 2>&1)" "change at its next start"
docker stop -t 0 e-ops2 >/dev/null
docker update --cpus 1 --memory 512m e-ops2 >/dev/null
docker start e-ops2 >/dev/null
expect_eq "and applied at the next start" "$(docker exec e-ops2 cat /sys/fs/cgroup/cpu.max /sys/fs/cgroup/memory.max | tr '\n' ' ')" "100000 100000 536870912 "
docker rm -f e-ops2 >/dev/null
# docker commit: what the container changed, as a layer on its image.
docker run -d --name e-cm alpine sh -c 'echo made > /made; ln -s /made /link; rm /etc/motd; sleep 300' >/dev/null
sleep 1
check "commit with a message, an author, and changes" docker commit -m first -a e2e -c 'CMD ["cat", "/made"]' -c 'ENV GREETING=hello' e-cm e2e-committed:v1
expect_eq "the new image runs the changed CMD on the files" "$(docker run --rm e2e-committed:v1)" "made"
expect_eq "with the link, the deletion, and the ENV" "$(docker run --rm e2e-committed:v1 sh -c 'readlink /link; [ -e /etc/motd ] || echo gone; echo $GREETING' | tr '\n' ' ')" "/made gone hello "
expect_eq "and the author and message" "$(docker image inspect e2e-committed:v1 --format '{{.Author}} {{.Comment}}')" "e2e first"
expect_eq "the container keeps running" "$(docker inspect e-cm --format '{{.State.Status}} {{.State.Paused}}')" "running false"
untagged=$(docker commit e-cm)
expect_eq "commit without a name makes a dangling image" "$(docker images -q --no-trunc -f dangling=true)" "$untagged"
check "image prune removes it" docker image prune -f
expect_eq "and only it" "$(docker images -q --no-trunc -f dangling=true | wc -l | tr -d ' ') $(docker images -q e2e-committed:v1 | wc -l | tr -d ' ')" "0 1"
docker rm -f e-cm >/dev/null
docker rmi e2e-committed:v1 >/dev/null
# A sparse file that claims a terabyte: export and commit refuse it, the daemon stays up.
docker run -d --name e-sparse alpine sh -c 'truncate -s 1099511627776 /huge && sync && sleep 300' >/dev/null
sleep 2
expect_has "export refuses a file larger than the disk left" "$(docker export e-sparse 2>&1 >/dev/null | head -1)" "more than the"
expect_has "commit too" "$(docker commit e-sparse e2e-sparse 2>&1)" "more than the"
check "and the daemon is still up" docker version
docker rm -f e-sparse >/dev/null
docker run -d --name e-sig --stop-signal SIGWINCH alpine sh -c 'trap "echo got-winch; exit 0" WINCH; while :; do sleep 0.1; done' >/dev/null
sleep 0.5
docker stop e-sig >/dev/null
expect_eq "--stop-signal" "$(docker logs e-sig) $(docker inspect e-sig --format '{{.State.ExitCode}}')" "got-winch 0"
docker rm e-sig >/dev/null
docker run -d --name e-pall -P --expose 80 busybox httpd -f -p 80 >/dev/null
expect_has "-P publishes exposed ports" "$(docker port e-pall)" "80/tcp -> 0.0.0.0:"
docker rm -f e-pall >/dev/null
docker network create --subnet 172.30.5.0/24 e-ipnet >/dev/null
docker run -d --name e-ip --network e-ipnet --ip 172.30.5.50 --mac-address 02:42:ac:1e:05:32 alpine sleep 300 >/dev/null
expect_eq "--ip and --mac-address" "$(docker exec e-ip sh -c 'ip -4 -o addr show eth0 | awk "{print \$4}"; cat /sys/class/net/eth0/address' | tr '\n' ' ')" "172.30.5.50/24 02:42:ac:1e:05:32 "
expect_has "a taken --ip is refused" "$(run --network e-ipnet --ip 172.30.5.50 alpine true)" "Address already in use"
expect_has "--ip on bridge is refused, as on Docker" "$(run --ip 172.17.0.99 alpine true)" "user defined networks only"
expect_has "--link resolves the alias" "$(run --network e-ipnet --link e-ip:dbalias alpine getent hosts dbalias)" "172.30.5.50"
docker rm -f e-ip >/dev/null
docker network rm e-ipnet >/dev/null
# Restart policies: on-failure counts, a stop by hand holds always off.
docker run -d --name e-rf --restart on-failure:2 alpine sh -c 'exit 3' >/dev/null
eventually "on-failure:2 restarts twice" sh -c '[ "$(docker inspect e-rf --format "{{.RestartCount}} {{.State.Status}}")" = "2 exited" ]'
docker run -d --name e-ra --restart always alpine sh -c 'sleep 0.3; exit 1' >/dev/null
eventually "always restarts" sh -c '[ "$(docker inspect e-ra --format "{{.RestartCount}}")" -ge 1 ]'
docker stop -t 1 e-ra >/dev/null
held=$(docker inspect e-ra --format '{{.RestartCount}}')
sleep 2
expect_eq "docker stop holds always off" "$(docker inspect e-ra --format '{{.RestartCount}} {{.State.Status}}')" "$held exited"
# A Mac restart, or a crash: the daemon goes, and the VMs with it.
docker run -d --name e-rus --restart unless-stopped alpine sleep 300 >/dev/null
docker run -d --name e-crash alpine sh -c 'echo kept > /data; sleep 300' >/dev/null
sleep 1
stop_daemon
for f in "$HOME_DIR"/containers/*/state.json; do
    pid=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("pid", ""))' "$f" 2>/dev/null)
    [ -n "$pid" ] && kill -9 "$pid" 2>/dev/null
done
sleep 1
start_daemon
eventually "unless-stopped comes back when the daemon starts" sh -c '[ "$(docker inspect e-rus --format "{{.State.Status}}")" = running ]'
eventually "always stopped by hand comes back too, as on Docker" sh -c '[ "$(docker inspect e-ra --format "{{.State.Status}}")" = running ]'
check "a container whose VM was killed starts again" docker start e-crash
expect_eq "and keeps its files (its rootfs is repaired)" "$(docker exec e-crash sh -c 'cat /data; echo w > /new; cat /new' | tr '\n' ' ')" "kept w "
docker rm -f e-rf e-ra e-rus e-crash >/dev/null

# Many containers stopping together on a fresh daemon (the uplink's first use comes from
# several threads at once; a lazy var there crashed the daemon).
stop_daemon
start_daemon
for i in $(seq 8); do docker run -d --name "e2e-burst$i" alpine sleep 300 >/dev/null; done
docker rm -f $(docker ps -aq --filter name=e2e-burst) >/dev/null 2>&1
check "the daemon survives eight containers removed at once" docker version
expect_eq "and all eight are gone" "$(docker ps -aq --filter name=e2e-burst | wc -l | tr -d ' ')" "0"

check "rmi removes the image" docker rmi alpine

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ] || { echo "--- daemon log"; tail -20 "$HOME_DIR/daemon.log"; exit 1; }
