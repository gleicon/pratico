#!/usr/bin/env bash
# End-to-end suite: runs pratico-daemon in a throwaway home and drives the real
# `docker` CLI against its socket. Each check names the SPEC AC it covers. The Docker API
# behavior lives here; e2e/embedded.sh covers the runtime underneath (shims, pratico-net).
# Usage: e2e/run.sh <bin-dir>
set -uo pipefail

BIN="${1:?usage: e2e/run.sh <bin-dir>}"
# Pinned to the Homebrew docker CLI; override with DOCKER=/path/to/docker.
DOCKER="${DOCKER:-/opt/homebrew/bin/docker}"
[ -x "$DOCKER" ] || { echo "e2e needs the docker CLI at $DOCKER"; exit 1; }
docker() { "$DOCKER" "$@"; }
echo "docker CLI: $DOCKER ($("$DOCKER" version --format '{{.Client.Version}}' 2>/dev/null))"
ASSETS="${PRATICO_RUNTIME_ASSETS:-$(pwd)/.build/runtime-assets}"
[ -f "$ASSETS/vmlinux" ] || { echo "runtime assets missing: run make assets"; exit 1; }
export PRATICO_RUNTIME_ASSETS="$ASSETS"

# $TMPDIR keeps the socket path under the 104-byte sun_path limit.
HOME_DIR="$(mktemp -d -t pratico-e2e)"
SOCK="$HOME_DIR/docker.sock"
export DOCKER_HOST="unix://$SOCK"
# An isolated CLI config: the user's registry logins must never reach the daemon under
# test. A config with no auth settings makes the CLI fall back to the macOS Keychain
# helper, so it carries one inert entry.
export DOCKER_CONFIG="$HOME_DIR/docker-config"
mkdir -p "$DOCKER_CONFIG"
echo '{"auths":{"pratico.invalid":{}}}' >"$DOCKER_CONFIG/config.json"
DAEMON_PID=""
# Hermetic scanning: fake scanners and a local KEV feed, never the network (D-24).
FAKES="$(cd "$(dirname "$0")" && pwd)/fakes"
export PRATICO_OSV_BIN="$FAKES/osv-scanner" PRATICO_GRYPE_BIN="$FAKES/grype" PRATICO_TRIVY_BIN="$FAKES/trivy"
export PRATICO_KEV_URL="file://$FAKES/kev.json" PRATICO_FAKE_SCAN_GATE="$HOME_DIR/scan-gate"
export PRATICO_FAKE_SCAN_FAIL="$HOME_DIR/scan-fail"

pass=0
fail=0
ok() { echo "ok   $1"; pass=$((pass + 1)); }
bad() { echo "FAIL $1${2:+ — $2}"; fail=$((fail + 1)); }
check() { local name="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$name"; else bad "$name"; fi; }
expect_eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "want [$3] got [$2]"; fi; }
expect_has() { if grep -qi -- "$3" <<<"$2"; then ok "$1"; else bad "$1" "[$3] not in [$2]"; fi; }

start_daemon() {
    "$BIN/pratico-daemon" --home "$HOME_DIR" >>"$HOME_DIR/daemon.log" 2>&1 &
    DAEMON_PID=$!
    for _ in $(seq 50); do [ -S "$SOCK" ] && return 0; sleep 0.1; done
    echo "daemon did not create $SOCK"; cat "$HOME_DIR/daemon.log"; exit 1
}

stop_daemon() {
    [ -n "$DAEMON_PID" ] && kill "$DAEMON_PID" 2>/dev/null && wait "$DAEMON_PID" 2>/dev/null
    DAEMON_PID=""
}

cleanup() {
    if [ -S "$SOCK" ]; then
        ids=$(docker ps -aq 2>/dev/null)
        [ -n "$ids" ] && docker rm -f $ids >/dev/null 2>&1
        docker network prune -f >/dev/null 2>&1
    fi
    stop_daemon
    rm -rf "$HOME_DIR"  # images live in its store too
}
trap cleanup EXIT

# AC-3: without its kernel the daemon refuses to start, creates no socket, and leaves a
# reason for the menubar.
(cd "$HOME_DIR" && PRATICO_RUNTIME_ASSETS="$HOME_DIR/no-assets" "$BIN/pratico-daemon" --home "$HOME_DIR" >/dev/null 2>&1)
expect_eq "AC-3 daemon refuses without its runtime" "$?" "3"
if [ -S "$SOCK" ]; then bad "AC-3 no socket without the runtime"; else ok "AC-3 no socket without the runtime"; fi
expect_has "AC-3 reason names the runtime" "$(cat "$HOME_DIR/daemon.err" 2>/dev/null)" "runtime unavailable"

