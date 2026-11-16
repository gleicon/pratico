# mcp.py <port> <token> <tool> <json arguments>: one MCP tools/call; prints the
# structuredContent as JSON, or "ERROR <text>" for a tool error.
import json
import sys
import urllib.request

port, token, tool, args = sys.argv[1], sys.argv[2], sys.argv[3], json.loads(sys.argv[4])
body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": tool, "arguments": args}}).encode()
req = urllib.request.Request(f"http://127.0.0.1:{port}/mcp", data=body,
                             headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"})
result = json.load(urllib.request.urlopen(req, timeout=600))["result"]
print("ERROR " + result["content"][0]["text"] if result["isError"] else json.dumps(result["structuredContent"], sort_keys=True))
