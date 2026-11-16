import Containerization
import ContainerizationOCI
import Foundation
import PraticoCore

/// Docker Remote API daemon: routes requests onto the container and image services.
/// The runtime cannot open: kernel, init, or `pratico-shim` missing or unusable.
public struct RuntimeUnavailable: Error, CustomStringConvertible {
    public var message: String
    public var description: String { "pratico runtime unavailable: \(message)" }
}

public final class Daemon: @unchecked Sendable {
    public let home: URL
    public let socketPath: String
    let images: ImageService
    let containers: ContainerService
    let execs: ExecService
    let archives: ArchiveService
    let stats: StatsService
    let events = EventBus()
    let networks: NetworkService
    let volumes: VolumeService
    let alerts: AlertLog
    let snapshots: SnapshotService
    let containerAlerts: ContainerAlerts
    let scans: ScanService
    let disk: DiskService
    /// Registry trust and kept logins.
    let registries: Registries
    let startedAt = Date()
    private var server: HTTPServer?
    /// The MCP endpoint for agents, when `mcp` is on (D-48).
    private var mcp: MCPServer?

    /// Throws `ConfigError` for unreadable `registry_ca` files and impossible trust
    /// settings: the daemon refuses to start (exit 4) rather than trust less, or more, than
    /// `config.toml` says. Throws `RuntimeUnavailable` when the kernel, init, or shim are
    /// missing (exit 3).
    public init(home: URL, config: Config = Config(), socketPath: String? = nil) throws {
        let policy = try RegistryPolicy.load(config)
        self.home = home
        self.socketPath = socketPath ?? home.appending(path: "docker.sock").path
        let embedded: EmbeddedContainers
        let store: ImageStore
        let content: LocalContentStore
        switch EmbeddedContainers.open(home: home) {
        case .success(let opened): (embedded, store, content) = opened
        case .failure(let error): throw RuntimeUnavailable(message: error.message)
        }
        self.alerts = AlertLog(path: home.appending(path: "alerts.json"))
        let registries = Registries(policy: policy, home: home)
        for w in policy.warnings { Pratico.log("pratico-daemon: \(w)") }
        registries.writeState()
        self.registries = registries
        let backend = EmbeddedImageBackend(store: store, content: content, registries: registries)
        self.images = ImageService(backend: backend, events: events)
        self.networks = NetworkService(root: home.appending(path: "networks", directoryHint: .isDirectory), events: events)
        self.volumes = VolumeService(root: home.appending(path: "volumes", directoryHint: .isDirectory), events: events)
        self.containers = ContainerService(
            images: images, root: home.appending(path: "containers", directoryHint: .isDirectory),
            networks: networks, volumes: volumes, config: config, events: events, embedded: embedded, dockerSocket: self.socketPath)
        backend.usedBy = { [containers] in Set(containers.all().map(\.imageId)) }
        volumes.usedBy = { [containers] in containers.volumeUsers() }
        self.execs = ExecService(containers: containers)
        self.archives = ArchiveService(containers: containers)
        self.stats = StatsService(containers: containers)
        self.scans = ScanService(home: home, images: images, containers: containers, config: config, events: events, alerts: alerts)
        self.containerAlerts = ContainerAlerts(alerts: alerts, containers: containers, events: events)
        self.snapshots = SnapshotService(dir: home.appending(path: "snapshots", directoryHint: .isDirectory),
                                         containers: containers, networks: networks, volumes: volumes)
        self.disk = DiskService(home: home, images: images, containers: containers, volumes: volumes)
        containers.startGate = { [scans] rec in scans.blockReason(imageId: rec.imageId) }
        // An image's unpacked copy goes with it.
        _ = events.subscribe(since: nil) { [embedded = containers.embedded] e in
            if e.type == "image" && e.action == "delete" { embedded.dropRootfsCache(imageId: e.id) }
            return true
        }
    }

