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
    let scans: ScanService
    let disk: DiskService
    /// Registry trust and kept logins.
    let registries: Registries
    let startedAt = Date()
    private var server: HTTPServer?

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
        let registries = Registries(policy: policy, home: home)
        for w in policy.warnings { Pratico.log("pratico-daemon: \(w)") }
        registries.writeState()
        self.registries = registries
        let backend = EmbeddedImageBackend(store: store, content: content, registries: registries)
        self.images = ImageService(backend: backend)
        self.networks = NetworkService(root: home.appending(path: "networks", directoryHint: .isDirectory), events: events)
        self.containers = ContainerService(
            images: images, root: home.appending(path: "containers", directoryHint: .isDirectory),
            networks: networks, config: config, events: events, embedded: embedded, dockerSocket: self.socketPath)
        backend.usedBy = { [containers] in Set(containers.all().map(\.imageId)) }
        self.execs = ExecService(containers: containers)
        self.archives = ArchiveService(containers: containers)
        self.stats = StatsService(containers: containers)
        self.scans = ScanService(home: home, images: images, containers: containers, config: config)
        self.disk = DiskService(home: home, images: images, containers: containers)
        containers.startGate = { [scans] rec in scans.blockReason(imageId: rec.imageId) }
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
        let s = HTTPServer(path: socketPath) { [self] req, conn in handle(req, conn) }
        try s.start()
        server = s
        scans.startBackground()
    }

    public func stop() { server?.stop() }

    // MARK: Routing

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
        // pratico's own endpoints (not Docker's): the menubar's status, and its view of
        // registry trust and logins.
        case ("GET", "pratico") where parts.count == 2 && parts[1] == "status":
            let c = containers.counts
            conn.json(200, ["Version": .string(Pratico.version), "Pid": .int(Int64(getpid())), "StartedAt": .string(startedAt.ISO8601Format()), "Socket": .string(socketPath),
                            "Containers": .int(Int64(c.total)), "ContainersRunning": .int(Int64(c.running))])
            return .keepAlive
        case ("GET", "pratico") where parts.count == 2 && parts[1] == "registries":
            conn.json(200, registries.state)
            return .keepAlive
        case ("DELETE", "pratico") where parts.count == 4 && parts[1] == "registries" && parts[2] == "logins":
            try registries.logout(parts[3].removingPercentEncoding ?? parts[3])
            conn.respond(204)
            return .keepAlive
        case ("GET", "pratico") where parts.count == 3 && parts[1] == "scans" && parts[2] == "summary":
            conn.json(200, scans.summary())
            return .keepAlive
        case ("GET", "pratico") where parts.count == 2 && parts[1] == "scans":
            conn.json(200, scans.results())
            return .keepAlive
        case ("POST", "pratico") where parts.count == 2 && parts[1] == "scans":
            conn.json(202, scans.rescanAll())
            return .keepAlive
        case ("GET", "pratico") where parts.count == 2 && parts[1] == "scanners":
            conn.json(200, scans.doctor())
            return .keepAlive
        case ("GET", "pratico") where parts.count == 2 && parts[1] == "disk":
            conn.json(200, disk.usage())
            return .keepAlive
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
        case ("POST", "volumes") where parts.count == 2 && parts[1] == "prune":
            conn.json(200, ["VolumesDeleted": [], "SpaceReclaimed": 0])
            return .keepAlive
        case ("GET", "info") where parts.count == 1:
            conn.json(200, info())
            return .keepAlive
        case (_, "containers"):
            if let d = try routeContainers(m, Array(parts.dropFirst()), req, conn) { return d }
        case (_, "exec") where parts.count == 3:
            if let d = try routeExec(m, parts[1], parts[2], req, conn) { return d }
        case (_, "images"):
            if let d = try routeImages(m, Array(parts.dropFirst()), req, conn) { return d }
        case (_, "networks"):
            if let d = try routeNetworks(m, Array(parts.dropFirst()), req, conn) { return d }
        case ("GET", "volumes") where parts.count == 2:
            throw APIError(404, "get \(parts[1]): no such volume")
        case ("GET", "plugins") where parts.count == 3 && parts[2] == "json":
            // No plugin API; a 404 lets `docker inspect` move on to other object types.
            throw APIError(404, "plugin \"\(parts[1])\" not found")
        default:
            break
        }
        conn.error(501, "pratico: endpoint not implemented: \(m) \(req.path)")  // FR-26
        return .keepAlive
    }

    private func routeContainers(_ m: String, _ p: [String], _ req: Request, _ conn: Connection) throws -> Disposition? {
        switch (m, p.count, p.last) {
        case ("GET", 1, "json"):
            let all = req.flag("all")
            conn.json(200, .array(containers.list(all: all, filters: ContainerService.parseFilters(req.query["filters"]))))
        case ("POST", 1, "create"):
            guard let body = JSON.parse(req.body) else { throw APIError(400, "invalid JSON body") }
            let rec = try containers.create(name: req.query["name"], body: body)
            conn.json(201, ["Id": .string(rec.id), "Warnings": []])
        case ("DELETE", 1, _):
            try containers.remove(p[0], force: req.flag("force"))
            conn.respond(204)
        case ("GET", 2, "json"):
            conn.json(200, containers.inspect(try containers.resolve(p[0])))
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
            let stream = req.query["stream"].map { $0 == "1" || $0 == "true" } ?? true
            try stats.stats(p[0], stream: stream, oneShot: req.flag("one-shot"), conn: conn)
        case ("HEAD", 2, "archive"):
            let stat = try archives.stat(p[0], path: req.query["path"] ?? "/")
            conn.respond(200, extra: [("X-Docker-Container-Path-Stat", stat)], headOnly: true)
        case ("GET", 2, "archive"):
            try archives.get(p[0], path: req.query["path"] ?? "/", conn: conn)
        case ("PUT", 2, "archive"):
            try archives.put(p[0], path: req.query["path"] ?? "/", tar: req.body)
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
                try containers.connect(ref, to: net, aliases: body["EndpointConfig"]?["Aliases"]?.strings ?? [])
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
            conn.json(200, .array(images.localImages().map(ImageService.summary)))
        case "POST" where p == ["create"]:
            guard let from = req.query["fromImage"], !from.isEmpty else {
                throw APIError(400, "image import is not supported; use fromImage")
            }
            let ref = ImageRef.join(from, tag: req.query["tag"])
            images.pull(ref, platform: req.query["platform"], auth: RegistryAuth.header(req.headers["x-registry-auth"]), conn: conn)
            scans.enqueue(ref)  // background; the pull reply is already complete
        case "GET" where p == ["get"]:
            // `docker save` of one image; several at once are not supported yet.
            guard let names = req.query["names"], !names.isEmpty else { throw APIError(400, "names is required") }
            try images.save(names, conn: conn)
        case "GET" where p.count >= 2 && p.last == "get":
            try images.save(name, conn: conn)
        case "POST" where p == ["prune"]:
            conn.json(200, images.prune(filters: ContainerService.parseFilters(req.query["filters"])))
        case "GET" where p.count >= 2 && p.last == "json":
            guard let img = images.resolve(name) else { throw APIError(404, "No such image: \(name)") }
            conn.json(200, ImageService.inspect(img.image))
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

