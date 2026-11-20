# Agents (MCP)

pratico serves the Model Context Protocol for coding agents: an agent can check an
image before it uses it, run a command in a throwaway VM, and start a service it needs,
on this Mac, with every image scanned and every container in its own VM.

## Turning it on

It is off until `mcp = true` is in `~/.pratico/config.toml` (Settings…), and the daemon
is restarted. The menubar's **Use with agents (MCP)…** then shows the command for Claude
Code:

```sh
claude mcp add --transport http pratico http://127.0.0.1:7728/mcp \
  --header "Authorization: Bearer $(cat ~/.pratico/mcp-token)"
```

Any client of MCP's Streamable HTTP transport works with the same URL and header.
`mcp_port` changes the port. A port already taken stops the daemon with the reason, so
`mcp = true` always means the endpoint is there.

## Security

The token gives whoever holds it what the Docker socket gives: running containers as
you. So:

- The endpoint listens on 127.0.0.1 only.
- Every request needs `Authorization: Bearer <token>`. The token is 32 random bytes in
  `~/.pratico/mcp-token`, readable by you only, made the first time MCP is on.
- A request for another `Host`, or from a web page (`Origin` other than the endpoint's
  own), is refused before the token is read. A browser cannot reach it through DNS
  rebinding or a cross-site request.
- Agents read every container and image, and change only what they made: `exec`,
  `stop`, and `remove` act on containers labeled `dev.pratico.mcp`.
- Images go through the same scan gate as `docker run`: a blocked image does not start.
- `run` has no network unless asked (`"network": "bridge"` or a network name), and Mac
  folders are mounted read-only unless `read_only` is false.

## Tools

| Tool | Does |
|---|---|
| `status` | pratico's version, containers, and installed scanners |
| `image_check` | pulls the image if needed, waits for its scan (up to `wait_seconds`, default 120), and returns the verdict: blocked or not, why, counts by severity, KEV and malware counts, the scanners that ran, and the 25 most serious findings |
| `image_sbom` | the image's SBOM, SPDX or CycloneDX (needs syft; up to 4 MiB) |
| `run` | one command in a new VM; returns the exit code, the last 64 KiB of stdout and stderr, whether `timeout_seconds` (default 300, at most 3600) killed it, its connections (the last 200), and its activity (the newest 500 events: what ran and which process opened each connection); the container is removed |
| `start` | a container that keeps running (`name`, `ports` in `-p` form) |
| `exec` | a command in a running container the agent made |
| `egress` | where a container's connections went (the last 500): each destination's name and address, and whether pratico refused it, and why ([egress](egress.md)) |
| `activity` | what ran in a container, from its VM's [flight recorder](vm.md#flight-recorder): each exec and exit, and each TCP connection with the process that opened it, named and marked refused from the egress record (`limit`, default 500, at most 10,000) |
| `logs` | the last lines of a container's output (`tail`, default 200) |
| `list` | containers with image, state, ports, and whether an agent made them |
| `stop`, `remove` | for containers the agent made |

`run` and `start` take `image`, `command`, `env`, `workdir`, `network`, `mounts`
(`host`, `container`, `read_only`), `egress` (an allowlist of names: with a network,
everything else is refused), `cpus`, and `memory_mib`.

The transport is Streamable HTTP without event streams: each `POST /mcp` gets one JSON
reply, and a `GET` answers 405. Protocol versions 2025-11-25, 2025-06-18, and 2025-03-26.

Example: [examples/09-agents.sh](../examples/09-agents.sh). Decision: SPEC D-48.