# AC-41: an unknown key stops the daemon, naming key and line.
printf '# pratico\nbogus_key = 1\n' >"$HOME_DIR/config.toml"
"$BIN/pratico-daemon" --home "$HOME_DIR" >/dev/null 2>&1
expect_eq "AC-41 daemon refuses unknown config key" "$?" "4"
err=$(cat "$HOME_DIR/daemon.err" 2>/dev/null)
expect_has "AC-41 error names the key" "$err" "bogus_key"
expect_has "AC-41 error names the line" "$err" "line 2"
printf 'default_memory = lots\n' >"$HOME_DIR/config.toml"
"$BIN/pratico-daemon" --home "$HOME_DIR" >/dev/null 2>&1
expect_has "FR-38 invalid value is refused, naming the key" "$(cat "$HOME_DIR/daemon.err" 2>/dev/null)" "default_memory"

# D-14: config defaults apply when Docker sets no limit.
printf 'default_memory = 512\ndefault_cpus = 2\n' >"$HOME_DIR/config.toml"
start_daemon
if [ -e "$HOME_DIR/daemon.err" ]; then bad "startup clears the previous error"; else ok "startup clears the previous error"; fi
docker run -d --name e2e-cfg alpine sleep 60 >/dev/null
expect_eq "D-14 config default CPUs reach the VM" "$(docker exec e2e-cfg nproc)" "2"
expect_eq "D-14 config default memory limits the container" "$(docker exec e2e-cfg cat /sys/fs/cgroup/memory.max)" "536870912"
docker rm -f e2e-cfg >/dev/null
stop_daemon
rm "$HOME_DIR/config.toml"

start_daemon
if [ -e "$HOME_DIR/daemon.err" ]; then bad "startup clears the previous error"; else ok "startup clears the previous error"; fi

