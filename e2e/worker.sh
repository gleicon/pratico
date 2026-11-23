#!/usr/bin/env bash
# The release on a real Linux host (docs/linux-hosts.md): copies the tarball there, checks
# its SHA-256, and runs e2e/host-checks.sh, the checks the Mac's test host runs, as the
# host's sudo user. The host is a worker given to pratico: the run installs and uninstalls
# pratico and its hardening, installs nothing from Docker, and leaves pratico installed at
# the end (WORKER_KEEP=0 leaves it uninstalled).
# Usage: WORKER_KEY=~/.ssh/key e2e/worker.sh user@host dist/pratico-<v>-linux-<arch>.tar.gz
set -uo pipefail

TARGET="${1:?usage: WORKER_KEY=<key> e2e/worker.sh user@host <tarball>}"
TAR="${2:?usage: WORKER_KEY=<key> e2e/worker.sh user@host <tarball>}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DOCKER="${DOCKER:-/opt/homebrew/bin/docker}"
NAME="$(basename "$TAR" .tar.gz)"
case "$NAME" in *-linux-arm64) SERVER_ARCH=linux/arm64 ;; *-linux-x86_64) SERVER_ARCH=linux/amd64 ;; *) echo "worker: $TAR is not a pratico Linux tarball"; exit 2 ;; esac
[ -f "$TAR" ] && [ -f "$TAR.sha256" ] || { echo "worker: $TAR and its .sha256 are needed (make linux-dist)"; exit 2; }

WORK="$(mktemp -d -t pratico-worker)"
trap 'rm -rf "$WORK"' EXIT
# An ssh the docker CLI finds on PATH, with this host's key; host keys from ~/.ssh/known_hosts.
cat >"$WORK/ssh_config" <<EOF
Host worker
    HostName ${TARGET#*@}
    User ${TARGET%@*}
    ${WORKER_KEY:+IdentityFile $WORKER_KEY}
    BatchMode yes
    LogLevel ERROR
EOF
mkdir -p "$WORK/bin"
printf '#!/bin/sh\nexec /usr/bin/ssh -F %s "$@"\n' "$WORK/ssh_config" >"$WORK/bin/ssh"
chmod +x "$WORK/bin/ssh"
export DOCKER_CONFIG="$WORK/docker-config"
mkdir -p "$DOCKER_CONFIG" && echo '{"auths":{"pratico.invalid":{}}}' >"$DOCKER_CONFIG/config.json"
remote() { PATH="$WORK/bin:$PATH" "$DOCKER" -H ssh://worker "$@"; }
asuser() { "$WORK/bin/ssh" worker "$*"; }
onhost() { "$WORK/bin/ssh" worker "sudo -n bash -c $(printf %q "$*")"; }

pass=0
fail=0
ok() { echo "ok   $1"; pass=$((pass + 1)); }
bad() { echo "FAIL $1${2:+ — $2}"; fail=$((fail + 1)); }
check() { local name="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$name"; else bad "$name"; fi; }
expect_eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "want [$3] got [$2]"; fi; }
eventually_eq() {
    local name="$1" want="$2" got=""
    shift 2
    for _ in $(seq 20); do got=$("$@" 2>&1) && [ "$got" = "$want" ] && { ok "$name"; return; }; sleep 0.5; done
    bad "$name" "want [$want] got [$got]"
}

echo "worker: copying $NAME to $TARGET"
"$WORK/bin/ssh" worker "rm -rf ~/pratico-e2e && mkdir -p ~/pratico-e2e" || { echo "worker: cannot reach $TARGET"; exit 1; }
PATH="$WORK/bin:$PATH" scp -q -F "$WORK/ssh_config" "$TAR" "$TAR.sha256" worker:pratico-e2e/ || exit 1
asuser "cd ~/pratico-e2e && sha256sum -c $NAME.tar.gz.sha256 >/dev/null && tar -xzf $NAME.tar.gz" || { echo "worker: the tarball does not match its SHA-256"; exit 1; }
PAYLOAD="$(asuser 'echo ~')/pratico-e2e/$NAME"
USER_NAME="${TARGET%@*}"
INSTALL_LOG="$WORK/install.log"

# VMs sized for a small host. Nothing from Docker is installed: pratico answers the docker
# CLI's `docker system dial-stdio` itself.
before_install() {
    onhost "mkdir -p /var/lib/pratico && printf 'default_memory = 256\ndefault_cpus = 1\n' >/var/lib/pratico/config.toml"
}
. "$ROOT/e2e/host-checks.sh"
# The menubar's SSH is checked on the Mac's test host: it reads ed25519 and ECDSA keys only.

if [ "${WORKER_KEEP:-1}" = 1 ]; then
    asuser sudo "$PAYLOAD/pratico-daemon" install --yes >>"$INSTALL_LOG" 2>&1 && echo "worker: pratico left installed on $TARGET"
fi
asuser "rm -rf ~/pratico-e2e"
[ "$fail" -eq 0 ] || { echo "install log:"; tail -30 "$INSTALL_LOG"; }
echo "worker: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
