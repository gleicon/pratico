#!/usr/bin/env bash
# pratico's MCP endpoint, called the way an agent calls it (mcp = true in config.toml).
. "$(dirname "$0")/lib.sh"
TOKEN_FILE="$(dirname "$SOCK")/mcp-token"
PORT="${PRATICO_MCP_PORT:-7728}"
[ -f "$TOKEN_FILE" ] || { echo "MCP is off: set mcp = true in ~/.pratico/config.toml and restart the daemon" >&2; exit 1; }
TOKEN=$(cat "$TOKEN_FILE")
call() {
    curl -fsS -X POST "http://127.0.0.1:$PORT/mcp" -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
        -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"$1\",\"arguments\":$2}}" |
        python3 -c 'import json,sys; r=json.load(sys.stdin)["result"]; print(r["content"][0]["text"])'
}

step "the tools an agent sees"
curl -fsS -X POST "http://127.0.0.1:$PORT/mcp" -H "Authorization: Bearer $TOKEN" -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' |
    python3 -c 'import json,sys; print(" ".join(t["name"] for t in json.load(sys.stdin)["result"]["tools"]))'

step "is this image safe to use?"
call image_check '{"image":"alpine","wait_seconds":30}' | python3 -c 'import json,sys; r=json.load(sys.stdin); print(r["Name"], r.get("Verdict"), r.get("Reasons"))'

step "a command in a throwaway VM, no network"
call run '{"image":"alpine","command":["sh","-c","uname -r; echo done"]}'

step "a service it keeps, then cleaned up"
call start '{"image":"alpine","command":["sleep","60"],"name":"pratico-example-agent"}'
call exec '{"container":"pratico-example-agent","command":["echo","inside"]}'
call remove '{"container":"pratico-example-agent"}'
