# Shared by the examples: talk to pratico's socket, whatever context is active.
# Source it: . "$(dirname "$0")/lib.sh"
set -euo pipefail
SOCK="${PRATICO_SOCK:-$HOME/.pratico/docker.sock}"
export DOCKER_HOST="unix://$SOCK"
[ -S "$SOCK" ] || { echo "pratico is not running: no $SOCK (start it from the menubar)" >&2; exit 1; }
# pratico's own endpoints, next to the Docker API on the same socket.
api() { curl -fsS --unix-socket "$SOCK" "http://pratico$1" "${@:2}"; }
step() { printf '\n== %s\n' "$*"; }