    public func start() throws {
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        // Container data is rebuildable and large; keep it out of Time Machine (FR-39).
        for name in ["store", "containers"] {
            var dir = home.appending(path: name, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try dir.setResourceValues(values)
        }
        Uplink.raiseDescriptorLimit()  // pratico-net holds a socket per container connection
        try networks.startSwitch()  // pratico-net
        let s = HTTPServer(path: socketPath, spool: Self.streamsBody) { [self] req, conn in handle(req, conn) }
        try s.start()
        server = s
        scans.startBackground()
        containers.embedded.sweepRootfsCache(keeping: Set(images.localImages().map(\.id)))
        // Restart policies: what `always` and `unless-stopped` keep up comes back, VMs
        // booting in the background while the API already answers.
        Thread.detachNewThread { [containers] in containers.restarts.daemonStarted() }
        if containers.config.mcp { try startMCP() }
    }

    /// A port already taken stops the daemon with the reason, as an unreadable CA does:
    /// `mcp = true` must mean the endpoint is there.
    private func startMCP() throws {
        let token = try MCPServer.token(home: home)
        let tools = MCPTools(containers: containers, images: images, scans: scans)
        let m = MCPServer(port: UInt16(containers.config.mcpPort), token: token, tools: tools)
        try m.start()
        mcp = m
        Pratico.log("pratico-daemon: MCP on http://127.0.0.1:\(m.port)/mcp (token in \(home.appending(path: "mcp-token").path))")
    }

    public func stop() {
        server?.stop()
        mcp?.stop()
    }

    // MARK: Routing

    /// Routes whose bodies can be larger than memory (NFR-4's streamed tar and image bodies):
    /// `docker cp` into a container and `docker load`. They are spooled to a file.
    @Sendable static func streamsBody(_ method: String, _ path: String) -> Bool {
        (method == "PUT" && path.hasPrefix("/containers/") && path.hasSuffix("/archive"))
            || (method == "POST" && path == "/images/load")
    }

    func handle(_ req: Request, _ conn: Connection) -> Disposition {
        do {
            return try route(req, conn)
        } catch let e as APIError {
            fail(req, conn, e.status, e.message)
        } catch {
            fail(req, conn, 500, "\(error)")
        }
        return .keepAlive
    }

    /// Docker JSON error; a reply to HEAD carries headers only (a body would be read as
    /// the next response on a kept-alive connection).
    private func fail(_ req: Request, _ conn: Connection, _ status: Int, _ message: String) {
        if req.method == "HEAD" {
            conn.respond(status, body: (["message": .string(message)] as JSON).encoded(), headOnly: true)
        } else {
            conn.error(status, message)
        }
    }

    private func route(_ req: Request, _ conn: Connection) throws -> Disposition {
        try DockerAPI.accept(req.apiVersion)
        let parts = req.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        let m = req.method

        switch (m, parts.first) {
        case ("GET", "_ping"), ("HEAD", "_ping"):
            conn.respond(200, body: Data("OK".utf8), contentType: "text/plain; charset=utf-8",
                         extra: [("OSType", "linux"), ("Docker-Experimental", "false"),
                                 ("Cache-Control", "no-cache, no-store, must-revalidate"), ("Pragma", "no-cache")],
                         headOnly: m == "HEAD")
            return .keepAlive
        case ("GET", "version") where parts.count == 1:
            conn.json(200, version())
            return .keepAlive
        case ("GET", "events") where parts.count == 1:
            events.serve(req, conn: conn)
            return .close
        case ("POST", "auth") where parts.count == 1:
            guard let body = JSON.parse(req.body), let auth = RegistryAuth.body(body) else {
                throw APIError(400, "username and password are required")
            }
            try images.backend.login(auth)
            conn.json(200, ["Status": "Login Succeeded", "IdentityToken": ""])
            return .keepAlive
        // pratico's own endpoints, next to Docker's (PraticoAPI.swift).
        case (_, "pratico"):
            if let d = try routePratico(m, Array(parts.dropFirst()), req, conn) { return d }
        case ("GET", "system") where parts.count == 2 && parts[1] == "df":
            conn.json(200, disk.df())
            return .keepAlive
        case ("POST", "containers") where parts.count == 2 && parts[1] == "prune":
            conn.json(200, try disk.pruneContainers(filters: ContainerService.parseFilters(req.query["filters"])))
            return .keepAlive
        // Nothing to prune yet; answering lets `docker system prune` finish.
        case ("POST", "build") where parts.count == 2 && parts[1] == "prune":
            conn.json(200, ["CachesDeleted": [], "SpaceReclaimed": 0])
            return .keepAlive
        case ("GET", "info") where parts.count == 1:
            conn.json(200, info())
            return .keepAlive
        case ("POST", "commit") where parts.count == 1:
            return try commit(req, conn)
        case (_, "containers"):
            let rest = Array(parts.dropFirst())
            if let d = try routeContainers(m, rest, req, conn) ?? routeContainerTools(m, rest, req, conn) { return d }
        case (_, "exec") where parts.count == 3:
            if let d = try routeExec(m, parts[1], parts[2], req, conn) { return d }
        case (_, "images"):
            if let d = try routeImages(m, Array(parts.dropFirst()), req, conn) { return d }
        case (_, "networks"):
            if let d = try routeNetworks(m, Array(parts.dropFirst()), req, conn) { return d }
        case (_, "volumes"):
            if let d = try routeVolumes(m, Array(parts.dropFirst()), req, conn) { return d }
        case ("GET", "plugins") where parts.count == 3 && parts[2] == "json":
            // No plugin API; a 404 lets `docker inspect` move on to other object types.
            throw APIError(404, "plugin \"\(parts[1])\" not found")
        default:
            break
        }
        conn.error(501, "pratico: endpoint not implemented: \(m) \(req.path)")  // FR-26
        return .keepAlive
    }

    /// `POST /commit` (D-47).
    private func commit(_ req: Request, _ conn: Connection) throws -> Disposition {
        guard let container = req.query["container"], !container.isEmpty else { throw APIError(400, "container is required") }
        let request = ContainerService.CommitRequest(
            repo: req.query["repo"] ?? "", tag: req.query["tag"] ?? "", comment: req.query["comment"] ?? "",
            author: req.query["author"] ?? "", pause: req.query["pause"].map { !["0", "false"].contains($0) } ?? true,
            changes: req.queryAll["changes"] ?? [], config: JSON.parse(req.body) ?? [:])
        let id = try containers.commit(container, request)
        scans.enqueue(id)  // a new image is scanned like a pulled one
        conn.json(201, ["Id": .string(id)])
        return .keepAlive
    }

    /// rename, top, export, diff, update (D-46).
    private func routeContainerTools(_ m: String, _ p: [String], _ req: Request, _ conn: Connection) throws -> Disposition? {
        guard p.count == 2 else { return nil }
        switch (m, p[1]) {
        case ("POST", "rename"):
            try containers.rename(p[0], to: req.query["name"] ?? "")
            conn.respond(204)
        case ("GET", "top"):
            conn.json(200, try containers.top(p[0], psArgs: req.query["ps_args"]))
        case ("GET", "export"):
            try containers.export(p[0], conn: conn)
        case ("GET", "changes"):
            conn.json(200, .array(try containers.changes(p[0])))
        case ("POST", "update"):
            guard let body = JSON.parse(req.body) else { throw APIError(400, "invalid JSON body") }
            conn.json(200, try containers.update(p[0], body))
        default:
            return nil
        }
        return .keepAlive
    }

    private func routeContainers(_ m: String, _ p: [String], _ req: Request, _ conn: Connection) throws -> Disposition? {
        switch (m, p.count, p.last) {
        case ("GET", 1, "json"):
            let list = containers.list(all: req.flag("all"), filters: ContainerService.parseFilters(req.query["filters"]))
            conn.json(200, .array(req.flag("size") ? disk.sized(list) : list))
        case ("POST", 1, "create"):
            guard let body = JSON.parse(req.body) else { throw APIError(400, "invalid JSON body") }
            let rec = try containers.create(name: req.query["name"], body: body)
            conn.json(201, ["Id": .string(rec.id), "Warnings": []])
        case ("DELETE", 1, _):
            try containers.remove(p[0], force: req.flag("force"), volumes: req.flag("v"))
            conn.respond(204)
        case ("GET", 2, "json"):
            let view = containers.inspect(try containers.resolve(p[0]))
            conn.json(200, req.flag("size") ? disk.sized([view])[0] : view)
        case ("POST", 2, "start"):
            conn.respond(try containers.start(p[0]) ? 204 : 304)
            stats.wake()
        case ("POST", 2, "stop"):
            conn.respond(try containers.stop(p[0], timeout: req.query["t"].flatMap(Int.init)) ? 204 : 304)
        case ("POST", 2, "restart"):
            try containers.restart(p[0], timeout: req.query["t"].flatMap(Int.init))
            conn.respond(204)
        case ("POST", 2, "kill"):
            try containers.kill(p[0], signal: req.query["signal"])
            conn.respond(204)
        case ("POST", 2, "pause"):
            try containers.pause(p[0])
            conn.respond(204)
        case ("POST", 2, "unpause"):
            try containers.unpause(p[0])
            conn.respond(204)
        case ("POST", 2, "exec"):
            guard let body = JSON.parse(req.body) else { throw APIError(400, "invalid JSON body") }
            conn.json(201, ["Id": .string(try execs.create(p[0], body: body).id)])
        case ("GET", 2, "stats"):
            let stream = req.query["stream"].map(Filters.isTrue) ?? true
            try stats.stats(p[0], stream: stream, oneShot: req.flag("one-shot"), conn: conn)
        case ("HEAD", 2, "archive"):
            let stat = try archives.stat(p[0], path: req.query["path"] ?? "/")
            conn.respond(200, extra: [("X-Docker-Container-Path-Stat", stat)], headOnly: true)
        case ("GET", 2, "archive"):
            try archives.get(p[0], path: req.query["path"] ?? "/", conn: conn)
        case ("PUT", 2, "archive"):
            guard let file = req.bodyFile else { throw APIError(400, "no archive in the request") }
            try archives.put(p[0], path: req.query["path"] ?? "/", tar: file)
            conn.respond(200, body: Data())
        case ("POST", 2, "wait"):
            try containers.wait(p[0], condition: req.query["condition"] ?? "not-running", conn: conn)
            return .detached
        case ("POST", 2, "attach"):
            try containers.attach(p[0], stdin: req.flag("stdin"), conn: conn)
            return .detached
        case ("GET", 2, "logs"):
            try containers.logs(p[0], query: req, conn: conn)
        case ("POST", 2, "resize"):
            try containers.resize(p[0], height: req.query["h"].flatMap(Int.init) ?? 0, width: req.query["w"].flatMap(Int.init) ?? 0)
            conn.respond(200, body: Data())
        default:
            return nil
        }
        return .keepAlive
    }

    private func routeVolumes(_ m: String, _ p: [String], _ req: Request, _ conn: Connection) throws -> Disposition? {
        let filters = ContainerService.parseFilters(req.query["filters"])
        switch (m, p.count, p.first) {
        case ("GET", 0, _):
            conn.json(200, volumes.list(filters: filters))
        case ("POST", 1, "create"):
            guard let body = JSON.parse(req.body) else { throw APIError(400, "invalid JSON body") }
            conn.json(201, volumes.json(try volumes.create(body)))
        case ("POST", 1, "prune"):
            conn.json(200, volumes.prune(filters: filters))
        case ("GET", 1, let name?):
            conn.json(200, volumes.json(try volumes.resolve(name)))
        case ("DELETE", 1, let name?):
            try volumes.remove(name, force: req.flag("force"))
            conn.respond(204)
        default:
            return nil
        }
        return .keepAlive
    }

    private func routeNetworks(_ m: String, _ p: [String], _ req: Request, _ conn: Connection) throws -> Disposition? {
        let filters = ContainerService.parseFilters(req.query["filters"])
        switch (m, p.count, p.last) {
        case ("GET", 0, _):
            conn.json(200, .array(networks.list(filters: filters)))
        case ("POST", 1, "create"):
            guard let body = JSON.parse(req.body) else { throw APIError(400, "invalid JSON body") }
            conn.json(201, ["Id": .string(try networks.create(body).id), "Warning": ""])
        case ("POST", 1, "prune"):
            conn.json(200, networks.prune(filters: filters))
        case ("GET", 1, _):
            conn.json(200, networks.json(try networks.resolve(p[0]), withContainers: true))
        case ("DELETE", 1, _):
            try networks.remove(p[0])
            conn.respond(204)
        case ("POST", 2, "connect"), ("POST", 2, "disconnect"):
            let net = try networks.resolve(p[0])
            guard let body = JSON.parse(req.body), let ref = body["Container"]?.string, !ref.isEmpty else {
                throw APIError(400, "container is required")
            }
            if p[1] == "connect" {
                try containers.connect(ref, to: net, endpoint: Endpoint.parse(body["EndpointConfig"]))
            } else {
                try containers.disconnect(ref, from: net)
            }
            conn.respond(200, body: Data())
        default:
            return nil
        }
        return .keepAlive
    }

    private func routeExec(_ m: String, _ id: String, _ action: String, _ req: Request, _ conn: Connection) throws -> Disposition? {
        switch (m, action) {
        case ("POST", "start"):
            return try execs.start(id, body: JSON.parse(req.body) ?? [:], conn: conn)
        case ("POST", "resize"):
            try execs.resize(id, height: req.query["h"].flatMap(Int.init) ?? 0, width: req.query["w"].flatMap(Int.init) ?? 0)
            conn.respond(200, body: Data())
        case ("GET", "json"):
            conn.json(200, execs.inspect(try execs.get(id)))
        default:
            return nil
        }
        return .keepAlive
    }

    private func routeImages(_ m: String, _ p: [String], _ req: Request, _ conn: Connection) throws -> Disposition? {
        // Image names contain `/`, so `/images/<name>/<action>` is matched on its ends.
        let name = p.dropLast().joined(separator: "/")
        switch m {
        case "GET" where p == ["json"]:
            conn.json(200, .array(images.list(filters: ContainerService.parseFilters(req.query["filters"]))))
        case "POST" where p == ["create"]:
            guard let from = req.query["fromImage"], !from.isEmpty else {
                throw APIError(400, "image import is not supported; use fromImage")
            }
            let ref = ImageRef.join(from, tag: req.query["tag"])
            images.pull(ref, platform: req.query["platform"], auth: RegistryAuth.header(req.headers["x-registry-auth"]), conn: conn)
            scans.enqueue(ref)  // background; the pull reply is already complete
        case "GET" where p == ["get"]:
            // `docker save a b`: the CLI repeats `names`.
            try images.save(req.queryAll["names"] ?? [], conn: conn)
        case "GET" where p.count >= 2 && p.last == "get":
            try images.save([name], conn: conn)
        case "POST" where p == ["load"]:
            guard let file = req.bodyFile else { throw APIError(400, "no archive in the request") }
            for ref in try images.load(file, quiet: req.flag("quiet"), conn: conn) { scans.enqueue(ref) }
        case "POST" where p == ["prune"]:
            conn.json(200, try images.prune(filters: ContainerService.parseFilters(req.query["filters"])))
        case "GET" where p.count >= 2 && p.last == "json":
            guard let img = images.resolve(name) else { throw APIError(404, "No such image: \(name)") }
            conn.json(200, ImageService.inspect(img.image))
        case "GET" where p.count >= 2 && p.last == "history":
            guard let img = images.resolve(name) else { throw APIError(404, "No such image: \(name)") }
            conn.json(200, .array(ImageService.history(img.image.record, tags: img.image.tags)))
        case "POST" where p.count >= 2 && p.last == "push":
            try images.push(ImageRef.join(name, tag: req.query["tag"]), auth: RegistryAuth.header(req.headers["x-registry-auth"]),
                            conn: conn)
        case "POST" where p.count >= 2 && p.last == "tag":
            try images.tag(name, repo: req.query["repo"] ?? "", tag: req.query["tag"])
            conn.respond(201)
        case "DELETE" where !p.isEmpty:
            conn.json(200, .array(try images.remove(p.joined(separator: "/"), force: req.flag("force"))))
        default:
            return nil
        }
        return .keepAlive
    }

    // MARK: System

    func version() -> JSON {
        [
            "Platform": ["Name": "pratico"],
            "Components": [[
                "Name": "Engine", "Version": .string(DaemonInfo.version),
                "Details": ["ApiVersion": .string(DockerAPI.version), "MinAPIVersion": .string(DockerAPI.minVersion),
                            "Os": "linux", "Arch": "arm64", "Experimental": "false"],
            ]],
            "Version": .string(DaemonInfo.version),
            "ApiVersion": .string(DockerAPI.version),
            "MinAPIVersion": .string(DockerAPI.minVersion),
            "GitCommit": "",
            "GoVersion": "",
            "Os": "linux",
            "Arch": "arm64",
            "KernelVersion": .string(ProcessInfo.processInfo.operatingSystemVersionString),
            "BuildTime": "",
        ]
    }

    func info() -> JSON {
        let c = containers.counts
        let out: JSON = [
            "ID": "pratico",
            "Containers": .int(Int64(c.total)),
            "ContainersRunning": .int(Int64(c.running)),
            "ContainersPaused": .int(Int64(c.paused)),
            "ContainersStopped": .int(Int64(c.total - c.running - c.paused)),
            "Images": .int(Int64(images.localImages().count)),
            "Driver": "pratico",
            "DockerRootDir": .string(home.path),
            "OperatingSystem": "macOS (pratico)",
            "OSType": "linux",
            "Architecture": "aarch64",
            "NCPU": .int(Int64(ProcessInfo.processInfo.activeProcessorCount)),
            "MemTotal": .int(Int64(ProcessInfo.processInfo.physicalMemory)),
            "Name": .string(Host.current().localizedName ?? "pratico"),
            "ServerVersion": .string(DaemonInfo.version),
            "KernelVersion": .string(ProcessInfo.processInfo.operatingSystemVersionString),
            "Swarm": ["LocalNodeState": "inactive", "ControlAvailable": false, "NodeID": "", "NodeAddr": ""],
            "SecurityOptions": [],
            "Labels": [],
            // The CLI prints "Insecure Registries" from this and each warning as WARNING: …
            "RegistryConfig": registries.policy.registryConfig,
            "Warnings": registries.warnings,
        ]
        return out
    }
}

