import Foundation
import PraticoCore

/// Labels marking what pratico created (SPEC FR-27).
public enum PraticoLabel {
    public static let managed = "dev.pratico.docker"
    public static let id = "dev.pratico.id"
}

/// Docker-side metadata persisted per container (SPEC FR-11).
struct ContainerRecord: Codable, Sendable {
    var id: String
    var name: String
    /// The short ID: VM name and default hostname. (Named for the CLI backend it once fed;
    /// kept so stored records still decode.)
    var appleId: String
    var image: String  // as the client asked for it
    var imageId: String
    var created: Date
    var path: String
    var args: [String]
    var config: JSON
    var hostConfig: JSON
    var state = ContainerState()
    /// Network ID → endpoint; nil for records older than networks (on `bridge`).
    var endpoints: [String: Endpoint]?

    var tty: Bool { config["Tty"]?.bool ?? false }
    var autoRemove: Bool { hostConfig["AutoRemove"]?.bool ?? false }
    var labels: [String: String] { config["Labels"]?.object?.compactMapValues(\.string) ?? [:] }
}

struct ContainerState: Codable, Sendable {
    var status = "created"  // created | running | exited
    var exitCode = 0
    var startedAt: Date?
    var finishedAt: Date?
    var error = ""

    var running: Bool { status == "running" }
}

public struct APIError: Error, Sendable {
    public var status: Int
    public var message: String
    public init(_ status: Int, _ message: String) {
        self.status = status
        self.message = message
    }

    static func noContainer(_ ref: String) -> APIError { APIError(404, "No such container: \(ref)") }
}

/// Docker containers, each in its own VM owned by a `pratico-shim` (SPEC FR-10, D-26).
public final class ContainerService: @unchecked Sendable {
    let images: ImageService
    let root: URL
    let config: Config
    let events: EventBus
    let networks: NetworkService
    let volumes: VolumeService
    /// The runtime: kernel, init, and the shim that owns each VM (docs/design/runtime.md).
    let embedded: EmbeddedContainers
    /// The daemon's own API socket: what `-v /var/run/docker.sock:...` gives a container.
    let dockerSocket: String
    let health = HealthMonitor()
    /// Returns why a container may not start (pratico's image scan, D-24), if it may not.
    var startGate: (@Sendable (ContainerRecord) -> String?)?

    private let lock = NSLock()
    private var records: [String: ContainerRecord] = [:]
    private var logs: [String: LogStore] = [:]
    private var exitWaiters: [String: [@Sendable (Int) -> Void]] = [:]
    private var removeWaiters: [String: [@Sendable (Int) -> Void]] = [:]
    private var attached: [String: [Connection]] = [:]
    private var pausedVMs: Set<String> = []
    private var published: [String: [String: [(ip: String, port: String)]]] = [:]  // bound host ports
    /// Serializes network connect and disconnect, which read, check, and write a
    /// container's endpoints and NIC slots.
    let membership = NSLock()

    init(images: ImageService, root: URL, networks: NetworkService, volumes: VolumeService, config: Config = Config(),
         events: EventBus = EventBus(), embedded: EmbeddedContainers, dockerSocket: String = "") {
        self.volumes = volumes
        self.dockerSocket = dockerSocket
        self.embedded = embedded
        self.events = events
        self.networks = networks
        self.config = config
        self.images = images
        self.root = root
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        health.service = self
        networks.containers = self
        load()
    }

    // MARK: Persistence

    private func dir(_ id: String) -> URL { root.appending(path: id, directoryHint: .isDirectory) }

    private func load() {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let ids = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        for id in ids {
            guard let data = try? Data(contentsOf: dir(id).appending(path: "config.json")),
                var rec = try? dec.decode(ContainerRecord.self, from: data)
            else { continue }
            let files = ShimFiles(dir: dir(id))
            let pid = rec.state.running ? ShimClient.livePid(files) : nil
            if rec.state.running && pid == nil {
                // Exited while the daemon was down; the shim recorded how.
                let status = ShimClient.exitStatus(files)
                rec.state.status = "exited"
                rec.state.exitCode = status?.code ?? 0
                rec.state.error = status?.error ?? ""
                rec.state.finishedAt = status?.finishedAt ?? Date()
                save(rec)
            }
            records[id] = rec
            let log = LogStore(path: files.log)
            logs[id] = log
            if let pid {
                if let data = try? Data(contentsOf: files.spec), let spec = try? JSONDecoder().decode(ShimSpec.self, from: data) {
                    networks.attach(rec, spec.nics)
                    // The daemon's listeners died with it; bind them again.
                    if let ports = try? networks.publish(rec, spec.nics) { published[id] = ports }
                }
                if ShimClient.read(files.state)?["status"]?.string == "paused" { pausedVMs.insert(id) }
                log.tailExternalWriter()
                track(id, pid: pid, log: log, shim: embedded.shim)
                health.started(rec)
            }
        }
    }

