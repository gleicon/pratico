import Foundation

/// What agents can do through MCP (D-48). Reading is open to every container and image;
/// changing a container (exec, stop, remove) only to those an agent made, labeled
/// `dev.pratico.mcp`, so an agent cannot stop or rewrite the user's own containers.
struct MCPTools: Sendable {
    let containers: ContainerService
    let images: ImageService
    let scans: ScanService

    static let label = "dev.pratico.mcp"
    /// A container's egress allowlist (D-51): names, `*.example.com` for subdomains; any
    /// container can carry it, `run` and `start` set it from `egress`.
    static let egressLabel = "dev.pratico.egress.allow"
    /// Output an agent gets back per stream: the last 64 KiB, as a log tail.
    static let outputBytes = 64 * 1024
    static let maxTimeout = 3600

    static let instructions = """
        pratico runs each container in its own lightweight VM on this Mac and scans every image it pulls. \
        Check an image with image_check before running it; use run for a one-off command in a throwaway VM \
        (network off unless asked; with egress, only the names listed), start for a service that keeps running. \
        egress shows where a container connected. exec, stop, and remove act only on containers made through this server.
        """

    static let catalog: [JSON] = [
        tool("status", "pratico's version, running containers, and scanners.", [:], []),
        tool("image_check", "Pull an image if needed and report pratico's scan verdict: blocked or not, findings by severity, exploited (KEV) CVEs, malware, top findings.",
             ["image": str("Image reference, e.g. python:3.13-slim"), "pull": bool("Pull it if it is not here (default true)"),
              "wait_seconds": int("How long to wait for a scan in progress (default 120, at most 600)")], ["image"]),
        tool("image_sbom", "The image's SBOM (needs syft), SPDX or CycloneDX JSON.",
             ["image": str("Image reference or ID"), "format": .object(["type": "string", "enum": ["spdx", "cyclonedx"]])], ["image"]),
        tool("run", "Run one command in a throwaway VM and return its exit code and output; the container is removed after.",
             runProperties.merging(["timeout_seconds": int("Kill it after this long (default 300, at most 3600)")]) { a, _ in a }, ["image"]),
        tool("start", "Start a container that keeps running (a database for tests, a server); returns its ID.",
             runProperties.merging(["name": str("Container name"), "ports": .object(["type": "array", "items": ["type": "string"],
                                    "description": "Published ports, Docker's form: 8080:80, 127.0.0.1:5432:5432/tcp"])]) { a, _ in a }, ["image"]),
        tool("exec", "Run a command in a running container made through this server.",
             ["container": str("Name or ID"), "command": strings("Command and arguments"), "timeout_seconds": int("Default 60, at most 3600")],
             ["container", "command"]),
        tool("egress", "Where a container's connections went: each destination's name and address, and whether pratico refused it (threat feeds, or the container's egress allowlist).",
             ["container": str("Name or ID")], ["container"]),
        tool("logs", "The last lines of a container's output.", ["container": str("Name or ID"), "tail": int("Lines, default 200, at most 5000")], ["container"]),
        tool("list", "Containers, running or not, with image, state, ports, and whether this server made them.", ["all": bool("Include stopped ones (default true)")], []),
        tool("stop", "Stop a container made through this server.", ["container": str("Name or ID")], ["container"]),
        tool("remove", "Remove a container made through this server, with its anonymous volumes.", ["container": str("Name or ID")], ["container"]),
    ]

    static let runProperties: [String: JSON] = [
        "image": str("Image reference"),
        "command": strings("Command and arguments; the image's default when absent"),
        "env": strings("NAME=value pairs"),
        "workdir": str("Working directory in the container"),
        "network": str("none (default), bridge, or a network name"),
        "mounts": .object(["type": "array", "description": "Mac folders to mount", "items": [
            "type": "object", "required": ["host", "container"],
            "properties": ["host": str("Absolute path on the Mac"), "container": str("Absolute path in the container"),
                           "read_only": bool("Default true")],
        ]]),
        "egress": .object(["type": "array", "items": ["type": "string"],
                           "description": "Allowlist: the only names it may reach (pypi.org, *.github.com); with a network, everything else is refused"]),
        "cpus": .object(["type": "number", "description": "vCPUs (default pratico's)"]),
        "memory_mib": int("Memory in MiB (default pratico's)"),
    ]

    private static func tool(_ name: String, _ description: String, _ properties: [String: JSON], _ required: [String]) -> JSON {
        ["name": .string(name), "description": .string(description),
         "inputSchema": ["type": "object", "properties": .object(properties), "required": JSON(required), "additionalProperties": false]]
    }

    private static func str(_ d: String) -> JSON { ["type": "string", "description": .string(d)] }
    private static func bool(_ d: String) -> JSON { ["type": "boolean", "description": .string(d)] }
    private static func int(_ d: String) -> JSON { ["type": "integer", "description": .string(d)] }
    private static func strings(_ d: String) -> JSON { ["type": "array", "items": ["type": "string"], "description": .string(d)] }

    func call(_ name: String, _ args: JSON) throws -> JSON {
        switch name {
        case "status": return status()
        case "image_check": return try imageCheck(args)
        case "image_sbom": return try sbom(args)
        case "run": return try run(args)
        case "start": return try start(args)
        case "exec": return try exec(args)
        case "logs": return try logs(args)
        case "egress": return try egress(args)
        case "list": return list(args)
        case "stop": return try stop(args)
        case "remove": return try remove(args)
        default: throw APIError(400, "no tool \(name)")
        }
    }
}