# --- Skeleton ---------------------------------------------------------------
tm=$(tmutil isexcluded "$HOME_DIR/store" "$HOME_DIR/containers" 2>&1)
expect_eq "AC-42 store and containers excluded from Time Machine" "$(grep -c '\[Excluded\]' <<<"$tm")" "2"
expect_eq "AC-1 socket mode is 0600" "$(stat -f %Lp "$SOCK")" "600"
check "AC-6 docker version prints client and server" docker version
expect_eq "AC-53 server API version is pinned" "$(docker version --format '{{.Server.APIVersion}}')" "1.55"
expect_eq "AC-53 server minimum API version" "$(docker version --format '{{.Server.MinAPIVersion}}')" "1.44"
expect_has "AC-7 docker inspect nope" "$(docker inspect nope 2>&1)" "no such object: nope"
resp=$(curl -s -w ' %{http_code}' --unix-socket "$SOCK" http://d/v1.55/swarm)
expect_has "AC-29 unimplemented endpoint is 501" "$resp" " 501$"
expect_has "AC-29 501 names the endpoint" "$resp" "/swarm"
check "Connection: close ends the connection after the reply" python3 -c "
import socket,sys,time
s=socket.socket(socket.AF_UNIX); s.connect(sys.argv[1]); s.settimeout(3); t=time.time()
s.sendall(b'GET /_ping HTTP/1.1\\r\\nHost: d\\r\\nConnection: close\\r\\n\\r\\n')
while s.recv(4096): pass
assert time.time()-t < 1" "$SOCK"

# --- First container --------------------------------------------------------
pull=$(docker pull busybox 2>&1)
expect_has "AC-8 docker pull streams progress" "$pull" "busybox:latest"
expect_has "AC-8 docker images lists pulled image" "$(docker images --format '{{.Repository}}:{{.Tag}}')" "busybox:latest"
# AC-24: tag, inspect, rmi, prune. (`prune -a` is not run: it would remove the
# user's own unused images.)
check "AC-24 docker tag" docker tag busybox pratico-e2e/a:1
expect_has "AC-24 image inspect lists both tags" "$(docker image inspect pratico-e2e/a:1 --format '{{json .RepoTags}}')" '"busybox:latest".*"pratico-e2e/a:1"\|"pratico-e2e/a:1".*"busybox:latest"'
expect_eq "docker images shows one ID for both tags" "$(docker images --format '{{.ID}}' busybox) $(docker images --format '{{.ID}}' pratico-e2e/a)" "$(docker images --format '{{.ID}}' busybox) $(docker images --format '{{.ID}}' busybox)"
bb_id=$(docker image inspect busybox --format '{{.Id}}')
expect_has "rmi by ID with two tags needs force" "$(docker rmi "${bb_id#sha256:}" 2>&1)" "referenced in multiple repositories"
expect_eq "AC-24 docker rmi untags only" "$(docker rmi pratico-e2e/a:1 2>&1)" "Untagged: pratico-e2e/a:1"
check "busybox survives the untag" docker image inspect busybox
docker run -d --name e2e-img busybox sleep 300 >/dev/null
expect_has "rmi of an image in use needs force" "$(docker rmi busybox 2>&1)" "being used by a container"
docker rm -f e2e-img >/dev/null
docker save busybox -o "$HOME_DIR/saved.tar"
saved=$(python3 -I - "$HOME_DIR/saved.tar" <<'PY'
import json, sys, tarfile
t = tarfile.open(sys.argv[1])
names = set(t.getnames())
m = json.load(t.extractfile("manifest.json"))[0]
ok = all(p in names for p in [m["Config"], *m["Layers"]]) and not any(n.startswith("./") for n in names)
print(m["RepoTags"][0] if ok else "broken")
PY
)
expect_eq "docker save writes a Docker archive scanners can read" "$saved" "busybox:latest"
check "AC-24 docker image prune -f" docker image prune -f
expect_has "docker rmi of a missing image is 404" "$(docker rmi pratico-e2e/none 2>&1)" "No such image"

expect_eq "AC-10 docker run --rm prints hello" "$(docker run --rm alpine echo hello 2>&1)" "hello"
docker run --rm alpine sh -c 'exit 3' >/dev/null 2>&1
expect_eq "AC-10 exit code propagates" "$?" "3"
expect_eq "stdout and stderr stay separate" "$(docker run --rm alpine sh -c 'echo out; echo err >&2' 2>/dev/null)" "out"
expect_eq "AC-10 --rm removes the container" "$(docker ps -aq | wc -l | tr -d ' ')" "0"
expect_eq "AC-18 env and workdir reach the process" \
    "$(docker run --rm -e FOO=bar -w /tmp alpine sh -c 'echo $FOO; pwd' | tr '\n' ' ')" "bar /tmp "

# --- Bind mounts --------------------------------------------------------------
MNT="$HOME_DIR/mnt"
mkdir -p "$MNT" && echo hi >"$MNT/f"
expect_eq "AC-16 bind mount reads host file" "$(docker run --rm -v "$MNT:/x" alpine cat /x/f)" "hi"
docker run --rm -v "$MNT:/x" alpine touch /x/g >/dev/null 2>&1
if [ -e "$MNT/g" ]; then ok "AC-17 bind mount is read-write without suffix"; else bad "AC-17 bind mount is read-write without suffix"; fi
docker run --rm -v "$MNT:/x:ro" alpine touch /x/h >/dev/null 2>&1
expect_eq "AC-17 :ro mount refuses writes (exit 1)" "$?" "1"
if [ -e "$MNT/h" ]; then bad "AC-17 :ro leaves host untouched"; else ok "AC-17 :ro leaves host untouched"; fi
expect_eq "--mount type=bind,readonly works" \
    "$(docker run --rm --mount "type=bind,source=$MNT,target=/x,readonly" alpine sh -c 'cat /x/f; touch /x/i 2>/dev/null || echo ro')" "hi
ro"
docker run --rm -v "$MNT/new:/n" alpine true >/dev/null 2>&1
if [ -d "$MNT/new" ]; then ok "-v creates a missing host directory"; else bad "-v creates a missing host directory"; fi
expect_has "--mount with missing source is refused" \
    "$(docker run --rm --mount "type=bind,source=$MNT/missing,target=/x" alpine true 2>&1)" "does not exist"

# --- Ports ------------------------------------------------------------------
LAN_IP=$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null)
WEB='mkdir -p /w && echo pratico-ok >/w/index.html && httpd -f -p 80 -h /w'
docker run -d --name e2e-p1 -p 18080:80 busybox sh -c "$WEB" >/dev/null
docker run -d --name e2e-p2 -p 127.0.0.1:18081:80 busybox sh -c "$WEB" >/dev/null
for _ in $(seq 50); do curl -s -m 1 localhost:18080 >/dev/null && curl -s -m 1 localhost:18081 >/dev/null && break; sleep 0.2; done
expect_eq "AC-15 -p reachable on localhost" "$(curl -s -m 2 localhost:18080)" "pratico-ok"
if [ -n "$LAN_IP" ]; then
    expect_eq "AC-15 -p reachable on LAN IP $LAN_IP" "$(curl -s -m 2 "$LAN_IP:18080")" "pratico-ok"
    expect_eq "AC-15.a -p 127.0.0.1 reachable on localhost" "$(curl -s -m 2 localhost:18081)" "pratico-ok"
    curl -s -m 2 "$LAN_IP:18081" >/dev/null 2>&1
    if [ $? -eq 0 ]; then bad "AC-15.a -p 127.0.0.1 not reachable on LAN IP"; else ok "AC-15.a -p 127.0.0.1 not reachable on LAN IP"; fi
else
    bad "AC-15 needs a LAN IP on en0 or en1"
fi
expect_eq "docker port shows the binding" "$(docker port e2e-p2 80/tcp)" "127.0.0.1:18081"
docker rm -f e2e-p1 e2e-p2 >/dev/null

docker run -d --name e2e-web -l a=1 -v "$MNT:/x:ro" alpine sleep 300 >/dev/null
docker run -d --name e2e-other -l a=2 alpine sleep 300 >/dev/null
expect_eq "AC-14 docker ps filters by label" "$(docker ps --filter label=a=1 --format '{{.Names}}')" "e2e-web"

before=$(docker inspect e2e-web --format '{{.Name}} {{json .Config.Labels}} {{json .HostConfig.PortBindings}} {{json .Mounts}}')
stop_daemon
start_daemon
after=$(docker inspect e2e-web --format '{{.Name}} {{json .Config.Labels}} {{json .HostConfig.PortBindings}} {{json .Mounts}}' 2>&1)
expect_eq "AC-12 metadata survives daemon restart" "$after" "$before"


# --- Lifecycle ---------------------------------------------------------------
docker run -d --name e2e-life alpine sleep 300 >/dev/null
if docker stop -t 2 e2e-life >/dev/null && docker start e2e-life >/dev/null && docker restart e2e-life >/dev/null &&
    docker pause e2e-life >/dev/null && docker unpause e2e-life >/dev/null &&
    docker kill -s KILL e2e-life >/dev/null && docker rm e2e-life >/dev/null; then
    ok "AC-13 stop/start/restart/pause/unpause/kill/rm"
else
    bad "AC-13 stop/start/restart/pause/unpause/kill/rm"
fi
if docker ps -a --format '{{.Names}}' | grep -q e2e-life; then bad "AC-13 removed container is gone"; else ok "AC-13 removed container is gone"; fi

# AC-13.a: a paused container runs nothing until unpaused.
docker run -d --name e2e-count alpine sh -c 'i=0; while true; do i=$((i+1)); echo $i; sleep 0.1; done' >/dev/null
sleep 1
docker pause e2e-count >/dev/null
expect_eq "AC-13.a inspect reports State.Paused" "$(docker inspect e2e-count --format '{{.State.Paused}} {{.State.Status}}')" "true paused"
expect_eq "AC-13.a docker ps filters paused" "$(docker ps --filter status=paused --format '{{.Names}}')" "e2e-count"
n1=$(docker logs e2e-count | wc -l); sleep 2; n2=$(docker logs e2e-count | wc -l)
expect_eq "AC-13.a no lines logged while paused" "$n2" "$n1"
expect_has "pause twice is a conflict" "$(docker pause e2e-count 2>&1)" "already paused"
docker unpause e2e-count >/dev/null; sleep 1
if [ "$(docker logs e2e-count | wc -l)" -gt "$n2" ]; then ok "AC-13.a lines resume after unpause"; else bad "AC-13.a lines resume after unpause"; fi
docker pause e2e-count >/dev/null
check "stop works on a paused container" docker stop -t 1 e2e-count
docker start e2e-count >/dev/null; docker pause e2e-count >/dev/null
stop_daemon
start_daemon
expect_eq "a paused container stays paused across a daemon restart" "$(docker inspect e2e-count --format '{{.State.Status}}')" "paused"
check "and unpauses after it" docker unpause e2e-count
docker rm -f e2e-count >/dev/null

# AC-23: lifecycle events stream in order; since/until replays them.
t0=$(date +%s)
docker events --filter label=e2e-ev=1 --format '{{.Action}}' >"$HOME_DIR/events" 2>&1 &
ev_pid=$!
sleep 1
docker run -d --name e2e-ev -l e2e-ev=1 alpine sleep 300 >/dev/null
docker pause e2e-ev >/dev/null && docker unpause e2e-ev >/dev/null && docker rm -f e2e-ev >/dev/null
sleep 1
kill "$ev_pid" 2>/dev/null; wait "$ev_pid" 2>/dev/null
live=$(grep -vx kill "$HOME_DIR/events" | tr '\n' ' ')
expect_eq "AC-23 events stream create/start/pause/unpause/die/destroy" "$live" "create start pause unpause die destroy "
replay=$(docker events --since "$t0" --until "$(($(date +%s) + 1))" --filter label=e2e-ev=1 --filter event=die --format '{{.Action}} {{.Actor.Attributes.name}} {{.Actor.Attributes.exitCode}}')
expect_eq "events --since/--until replays with filters" "$replay" "die e2e-ev 137"

# AC-52 (daemon part): healthcheck status, events, and recovery.
docker events --filter container=e2e-h --filter event=health_status --format '{{.Action}}' >"$HOME_DIR/hevents" 2>&1 &
hev_pid=$!
docker run -d --name e2e-h --health-cmd 'test -f /ok' --health-interval 1s --health-retries 2 alpine sleep 300 >/dev/null
hs=""
for _ in $(seq 50); do hs=$(docker inspect e2e-h --format '{{.State.Health.Status}}'); [ "$hs" = unhealthy ] && break; sleep 0.1; done
expect_eq "AC-52 State.Health.Status becomes unhealthy within 5 s" "$hs" "unhealthy"
expect_has "ps shows the health status" "$(docker ps --filter name=e2e-h --format '{{.Status}}')" "(unhealthy)"
docker exec e2e-h touch /ok
for _ in $(seq 30); do hs=$(docker inspect e2e-h --format '{{.State.Health.Status}}'); [ "$hs" = healthy ] && break; sleep 0.1; done
expect_eq "AC-52 status becomes healthy within 3 s of the fix" "$hs" "healthy"
expect_eq "ps filters by health" "$(docker ps --filter health=healthy --format '{{.Names}}')" "e2e-h"
sleep 0.5
kill "$hev_pid" 2>/dev/null; wait "$hev_pid" 2>/dev/null
expect_eq "AC-52 health_status events emitted" "$(tr '\n' ' ' <"$HOME_DIR/hevents")" "health_status: unhealthy health_status: healthy "
docker rm -f e2e-h >/dev/null

# AC-22: stats one-shot and streamed.
docker run -d --name e2e-stats alpine sh -c 'while true; do :; done' >/dev/null
docker run -d --name e2e-idle alpine sleep 300 >/dev/null
docker stats --no-stream e2e-stats >/dev/null 2>&1  # first call starts sampling; CPU % needs two samples
sleep 5
row=$(docker stats --no-stream --format '{{.Name}}|{{.CPUPerc}}|{{.MemUsage}}|{{.NetIO}}' e2e-stats)
IFS='|' read -r s_name s_cpu s_mem s_net <<<"$row"
if [ "$s_name" = e2e-stats ] && [ "$s_cpu" != "--" ] && [ -n "$s_cpu" ] && [ "$s_mem" != "-- / --" ] && [ "$s_net" != "--" ]; then
    ok "AC-22 stats --no-stream row has CPU, MEM, NET ($row)"
else
    bad "AC-22 stats --no-stream row has CPU, MEM, NET" "$row"
fi
cpu_num=${s_cpu%\%}
if [ "${cpu_num%%.*}" -ge 50 ] 2>/dev/null; then ok "busy loop shows high CPU ($s_cpu)"; else bad "busy loop shows high CPU" "$s_cpu"; fi
expect_has "stats on an unlimited container does not crash the daemon" \
    "$(docker stats --no-stream --format '{{.Name}} {{.CPUPerc}}' e2e-idle 2>&1)" "^e2e-idle [0-9]"
lines=$(curl -s -m 7 --unix-socket "$SOCK" "http://d/v1.55/containers/e2e-stats/stats?stream=true" | grep -c '"cpu_stats"')
if [ "$lines" -ge 2 ]; then ok "stats streams repeated samples ($lines in 7s)"; else bad "stats streams repeated samples" "$lines"; fi
docker rm -f e2e-stats e2e-idle >/dev/null

# AC-21: docker cp out of and into a running container.
docker run -d --name e2e-cp alpine sleep 300 >/dev/null
CP="$HOME_DIR/cp"; mkdir -p "$CP"
check "AC-21 docker cp out succeeds" docker cp e2e-cp:/etc/hostname "$CP/h"
expect_eq "AC-21 copied file has the container hostname" "$(cat "$CP/h" 2>/dev/null)" "$(docker inspect e2e-cp --format '{{.Config.Hostname}}')"
check "AC-21 docker cp in succeeds" docker cp "$CP/h" e2e-cp:/tmp/h
expect_eq "AC-21 contents match after the round trip" "$(docker exec e2e-cp cat /tmp/h)" "$(cat "$CP/h")"
mkdir -p "$CP/d/sub" && echo deep >"$CP/d/sub/f"
docker cp "$CP/d" e2e-cp:/tmp/ >/dev/null 2>&1
expect_eq "cp copies a directory tree in" "$(docker exec e2e-cp cat /tmp/d/sub/f)" "deep"
docker cp e2e-cp:/tmp/d "$CP/back" >/dev/null 2>&1
expect_eq "cp copies a directory tree out" "$(cat "$CP/back/sub/f" 2>/dev/null)" "deep"
expect_has "cp of a missing path is refused" "$(docker cp e2e-cp:/nope "$CP/x" 2>&1)" "Could not find the file /nope"
docker rm -f e2e-cp >/dev/null

# AC-20: exec with and without a TTY.
docker run -d --name e2e-exec alpine sleep 300 >/dev/null
expect_eq "AC-20 docker exec echo ok" "$(docker exec e2e-exec echo ok)" "ok"
docker exec e2e-exec sh -c 'exit 7' >/dev/null 2>&1
expect_eq "exec exit code propagates" "$?" "7"
expect_eq "exec -i pipes stdin" "$(echo piped | docker exec -i e2e-exec cat)" "piped"
expect_eq "exec stderr stays separate" "$(docker exec e2e-exec sh -c 'echo out; echo err >&2' 2>/dev/null)" "out"
tty_out=$(python3 -I "$(dirname "$0")/pty.py" 33 111 "$DOCKER" exec -it e2e-exec sh -c 'sleep 1; tty; stty size' | tr -d '\r')
expect_has "AC-20 exec -it gets a /dev/pts tty" "$tty_out" "^/dev/pts/"
expect_has "exec -it receives the terminal size" "$tty_out" "^33 111$"
docker exec -d e2e-exec touch /tmp/detached
sleep 1
check "exec -d runs detached" docker exec e2e-exec test -e /tmp/detached
docker pause e2e-exec >/dev/null
expect_has "exec on a paused container is refused" "$(docker exec e2e-exec true 2>&1)" "paused"
docker rm -f e2e-exec >/dev/null

id=$(docker run -d alpine sh -c 'echo one; echo two; echo three')
docker wait "$id" >/dev/null
expect_eq "docker logs --tail" "$(docker logs --tail 2 "$id" | tr '\n' ' ')" "two three "
expect_has "docker ps -a shows exit status" "$(docker ps -a --filter id="$id" --format '{{.Status}}')" "Exited (0)"

# AC-19: tail + follow prints the last lines, then keeps streaming.
docker run -d --name e2e-tick alpine sh -c 'i=0; while true; do i=$((i+1)); echo tick $i; sleep 1; done' >/dev/null
sleep 4
docker logs --tail 2 -f e2e-tick >"$HOME_DIR/follow" 2>&1 &
follow_pid=$!
sleep 3
kill "$follow_pid" 2>/dev/null; wait "$follow_pid" 2>/dev/null
first=$(head -1 "$HOME_DIR/follow" | awk '{print $2}')
total=$(wc -l <"$HOME_DIR/follow" | tr -d ' ')
if [ "$total" -ge 4 ] && [ "$(tail -1 "$HOME_DIR/follow" | awk '{print $2}')" -gt $((first + 2)) ]; then
    ok "AC-19 logs --tail 2 -f streams new lines"
else
    bad "AC-19 logs --tail 2 -f streams new lines" "$(tr '\n' '|' <"$HOME_DIR/follow")"
fi
expect_has "logs --timestamps prefixes RFC 3339 time" "$(docker logs -t --tail 1 e2e-tick)" "^20[0-9][0-9]-[0-9][0-9]-[0-9][0-9]T"
docker rm -f e2e-tick >/dev/null

# AC-51: 200 MiB of output leaves at most 100 MiB on disk, newest line kept.
big=$(docker run -d alpine sh -c 'yes 0123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456 | head -n 2097152; echo LAST-LINE')
docker wait "$big" >/dev/null
disk=$(cat "$HOME_DIR/containers/$big"/log* | wc -c | tr -d ' ')
if [ "$disk" -le 104857600 ] && [ "$disk" -gt 0 ]; then ok "AC-51 on-disk log capped at 100 MiB ($disk bytes)"; else bad "AC-51 on-disk log capped at 100 MiB" "$disk bytes"; fi
expect_eq "AC-51 logs --tail 1 returns the latest line" "$(docker logs --tail 1 "$big")" "LAST-LINE"
docker rm "$big" >/dev/null

# --- Networks (D-25) ----------------------------------------------------------
t0=$(date +%s)
expect_eq "AC-26 bridge and none are listed" "$(docker network ls --format '{{.Name}}' | tr '\n' ' ')" "bridge none "
check "network create" docker network create e2e-n
expect_has "duplicate network name is refused" "$(docker network create e2e-n 2>&1)" "already exists"
docker run -d --name e2e-na --network e2e-n busybox sleep 300 >/dev/null
docker run -d --name e2e-nb --network e2e-n --network-alias db busybox sleep 300 >/dev/null
check "AC-27 a reaches b by name" docker exec e2e-na ping -c1 -W2 e2e-nb
check "network alias resolves" docker exec e2e-na ping -c1 -W2 db
expect_eq "network inspect lists members" \
    "$(docker network inspect e2e-n --format '{{range .Containers}}{{.Name}} {{end}}' | tr ' ' '\n' | sort | xargs)" "e2e-na e2e-nb"
nb_ip=$(docker inspect e2e-nb --format '{{(index .NetworkSettings.Networks "e2e-n").IPAddress}}')
expect_has "container inspect reports its address on the network" "$nb_ip" "172.18."
expect_eq "ps filters by network" "$(docker ps --filter network=e2e-n -q | wc -l | tr -d ' ')" "2"
if docker run --rm busybox ping -c1 -W1 "$nb_ip" >/dev/null 2>&1; then
    bad "bridge containers cannot reach a custom network"
else
    ok "bridge containers cannot reach a custom network"
fi
check "custom network reaches the internet" docker exec e2e-na wget -qO- -T5 http://1.1.1.1
docker run -d --name e2e-nbr busybox sleep 300 >/dev/null
check "connect a running container" docker network connect e2e-n e2e-nbr
docker create --name e2e-nc busybox sleep 300 >/dev/null
check "connect a created container with an alias" docker network connect --alias cache e2e-n e2e-nc
docker start e2e-nc >/dev/null
check "the connected container is reachable by its alias" docker exec e2e-na ping -c1 -W2 cache
check "it is on both networks" test "$(docker inspect e2e-nc --format '{{len .NetworkSettings.Networks}}')" = 2
docker network disconnect e2e-n e2e-nb
if docker exec e2e-na ping -c1 -W2 e2e-nb >/dev/null 2>&1; then bad "AC-27 after disconnect b is unreachable by name"; else ok "AC-27 after disconnect b is unreachable by name"; fi
expect_has "network rm refuses while containers use it" "$(docker network rm e2e-n 2>&1)" "active endpoints"
expect_has "bridge cannot be removed" "$(docker network rm bridge 2>&1)" "pre-defined"
docker rm -f e2e-na e2e-nb e2e-nc e2e-nbr >/dev/null
check "AC-27 network rm succeeds once its containers are removed" docker network rm e2e-n
expect_eq "network events" \
    "$(docker events --since "$t0" --until "$(($(date +%s) + 1))" --filter type=network --filter network=e2e-n --format '{{.Action}}' | xargs)" \
    "create connect connect disconnect destroy"

# D-24: a serious scan finding stops the image's containers and blocks new starts.
docker pull busybox:musl >/dev/null 2>&1
docker run -d --name e2e-evil busybox:musl sleep 300 >/dev/null
touch "$PRATICO_FAKE_SCAN_GATE"
for _ in $(seq 100); do [ "$(docker inspect e2e-evil --format '{{.State.Running}}')" = false ] && break; sleep 0.1; done
expect_eq "D-24 serious finding stops the image's container" "$(docker inspect e2e-evil --format '{{.State.Running}}')" "false"
expect_has "D-24 start is blocked, naming the finding" "$(docker start e2e-evil 2>&1)" "MAL-0000-0001"
# The alert follows the stop, which also says which containers were stopped.
for _ in $(seq 50); do grep -q "busybox:musl blocked" "$HOME_DIR/alerts.json" 2>/dev/null && break; sleep 0.1; done
expect_has "D-24 alert written for the menubar" "$(cat "$HOME_DIR/alerts.json" 2>/dev/null)" "busybox:musl blocked"
musl_id=$(docker image inspect busybox:musl --format '{{.Id}}')
report="$HOME_DIR/scans/${musl_id#sha256:}.json"
expect_has "D-24 report keeps the bill of materials" "$(cat "$report" 2>/dev/null)" "busybox@1.37.0"
touch "$PRATICO_FAKE_SCAN_FAIL"
docker pull busybox:musl >/dev/null 2>&1  # triggers a rescan, which now fails
for _ in $(seq 50); do [ -e "$PRATICO_FAKE_SCAN_FAIL.ran" ] && break; sleep 0.1; done
sleep 1
rm -f "$PRATICO_FAKE_SCAN_FAIL"
expect_has "a failed rescan keeps the block" "$(docker start e2e-evil 2>&1)" "MAL-0000-0001"
check "other images are not blocked" docker run --rm alpine true
stop_daemon
printf 'scan_allow = ["%s"]\n' "$musl_id" >"$HOME_DIR/config.toml"
start_daemon
check "D-24 scan_allow lets the image run" docker start e2e-evil
docker rm -f e2e-evil >/dev/null

# Your own scanner (scan_custom), and the menubar's scanner checkup.
stop_daemon
printf 'scan_custom = ["%s"]\n' "$FAKES/my-scanner" >"$HOME_DIR/config.toml"
start_daemon
doctor=$(curl -s --unix-socket "$SOCK" http://d/pratico/scanners)
check "the scanner checkup lists built-in and custom scanners with paths" python3 -c "import json,sys; d=json.loads(sys.argv[1]); n={s['name']: s for s in d['scanners']}; assert set(n) >= {'osv-scanner','grype','trivy','my-scanner'} and all(s['path'] for s in n.values()) and n['grype']['brew'] == 'grype' and not n['my-scanner']['builtin']" "$doctor"
docker pull busybox:uclibc >/dev/null 2>&1
docker create --name e2e-custom busybox:uclibc true >/dev/null
for _ in $(seq 100); do docker start e2e-custom 2>&1 | grep -q MAL-CUSTOM-1 && break; sleep 0.1; done
expect_has "a custom scanner's finding blocks the image" "$(docker start e2e-custom 2>&1)" "MAL-CUSTOM-1"
results=$(curl -s --unix-socket "$SOCK" http://d/pratico/scans)
check "scan results say which scanner found what" python3 -c "import json,sys; r={t: i for i in json.loads(sys.argv[1]) for t in i['Tags']}['busybox:uclibc']; f=[f for f in r['Report']['findings'] if f['id']=='MAL-CUSTOM-1'][0]; assert f['sources']==['my-scanner'] and r['Blocked'] and {s['name'] for s in r['Report']['scanners'] if s['ran']} >= {'osv-scanner','grype','trivy','my-scanner'}" "$results"
summary=$(curl -s --unix-socket "$SOCK" http://d/pratico/scans/summary)
check "the scan summary counts blocked and critical-or-high images" python3 -c "import json,sys; s=json.loads(sys.argv[1]); assert s['Blocked'] >= 1 and 'CriticalOrHigh' in s and s['Images'] >= 2" "$summary"
queued=$(curl -s -X POST --unix-socket "$SOCK" http://d/pratico/scans)
check "Scan Now queues every image" python3 -c "import json,sys; q=json.loads(sys.argv[1]); assert q['Enabled'] and q['Queued'] >= 2" "$queued"
docker rm -f e2e-custom >/dev/null
rm -f "$HOME_DIR/config.toml"

docker rm -f $(docker ps -aq) >/dev/null 2>&1
pid="$DAEMON_PID"
stop_daemon
if [ -S "$SOCK" ] || kill -0 "$pid" 2>/dev/null; then bad "AC-2 stop leaves no socket and no process"; else ok "AC-2 stop leaves no socket and no process"; fi

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ] || { echo "--- daemon log"; tail -20 "$HOME_DIR/daemon.log"; exit 1; }