    private func save(_ rec: ContainerRecord) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? FileManager.default.createDirectory(at: dir(rec.id), withIntermediateDirectories: true)
        try? enc.encode(rec).write(to: dir(rec.id).appending(path: "config.json"), options: .atomic)
    }

    func update(_ id: String, _ change: (inout ContainerRecord) -> Void) {
        lock.lock()
        guard var rec = records[id] else { lock.unlock(); return }
        change(&rec)
        records[id] = rec
        lock.unlock()
        save(rec)
    }

    // MARK: Lookup

    /// Resolves a full ID, unique ID prefix, or name (with or without leading `/`).
    func resolve(_ ref: String) throws -> ContainerRecord {
        let name = ref.hasPrefix("/") ? String(ref.dropFirst()) : ref
        lock.lock()
        defer { lock.unlock() }
        if let r = records[ref] { return r }
        if let r = records.values.first(where: { $0.name == name }) { return r }
        let matches = records.values.filter { $0.id.hasPrefix(ref) }
        if matches.count == 1 { return matches[0] }
        if matches.count > 1 { throw APIError(400, "multiple containers match prefix \(ref)") }
        throw APIError.noContainer(ref)
    }

    func all() -> [ContainerRecord] {
        lock.lock()
        defer { lock.unlock() }
        return records.values.sorted { $0.created > $1.created }
    }

    // MARK: Create

    func create(name requested: String?, body: JSON) throws -> ContainerRecord {
        let name = requested.flatMap { $0.isEmpty ? nil : $0 } ?? uniqueName()
        let shortName = name.hasPrefix("/") ? String(name.dropFirst()) : name
        guard Names.valid(shortName) else {
            throw APIError(400, "Invalid container name (\(shortName)), only [a-zA-Z0-9][a-zA-Z0-9_.-] are allowed")
        }
        if let existing = try? resolve(shortName), existing.name == shortName {
            throw APIError(409, "Conflict. The container name \"/\(shortName)\" is already in use by container \"\(existing.id)\". You have to remove (or rename) that container to be able to reuse that name.")
        }
        guard let imageRef = body["Image"]?.string, !imageRef.isEmpty else { throw APIError(400, "No image specified") }
        guard let img = images.find(imageRef) else {
            throw APIError(404, "No such image: \(ImageRef.familiar(ImageRef.normalize(imageRef)))")
        }

        let id = randomHexID()
        let appleId = String(id.prefix(12))
        let imageConfig = ImageService.config(img)
        let attach = try networks.attachments(host: body["HostConfig"] ?? [:], networking: body["NetworkingConfig"])
        var hostFields = body["HostConfig"]?.object ?? [:]
        if ["", "default"].contains(hostFields["NetworkMode"]?.string ?? "") { hostFields["NetworkMode"] = "bridge" }
        // Paths that want an anonymous volume: the image's `VOLUME`s and a bare `-v /path`,
        // which the Docker CLI sends as `Volumes`, not in `Binds`.
        let wanted = [imageConfig["Volumes"], body["Volumes"]].flatMap { $0?.object.map { Array($0.keys) } ?? [] }
        let host = try namingVolumes(.object(hostFields), imageVolumes: Array(Set(wanted)))

        // Docker merges image defaults into the container config; an explicit
        // Entrypoint resets the image Cmd.
        let userEntry = body["Entrypoint"]?.strings.flatMap { $0.isEmpty ? nil : $0 }
        let userCmd = body["Cmd"]?.strings.flatMap { $0.isEmpty ? nil : $0 }
        let entry = userEntry ?? imageConfig["Entrypoint"]?.strings ?? []
        let cmd = userCmd ?? (userEntry == nil ? imageConfig["Cmd"]?.strings ?? [] : [])
        let imageEnv = imageConfig["Env"]?.strings ?? []
        let userEnv = body["Env"]?.strings ?? []
        let userKeys = Set(userEnv.map { $0.splitOnce("=").0 })
        let env = imageEnv.filter { !userKeys.contains($0.splitOnce("=").0) } + userEnv
        let workdir = body["WorkingDir"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? imageConfig["WorkingDir"]?.string ?? ""
        let full = entry + cmd

        var config = body.object ?? [:]
        config["HostConfig"] = nil
        config["NetworkingConfig"] = nil
        config["Hostname"] = .string(appleId)
        config["Env"] = JSON(env)
        config["Cmd"] = JSON(cmd)
        config["Entrypoint"] = entry.isEmpty ? .null : JSON(entry)
        config["WorkingDir"] = .string(workdir)
        config["Image"] = .string(imageRef)
        config["Labels"] = body["Labels"] ?? [:]
        config["Healthcheck"] = body["Healthcheck"] ?? imageConfig["Healthcheck"]

        // `-v` creates a missing host directory, as Docker does.
        for m in try mounts(host) where m.createSource {
            try? FileManager.default.createDirectory(atPath: m.source, withIntermediateDirectories: true)
        }
        try FileManager.default.createDirectory(at: dir(id), withIntermediateDirectories: true)
        do {
            try embedded.prepareRootfs(image: ImageRef.normalize(imageRef), at: dir(id).appending(path: "rootfs.ext4"))
        } catch {
            try? FileManager.default.removeItem(at: dir(id))
            throw APIError(500, "container create failed: \(error)")
        }

        let rec = ContainerRecord(
            id: id, name: shortName, appleId: appleId, image: imageRef, imageId: ImageService.id(img),
            created: Date(), path: full.first ?? "", args: Array(full.dropFirst()),
            config: .object(config), hostConfig: host,
            endpoints: Dictionary(attach.map { ($0.0.id, $0.1) }, uniquingKeysWith: { a, _ in a }))
        lock.lock()
        records[id] = rec
        lock.unlock()
        save(rec)
        logs[id] = LogStore(path: dir(id).appending(path: "log"))
        emit(rec, "create")
        return rec
    }

    private func uniqueName() -> String {
        for _ in 0..<32 {
            let n = Names.random()
            if (try? resolve(n)) == nil { return n }
        }
        return "pratico_\(randomHexID().prefix(8))"
    }

    // MARK: Lifecycle

    func start(_ ref: String) throws -> Bool {
        let rec = try resolve(ref)
        if rec.state.running { return false }
        if let reason = startGate?(rec) { throw APIError(409, reason) }
        try launch(rec)
        return true
    }

    /// Starts the container's shim. Its output reaches attached clients and log followers
    /// through the log file the shim writes.
    private func launch(_ rec: ContainerRecord) throws {
        let files = ShimFiles(dir: dir(rec.id))
        let mounts = try mounts(rec.hostConfig).map { Self.shimMount($0, dockerSocket: dockerSocket) }
        let mem = rec.hostConfig["Memory"]?.int.flatMap { $0 > 0 ? Int($0 / 1_048_576) : nil } ?? config.defaultMemoryMiB
        let cpus = rec.hostConfig["NanoCpus"]?.int.flatMap { $0 > 0 ? Int(($0 + 999_999_999) / 1_000_000_000) : nil } ?? config.defaultCPUs
        let rootfs: String = files.dir.appending(path: "rootfs.ext4").path
        let env: [String] = rec.config["Env"]?.strings ?? []
        let workdir: String = rec.config["WorkingDir"]?.string ?? ""
        let user: String = rec.config["User"]?.string ?? ""
        let hostname: String = rec.config["Hostname"]?.string ?? rec.appleId
        let openStdin: Bool = rec.config["OpenStdin"]?.bool ?? false
        let nics = try networks.allocateNICs(rec, runDir: files.socket.deletingLastPathComponent())
        var spec = ShimSpec(
            id: rec.appleId, kernel: embedded.kernel, initfs: embedded.initfs, rootfs: rootfs,
            arguments: [rec.path] + rec.args, environment: env, workingDirectory: workdir, user: user,
            tty: rec.tty, openStdin: openStdin, hostname: hostname, cpus: max(cpus, 1), memoryMiB: max(mem, 64),
            mounts: mounts)
        spec.nics = nics
        spec.switchSocket = networks.netSwitch.socketPath ?? ""
        try JSONEncoder().encode(spec).write(to: files.spec, options: .atomic)

        lock.lock()
        let log = logs[rec.id] ?? LogStore(path: files.log)
        logs[rec.id] = log
        lock.unlock()
        log.tailExternalWriter()
        let pid: pid_t
        do { pid = try embedded.shim.spawn(files) } catch {
            networks.stopped(rec.id)
            throw error
        }
        networks.attach(rec, nics)
        do {
            let ports = try networks.publish(rec, nics)
            lock.lock()
            published[rec.id] = ports
            lock.unlock()
        } catch {
            // Docker fails the start when a port cannot be bound; nothing keeps running.
            try? embedded.shim.call(files, "POST", "/kill?signal=9")
            networks.stopped(rec.id)
            throw error
        }
        update(rec.id) { $0.state = ContainerState(status: "running", startedAt: Date()) }
        track(rec.id, pid: pid, log: log, shim: embedded.shim)
        // Networks, ports, and state are in place: now the process runs (Docker's order).
        // One that cannot (bad image config, missing executable) fails the start, as Docker
        // does, instead of reporting a container that exited at once.
        var failure = ShimClient.exitStatus(files)?.error ?? ""
        if failure.isEmpty {
            do { try embedded.shim.call(files, "POST", "/start") } catch let e as APIError { failure = e.message } catch { failure = "\(error)" }
        }
        if !failure.isEmpty {
            awaitExit(rec.id, seconds: 5)
            throw Self.startError(failure, executable: rec.path)
        }
        emit(rec, "start")
        health.started(rec)
    }

    /// Docker's wording for a process that cannot start. The CLI picks `run`'s exit code
    /// from it: "executable file not found" → 127, "permission denied" → 126.
    static func startError(_ error: String, executable: String) -> APIError {
        let e = error.lowercased()
        if e.contains("failed to find target executable") || e.contains("no such file") {
            return APIError(400, "failed to create task for container: exec: \"\(executable)\": executable file not found in $PATH: unknown")
        }
        if e.contains("permission denied") {
            return APIError(400, "failed to create task for container: exec: \"\(executable)\": permission denied: unknown")
        }
        return APIError(500, error)
    }

    /// Relays the shim's output to attached clients and records the exit when it ends.
    private func track(_ id: String, pid: pid_t, log: LogStore, shim: ShimClient) {
        let tty = (try? resolve(id))?.tty ?? false
        log.subscribe { [weak self] line in
            guard let self, let line else { return false }
            self.broadcast(id, tty ? line.data : StdCopy.frame(stream: line.stream, line.data))
            return true
        }
        let done = Box(false)
        Thread.detachNewThread {
            while !done.value {
                log.refresh()
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        shim.onExit(pid) { [weak self] in
            done.value = true
            log.refresh()  // last output reaches attached clients before they are closed
            let status = ShimClient.exitStatus(ShimFiles(dir: log.path.deletingLastPathComponent()))
            if let error = status?.error, !error.isEmpty { self?.update(id) { $0.state.error = error } }
            self?.finished(id, code: status?.code ?? 137)
        }
    }

    /// Docker event attributes: the container's labels plus `image` and `name`.
    func emit(_ rec: ContainerRecord, _ action: String, _ extra: [String: String] = [:]) {
        var attrs = rec.labels
        attrs["image"] = rec.image
        attrs["name"] = rec.name
        attrs.merge(extra) { _, new in new }
        events.emit("container", action, id: rec.id, attributes: attrs)
    }

    static func signalNumber(_ name: String) -> String {
        let n = name.uppercased().replacingOccurrences(of: "SIG", with: "")
        let table = ["HUP": 1, "INT": 2, "QUIT": 3, "KILL": 9, "USR1": 10, "USR2": 12, "TERM": 15, "STOP": 19, "CONT": 18]
        return table[n].map(String.init) ?? name
    }

    private func broadcast(_ id: String, _ data: Data) {
        lock.lock()
        let conns = attached[id] ?? []
        lock.unlock()
        for c in conns { c.write(data) }
    }

    private func finished(_ id: String, code: Int) {
        lock.lock()
        let log = logs[id]
        let conns = attached.removeValue(forKey: id) ?? []
        let waiters = exitWaiters.removeValue(forKey: id) ?? []
        let auto = records[id]?.autoRemove ?? false
        lock.unlock()

        log?.finish()
        health.stopped(id)
        networks.unpublish(id)
        networks.stopped(id)
        lock.lock()
        pausedVMs.remove(id)
        published[id] = nil
        lock.unlock()
        update(id) {
            $0.state.status = "exited"
            $0.state.exitCode = code
            $0.state.finishedAt = Date()
        }
        if let rec = try? resolve(id) { emit(rec, "die", ["exitCode": "\(code)"]) }
        for c in conns { c.close() }
        if auto, let rec = try? resolve(id) {
            removeNow(id, code: code)
            removeAnonymousVolumes(rec)  // `--rm` takes its anonymous volumes, as in Docker
        }
        for w in waiters { w(code) }
    }

    /// Waits (bounded) for the shim's exit to be recorded.
    private func awaitExit(_ id: String, seconds: Double) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            guard let rec = try? resolve(id), rec.state.running else { return }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    // MARK: Pause

    func isPaused(_ id: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return pausedVMs.contains(id)
    }

    func pause(_ ref: String) throws {
        let rec = try resolve(ref)
        guard rec.state.running else { throw APIError(409, "Container \(rec.id) is not running") }
        guard !isPaused(rec.id) else { throw APIError(409, "Container \(rec.id) is already paused") }
        // The whole VM pauses: no guest tools, nothing runs until resume.
        try embedded.shim.call(ShimFiles(dir: dir(rec.id)), "POST", "/pause")
        lock.lock()
        pausedVMs.insert(rec.id)
        lock.unlock()
        emit(rec, "pause")
    }

    func unpause(_ ref: String) throws {
        let rec = try resolve(ref)
        lock.lock()
        let paused = pausedVMs.contains(rec.id)
        lock.unlock()
        guard paused else { throw APIError(409, "Container \(rec.id) is not paused") }
        try embedded.shim.call(ShimFiles(dir: dir(rec.id)), "POST", "/resume")
        lock.lock()
        pausedVMs.remove(rec.id)
        lock.unlock()
        emit(rec, "unpause")
    }

    /// A paused VM ignores stop and kill, so lifecycle calls resume it first.
    private func thawIfPaused(_ id: String) {
        lock.lock()
        let vm = pausedVMs.remove(id) != nil
        lock.unlock()
        if vm { _ = try? embedded.shim.call(ShimFiles(dir: dir(id)), "POST", "/resume") }
    }

    func stop(_ ref: String, timeout: Int?) throws -> Bool {
        let rec = try resolve(ref)
        guard rec.state.running else { return false }
        thawIfPaused(rec.id)
        let t = timeout ?? 10
        emit(rec, "kill", ["signal": "15"])
        try embedded.shim.call(ShimFiles(dir: dir(rec.id)), "POST", "/stop?t=\(t)")
        awaitExit(rec.id, seconds: Double(t) + 10)
        emit(rec, "stop")
        return true
    }

    func kill(_ ref: String, signal: String?) throws {
        let rec = try resolve(ref)
        guard rec.state.running else {
            throw APIError(409, "Cannot kill container: \(ref): Container \(rec.id) is not running")
        }
        let sig = (signal.flatMap { $0.isEmpty ? nil : $0 } ?? "KILL").uppercased()
        thawIfPaused(rec.id)
        emit(rec, "kill", ["signal": Self.signalNumber(sig)])
        guard let n = Int(Self.signalNumber(sig)) else { throw APIError(400, "invalid signal: \(sig)") }
        try embedded.shim.call(ShimFiles(dir: dir(rec.id)), "POST", "/kill?signal=\(n)")
        if ["KILL", "SIGKILL", "9"].contains(sig) { awaitExit(rec.id, seconds: 10) }
    }

    func restart(_ ref: String, timeout: Int?) throws {
        let rec = try resolve(ref)
        if let reason = startGate?(rec) { throw APIError(409, reason) }
        _ = try stop(rec.id, timeout: timeout)
        try launch(try resolve(rec.id))
        emit(rec, "restart")
    }

    func remove(_ ref: String, force: Bool, volumes removeVolumes: Bool = false) throws {
        let rec = try resolve(ref)
        if rec.state.running {
            guard force else {
                throw APIError(409, "cannot remove container \"/\(rec.name)\": container is running: stop the container before removing or force remove")
            }
            thawIfPaused(rec.id)
            emit(rec, "kill", ["signal": "9"])
            _ = try? embedded.shim.call(ShimFiles(dir: dir(rec.id)), "POST", "/kill?signal=9")
            awaitExit(rec.id, seconds: 10)
        }
        removeNow(rec.id, code: (try? resolve(rec.id))?.state.exitCode ?? 0)
        if removeVolumes { removeAnonymousVolumes(rec) }
    }

    private func removeNow(_ id: String, code: Int) {
        lock.lock()
        guard let rec = records.removeValue(forKey: id) else { lock.unlock(); return }
        logs[id] = nil
        let waiters = removeWaiters.removeValue(forKey: id) ?? []
        lock.unlock()
        try? FileManager.default.removeItem(at: ShimFiles(dir: dir(id)).socket)
        try? FileManager.default.removeItem(at: dir(id))  // rootfs and shim files too
        health.removed(id)
        emit(rec, "destroy")
        for w in waiters { w(code) }
    }

    // MARK: Wait, attach, logs

    /// `POST /containers/{id}/wait`. Headers go out at once (the Docker client blocks on
    /// them before starting the container); the result follows when the condition holds.
    func wait(_ ref: String, condition: String, conn: Connection) throws {
        let rec = try resolve(ref)
        let reply: @Sendable (Int) -> Void = { code in
            let body: JSON = ["StatusCode": .int(Int64(code)), "Error": .null]
            conn.chunk(body.encoded() + Data("\n".utf8))
            conn.endChunked()
            conn.close()
        }
        conn.beginChunked()
        lock.lock()
        let current = records[rec.id]
        switch condition {
        case "removed":
            if current == nil {
                lock.unlock()
                reply(rec.state.exitCode)
                return
            }
            removeWaiters[rec.id, default: []].append(reply)
        case "next-exit":
            exitWaiters[rec.id, default: []].append(reply)
        default:  // not-running
            if let current, !current.state.running {
                lock.unlock()
                reply(current.state.exitCode)
                return
            }
            exitWaiters[rec.id, default: []].append(reply)
        }
        lock.unlock()
    }

    func attach(_ ref: String, stdin: Bool, conn: Connection) throws {
        let rec = try resolve(ref)
        conn.hijack(contentType: rec.tty ? "application/vnd.docker.raw-stream" : "application/vnd.docker.multiplexed-stream")
        lock.lock()
        attached[rec.id, default: []].append(conn)
        lock.unlock()
        if stdin, rec.config["OpenStdin"]?.bool == true { pumpStdin(rec, conn, embedded) }
    }

    /// Client keystrokes or piped input into the shim's `/stdin`. The Docker CLI attaches
    /// before it starts the container, so this waits for the shim; until then the input
    /// stays in the socket buffer.
    private func pumpStdin(_ rec: ContainerRecord, _ conn: Connection, _ embedded: EmbeddedContainers) {
        let files = ShimFiles(dir: dir(rec.id))
        let attachedAt = Date()
        Thread.detachNewThread { [weak self] in
            var fd: Int32 = -1
            while fd < 0 {
                if let s = try? embedded.shim.openStream(files, "/stdin") { fd = s; break }
                guard let self, Date().timeIntervalSince(attachedAt) < 120 else { return }
                // Started and already gone: nothing will read stdin.
                if let r = try? self.resolve(rec.id), !r.state.running, let started = r.state.startedAt, started > attachedAt { return }
                Thread.sleep(forTimeInterval: 0.05)
            }
            while let data = conn.readRaw() {
                let sent = data.withUnsafeBytes { buf -> Bool in
                    var off = 0
                    while off < buf.count {
                        let n = write(fd, buf.baseAddress! + off, buf.count - off)
                        if n <= 0 { return false }
                        off += n
                    }
                    return true
                }
                if !sent { break }
            }
            close(fd)  // EOF ends the process's stdin
        }
    }

    func shimFiles(_ id: String) -> ShimFiles { ShimFiles(dir: dir(id)) }

    /// `POST /containers/{id}/resize` for a TTY container.
    func resize(_ ref: String, height: Int, width: Int) throws {
        let rec = try resolve(ref)
        guard rec.state.running, height > 0, width > 0 else { return }
        _ = try? embedded.shim.call(ShimFiles(dir: dir(rec.id)), "POST", "/resize?h=\(height)&w=\(width)")
    }

    /// One healthcheck probe, through the shim's guest agent.
    func healthProbe(_ rec: ContainerRecord, _ check: HealthConfig) -> HealthState.Probe {
        let start = Date()
        let body: JSON = ["args": JSON(check.command), "timeout": .int(Int64(max(check.timeout.rounded(.up), 1)))]
        do {
            let r = try embedded.shim.request(ShimFiles(dir: dir(rec.id)), "POST", "/exec", body: body.encoded())
            let j = JSON.parse(r.body) ?? [:]
            // Docker keeps at most 4 KiB of probe output.
            return .init(start: start, end: Date(), exitCode: Int(j["exitCode"]?.int ?? -1), output: String((j["output"]?.string ?? "").prefix(4096)))
        } catch {
            return .init(start: start, end: Date(), exitCode: -1, output: "\(error)")
        }
    }

    func logs(_ ref: String, query: Request, conn: Connection) throws {
        let rec = try resolve(ref)
        lock.lock()
        let store = logs[rec.id]
        lock.unlock()
        let wantOut = query.flag("stdout")
        let wantErr = query.flag("stderr")
        let stamps = query.flag("timestamps")
        let follow = query.flag("follow") && rec.state.running
        let tail = query.query["tail"].flatMap(Int.init)
        let tty = rec.tty

        @Sendable func encode(_ l: LogLine) -> Data? {
            guard (l.stream == 1 && wantOut) || (l.stream == 2 && wantErr) else { return nil }
            var payload = l.data
            if stamps { payload = Data((Timestamp.format(l.time) + " ").utf8) + payload }
            return tty ? payload : StdCopy.frame(stream: l.stream, payload)
        }

        conn.beginChunked(contentType: tty ? "application/vnd.docker.raw-stream" : "application/vnd.docker.multiplexed-stream")
        guard let store else {
            conn.endChunked()
            return
        }
        let done = DispatchSemaphore(value: 0)
        var past: [LogLine]
        if follow {
            past = store.follow { line in
                guard let line else { done.signal(); return false }
                if let d = encode(line) { return conn.chunk(d) }
                return true
            }
        } else {
            past = store.read()
        }
        past = past.filter { ($0.stream == 1 && wantOut) || ($0.stream == 2 && wantErr) }
        if let tail, tail >= 0 { past = Array(past.suffix(tail)) }
        var batch = Data()
        for l in past { if let d = encode(l) { batch.append(d) } }
        conn.chunk(batch)
        if follow { done.wait() }
        conn.endChunked()
    }

    // MARK: Views

    func dockerState(_ rec: ContainerRecord) -> String {
        rec.state.running && isPaused(rec.id) ? "paused" : rec.state.status
    }

    func statusText(_ rec: ContainerRecord) -> String {
        switch rec.state.status {
        case "running":
            var suffix = ""
            if isPaused(rec.id) {
                suffix = " (Paused)"
            } else if let h = health.state(rec.id) {
                suffix = h.status == "starting" ? " (health: starting)" : " (\(h.status))"
            }
            return "Up \(Timestamp.human(since: rec.state.startedAt))\(suffix)"
        case "exited": return "Exited (\(rec.state.exitCode)) \(Timestamp.human(since: rec.state.finishedAt)) ago"
        default: return "Created"
        }
    }

    /// Bound host ports (`-p 80` gets a free port), else the request.
    private func bindings(_ rec: ContainerRecord) -> [String: JSON] {
        lock.lock()
        let bound = published[rec.id]
        lock.unlock()
        guard let bound, rec.state.running else { return rec.hostConfig["PortBindings"]?.object ?? [:] }
        return bound.mapValues { list in .array(list.map { ["HostIp": .string($0.ip), "HostPort": .string($0.port)] }) }
    }

    func ports(_ rec: ContainerRecord) -> [JSON] {
        var out: [JSON] = []
        for (port, list) in bindings(rec).sorted(by: { $0.key < $1.key }) {
            let (num, proto) = port.splitOnce("/")
            for b in list.array ?? [] {
                let hp = b["HostPort"]?.string.flatMap { Int64($0) } ?? Int64(num) ?? 0
                out.append(["IP": .string(b["HostIp"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? "0.0.0.0"),
                            "PrivatePort": .int(Int64(num) ?? 0), "PublicPort": .int(hp),
                            "Type": .string(proto ?? "tcp")])
            }
        }
        return out
    }

    func summary(_ rec: ContainerRecord) -> JSON {
        [
            "Id": .string(rec.id),
            "Names": [.string("/\(rec.name)")],
            "Image": .string(rec.image),
            "ImageID": .string(rec.imageId),
            "Command": .string(([rec.path] + rec.args).joined(separator: " ")),
            "Created": .int(Int64(rec.created.timeIntervalSince1970)),
            "Ports": .array(ports(rec)),
            "Labels": JSON(rec.labels),
            "State": .string(dockerState(rec)),
            "Status": .string(statusText(rec)),
            "HostConfig": ["NetworkMode": rec.hostConfig["NetworkMode"] ?? "bridge"],
            "NetworkSettings": ["Networks": networks.containerNetworks(rec)],
            "Mounts": mountsJSON(rec),
        ]
    }

    func inspect(_ rec: ContainerRecord) -> JSON {
        let s = rec.state
        var portMap: [String: JSON] = [:]
        for (port, list) in bindings(rec) { portMap[port] = list }
        // Docker's top-level address fields describe the default bridge only.
        let bridge = s.running && networks.active(rec)[networks.bridge.id] != nil
            ? networks.address(rec.id, on: networks.bridge) : nil
        return [
            "Id": .string(rec.id),
            "Created": .string(Timestamp.format(rec.created)),
            "Path": .string(rec.path),
            "Args": JSON(rec.args),
            "State": [
                "Status": .string(dockerState(rec)),
                "Running": .bool(s.running),
                "Paused": .bool(s.running && isPaused(rec.id)),
                "Restarting": false,
                "OOMKilled": false,
                "Dead": false,
                "Pid": 0,
                "ExitCode": .int(Int64(s.exitCode)),
                "Error": .string(s.error),
                "StartedAt": .string(Timestamp.format(s.startedAt)),
                "FinishedAt": .string(Timestamp.format(s.finishedAt)),
                "Health": health.state(rec.id)?.json ?? .null,
            ],
            "Image": .string(rec.imageId),
            "Name": .string("/\(rec.name)"),
            "RestartCount": 0,
            "Driver": "pratico",
            "Platform": "linux",
            "HostConfig": rec.hostConfig,
            "Config": rec.config,
            "Mounts": mountsJSON(rec),
            "NetworkSettings": [
                "IPAddress": .string(bridge?.ip ?? ""),
                "IPPrefixLen": .int(Int64(bridge?.prefix ?? 0)),
                "Gateway": .string(bridge?.gateway ?? ""),
                "MacAddress": .string(bridge?.mac ?? ""),
                "Ports": .object(portMap),
                "Networks": networks.containerNetworks(rec),
            ],
        ]
    }

    /// Docker `filters` query: `{"label":{"a=1":true}}` or the older `{"label":["a=1"]}`.
    static func parseFilters(_ raw: String?) -> [String: [String]] {
        guard let raw, let json = JSON.parse(Data(raw.utf8))?.object else { return [:] }
        return json.mapValues { v in v.object.map { Array($0.keys) } ?? v.strings ?? [] }
    }

    func list(all: Bool, filters: [String: [String]]) -> [JSON] {
        self.all().filter { rec in
            if !all && !rec.state.running && filters["status"] == nil { return false }
            for (key, values) in filters where !values.isEmpty {
                let ok = values.contains { v in
                    switch key {
                    case "label":
                        let (k, val) = v.splitOnce("=")
                        guard let have = rec.labels[k] else { return false }
                        return val == nil || have == val
                    case "name": return rec.name.contains(v.hasPrefix("/") ? String(v.dropFirst()) : v)
                    case "id": return rec.id.hasPrefix(v)
                    case "status": return dockerState(rec) == v
                    case "health": return (health.state(rec.id)?.status ?? "none") == v
                    case "ancestor": return ImageRef.normalize(rec.image) == ImageRef.normalize(v)
                    case "network":
                        return networks.active(rec).keys.contains { id in
                            id.hasPrefix(v) || (try? networks.resolve(id))?.name == v
                        }
                    default: return true
                    }
                }
                if !ok { return false }
            }
            return true
        }.map(summary)
    }

    public var counts: (total: Int, running: Int, paused: Int) {
        let a = all()
        let paused = a.filter { $0.state.running && isPaused($0.id) }.count
        return (a.count, a.filter(\.state.running).count - paused, paused)
    }
}
