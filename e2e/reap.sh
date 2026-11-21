# Sourced by the e2e scripts. Shims outlive their daemon, as containers do, so a run killed
# outright (SIGKILL: no EXIT trap) leaves its VMs running, holding their memory, until a
# later VM fails to start. Each run stops those of earlier runs whose daemon is gone.
# Homes are matched by their random basename: $TMPDIR's trailing slash makes the paths in
# argv vary (`T//pratico-e2e.…`).

# reap_stale <home-prefix>: SIGTERM (a `docker stop`) the shims under <prefix>.* homes
# that no daemon serves.
reap_stale() {
    local base="${TMPDIR:-/tmp}" d name
    for d in "${base%/}/$1".*; do
        [ -d "$d" ] || continue
        name="${d##*/}"
        pgrep -f "pratico-daemon --home .*/$name" >/dev/null && continue
        pkill -TERM -f "pratico-shim .*/$name" && echo "stopped VMs left by an earlier run in $d"
    done
    return 0
}

# reap_own <home>: after its daemon has gone, SIGTERM any shim of <home> still running.
reap_own() {
    pkill -TERM -f "pratico-shim .*/${1##*/}" || true
}
