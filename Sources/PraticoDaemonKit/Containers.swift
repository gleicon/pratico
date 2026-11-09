import Foundation
import PraticoCore

/// Label set on every Apple container pratico creates (SPEC FR-27).
public enum PraticoLabel {
    public static let managed = "dev.pratico.docker"
    public static let id = "dev.pratico.id"
}

/// Docker-side metadata persisted per container (SPEC FR-11).
struct ContainerRecord: Codable, Sendable {
    var id: String
    var name: String
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
    /// `container create` arguments without `--network`, kept so a container that never
    /// ran can be recreated with other networks (D-25). nil for older records.
    var createArgs: [String]?

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

/// Docker containers mapped one-to-one onto Apple containers (SPEC FR-10).
///
/// Each running container has a supervisor: a `container start --attach` child process.
/// The Apple runtime reports no exit codes, but that process exits with the container's
/// code, and its stdout/stderr are the container's streams, kept separate.
public final class ContainerService: @unchecked Sendable {
    let runtime: AppleContainer
    let images: ImageService
    let root: URL
    let config: Config
    let events: EventBus
    let networks: NetworkService
    /// Set when the embedded runtime runs containers (docs/design/runtime.md); nil means
    /// Apple's `container` CLI.
    let embedded: EmbeddedContainers?
    let health = HealthMonitor()
    /// Returns why a container may not start (pratico's image scan, D-24), if it may not.
    var startGate: (@Sendable (ContainerRecord) -> String?)?

    private let lock = NSLock()
    private var records: [String: ContainerRecord] = [:]
    private var logs: [String: LogStore] = [:]
    private var supervisors: [String: Process] = [:]
    private var exitWaiters: [String: [@Sendable (Int) -> Void]] = [:]
    private var removeWaiters: [String: [@Sendable (Int) -> Void]] = [:]
    private var attached: [String: [Connection]] = [:]
    private var pauseAgents: [String: PauseAgent] = [:]
    private var pausedVMs: Set<String> = []  // embedded: paused through the shim

    init(runtime: AppleContainer, images: ImageService, root: URL, networks: NetworkService, config: Config = Config(),
         events: EventBus = EventBus(), embedded: EmbeddedContainers? = nil) {
        self.runtime = runtime
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
        if let embedded {
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
                    if ShimClient.read(files.state)?["status"]?.string == "paused" { pausedVMs.insert(id) }
                    log.tailExternalWriter()
                    track(id, pid: pid, log: log, shim: embedded.shim)
                    health.started(rec)
                }
            }
            return
        }
        let live = Dictionary(runtime.containers().compactMap { c in c["id"]?.string.map { ($0, c) } },
                              uniquingKeysWith: { a, _ in a })
        for id in ids {
            guard let data = try? Data(contentsOf: dir(id).appending(path: "config.json")),
                var rec = try? dec.decode(ContainerRecord.self, from: data)
            else { continue }
            guard live[rec.appleId] != nil else {
                // The Apple container vanished while the daemon was down.
                try? FileManager.default.removeItem(at: dir(id))
                continue
            }
            let appleRunning = live[rec.appleId]?["status"]?["state"]?.string == "running"
            if rec.state.running && !appleRunning {
                rec.state.status = "exited"
                rec.state.finishedAt = rec.state.finishedAt ?? Date()
            }
            records[id] = rec
            logs[id] = LogStore(path: dir(id).appending(path: "log"))
            if rec.state.running {
                watch(id)
                health.started(rec)
                networks.started(rec)
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

    private func update(_ id: String, _ change: (inout ContainerRecord) -> Void) {
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
        let host = JSON.object(hostFields)

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

        var args = ["create", "--name", appleId,
                    "-l", "\(PraticoLabel.managed)=1", "-l", "\(PraticoLabel.id)=\(id)"]
        for (k, v) in (body["Labels"]?.object ?? [:]) { args += ["-l", "\(k)=\(v.string ?? "")"] }
        for e in userEnv { args += ["-e", e] }
        if let w = body["WorkingDir"]?.string, !w.isEmpty { args += ["-w", w] }
        if let u = body["User"]?.string, !u.isEmpty { args += ["-u", u] }
        if body["Tty"]?.bool == true { args.append("-t") }
        // Docker limits win; otherwise config.toml defaults apply (D-14).
        if let mem = host["Memory"]?.int, mem > 0 {
            args += ["-m", "\(max(mem / 1_048_576, 1))M"]
        } else {
            args += ["-m", "\(self.config.defaultMemoryMiB)M"]
        }
        if let nano = host["NanoCpus"]?.int, nano > 0 {
            args += ["-c", "\(max((nano + 999_999_999) / 1_000_000_000, 1))"]
        } else {
            args += ["-c", "\(self.config.defaultCPUs)"]
        }
        let mounts = try Self.mounts(host)
        for m in mounts {
            if m.createSource {
                try? FileManager.default.createDirectory(atPath: m.source, withIntermediateDirectories: true)
            }
            args += ["-v", "\(m.source):\(m.destination)\(m.readOnly ? ":ro" : "")"]
        }
        for spec in Self.publishSpecs(host["PortBindings"]) { args += ["-p", spec] }
        if let userEntry {
            args += ["--entrypoint", userEntry[0]]
        }
        args += ["--", ImageRef.normalize(imageRef)]
        if let userEntry {
            args += Array(userEntry.dropFirst()) + cmd
        } else if userCmd != nil {
            args += cmd
        }

        if let embedded {
            // No network until pratico-net (docs/design/runtime.md); say so rather than drop it.
            guard attach.allSatisfy({ $0.0.builtin }) else {
                throw APIError(400, "pratico: custom networks are not on the embedded runtime yet")
            }
            guard host["PortBindings"]?.object?.isEmpty ?? true else {
                throw APIError(400, "pratico: published ports are not on the embedded runtime yet")
            }
            try FileManager.default.createDirectory(at: dir(id), withIntermediateDirectories: true)
            do {
                try embedded.prepareRootfs(image: ImageRef.normalize(imageRef), at: dir(id).appending(path: "rootfs.ext4"))
            } catch {
                try? FileManager.default.removeItem(at: dir(id))
                throw APIError(500, "container create failed: \(error)")
            }
        } else {
            let r = runtime.run(Self.withNetworks(args, attach.map(\.0.appleName)))
            guard r.ok else { throw APIError(500, "container create failed: \(r.errorText)") }
        }

        let rec = ContainerRecord(
            id: id, name: shortName, appleId: appleId, image: imageRef, imageId: ImageService.id(img),
            created: Date(), path: full.first ?? "", args: Array(full.dropFirst()),
            config: .object(config), hostConfig: host,
            endpoints: Dictionary(attach.map { ($0.0.id, $0.1) }, uniquingKeysWith: { a, _ in a }), createArgs: args)
        lock.lock()
        records[id] = rec
        lock.unlock()
        save(rec)
        logs[id] = LogStore(path: dir(id).appending(path: "log"))
        emit(rec, "create")
        return rec
    }

    /// Apple fixes networks at create; `--network` goes right after the name.
    static func withNetworks(_ args: [String], _ appleNames: [String]) -> [String] {
        var a = args
        a.insert(contentsOf: appleNames.flatMap { ["--network", $0] }, at: min(3, a.count))
        return a
    }

    private func uniqueName() -> String {
        for _ in 0..<32 {
            let n = Names.random()
            if (try? resolve(n)) == nil { return n }
        }
        return "pratico_\(randomHexID().prefix(8))"
    }

    /// Docker PortBindings → `container -p [ip:]host:container/proto`. A missing host IP
    /// binds every interface, as Docker does (SPEC FR-13, D-8).
    static func publishSpecs(_ bindings: JSON?) -> [String] {
        var out: [String] = []
        for (port, list) in (bindings?.object ?? [:]).sorted(by: { $0.key < $1.key }) {
            let (num, proto) = port.splitOnce("/")
            for b in list.array ?? [] {
                let hostPort = b["HostPort"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? num
                let ip = b["HostIp"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? "0.0.0.0"
                out.append("\(ip):\(hostPort):\(num)/\(proto ?? "tcp")")
            }
        }
        return out
    }

    struct Mount: Equatable {
        var source: String
        var destination: String
        var readOnly: Bool
        /// `-v` creates a missing host path, as Docker does; `--mount` does not.
        var createSource: Bool
    }

    /// Docker `Binds` (`src:dst[:opts]`) and bind-type `Mounts` (SPEC FR-14). Named
    /// volumes and other mount types are rejected until volumes exist.
    static func mounts(_ host: JSON) throws -> [Mount] {
        var out: [Mount] = []
        for bind in host["Binds"]?.strings ?? [] {
            let parts = bind.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 2 || parts.count == 3, !parts[0].isEmpty, parts[1].hasPrefix("/") else {
                throw APIError(400, "invalid volume specification: '\(bind)'")
            }
            guard parts[0].hasPrefix("/") else {
                throw APIError(400, "named volumes are not supported yet: '\(bind)'")
            }
            let opts = parts.count == 3 ? parts[2].split(separator: ",").map(String.init) : []
            out.append(Mount(source: parts[0], destination: parts[1], readOnly: opts.contains("ro"), createSource: true))
        }
        for m in host["Mounts"]?.array ?? [] {
            let type = m["Type"]?.string ?? "volume"
            guard type == "bind" else { throw APIError(400, "mount type \(type) is not supported yet") }
            guard let src = m["Source"]?.string, src.hasPrefix("/"), let dst = m["Target"]?.string, dst.hasPrefix("/") else {
                throw APIError(400, "invalid mount config: bind mounts need an absolute source and target")
            }
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: src, isDirectory: &isDir) else {
                throw APIError(400, "invalid mount config for type \"bind\": bind source path does not exist: \(src)")
            }
            out.append(Mount(source: src, destination: dst, readOnly: m["ReadOnly"]?.bool ?? false, createSource: false))
        }
        return out
    }

    func mountsJSON(_ rec: ContainerRecord) -> JSON {
        .array(((try? Self.mounts(rec.hostConfig)) ?? []).map { m in
            ["Type": "bind", "Source": .string(m.source), "Destination": .string(m.destination),
             "Mode": .string(m.readOnly ? "ro" : ""), "RW": .bool(!m.readOnly), "Propagation": "rprivate"]
        })
    }

    // MARK: Lifecycle

    func start(_ ref: String) throws -> Bool {
        let rec = try resolve(ref)
        if rec.state.running { return false }
        if let reason = startGate?(rec) { throw APIError(409, reason) }
        try launch(rec)
        return true
    }

    private func launch(_ rec: ContainerRecord) throws {
        if let embedded { return try launchEmbedded(rec, embedded) }
        let anchored = networks.raiseDefaultIfNeeded(rec)
        defer { if anchored { networks.dropAnchor() } }
        let p = runtime.process(["start", "--attach", rec.appleId])
        let out = Pipe()
        let err = Pipe()
        p.standardOutput = out
        p.standardError = err
        do { try p.run() } catch { throw APIError(500, "cannot start container: \(error)") }

        lock.lock()
        supervisors[rec.id] = p
        let log = logs[rec.id] ?? LogStore(path: dir(rec.id).appending(path: "log"))
        logs[rec.id] = log
        lock.unlock()
        update(rec.id) {
            $0.state = ContainerState(status: "running", startedAt: Date())
        }

        let id = rec.id
        let tty = rec.tty
        let group = DispatchGroup()
        for (stream, pipe) in [(UInt8(1), out), (UInt8(2), err)] {
            group.enter()
            Thread.detachNewThread { [self] in
                let h = pipe.fileHandleForReading
                while case let data = h.availableData, !data.isEmpty {
                    log.append(stream: stream, data)
                    broadcast(id, tty ? data : StdCopy.frame(stream: stream, data))
                }
                group.leave()
            }
        }
        Thread.detachNewThread { [self] in
            group.wait()
            p.waitUntilExit()
            finished(id, code: Int(p.terminationStatus))
        }

        // Docker's start returns once the container runs. Without this, a stop that
        // lands while the VM boots is a no-op in the Apple runtime and the VM comes up
        // anyway. Short-lived containers may exit before ever reporting running.
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline && p.isRunning && runtime.state(rec.appleId) != "running" {
            Thread.sleep(forTimeInterval: 0.1)
        }
        if p.isRunning {
            networks.started(rec)
            networks.sync(Set(networks.active(rec).keys), wait: true)
        }
        emit(rec, "start")
        health.started(rec)
    }

    /// Starts the container's shim. Its output reaches attached clients and log followers
    /// through the log file the shim writes.
    private func launchEmbedded(_ rec: ContainerRecord, _ embedded: EmbeddedContainers) throws {
        let files = ShimFiles(dir: dir(rec.id))
        let mounts = try Self.mounts(rec.hostConfig).map { ShimMount(source: $0.source, destination: $0.destination, readOnly: $0.readOnly) }
        let mem = rec.hostConfig["Memory"]?.int.flatMap { $0 > 0 ? Int($0 / 1_048_576) : nil } ?? config.defaultMemoryMiB
        let cpus = rec.hostConfig["NanoCpus"]?.int.flatMap { $0 > 0 ? Int(($0 + 999_999_999) / 1_000_000_000) : nil } ?? config.defaultCPUs
        let rootfs: String = files.dir.appending(path: "rootfs.ext4").path
        let env: [String] = rec.config["Env"]?.strings ?? []
        let workdir: String = rec.config["WorkingDir"]?.string ?? ""
        let user: String = rec.config["User"]?.string ?? ""
        let hostname: String = rec.config["Hostname"]?.string ?? rec.appleId
        let openStdin: Bool = rec.config["OpenStdin"]?.bool ?? false
        let spec = ShimSpec(
            id: rec.appleId, kernel: embedded.kernel, initfs: embedded.initfs, rootfs: rootfs,
            arguments: [rec.path] + rec.args, environment: env, workingDirectory: workdir, user: user,
            tty: rec.tty, openStdin: openStdin, hostname: hostname, cpus: max(cpus, 1), memoryMiB: max(mem, 64),
            mounts: mounts)
        try JSONEncoder().encode(spec).write(to: files.spec, options: .atomic)

        lock.lock()
        let log = logs[rec.id] ?? LogStore(path: files.log)
        logs[rec.id] = log
        lock.unlock()
        log.tailExternalWriter()
        let pid = try embedded.shim.spawn(files)
        update(rec.id) { $0.state = ContainerState(status: "running", startedAt: Date()) }
        track(rec.id, pid: pid, log: log, shim: embedded.shim)
        // The process never ran (bad image config, missing executable): fail the start, as
        // Docker does, instead of reporting a container that exited at once.
        if let status = ShimClient.exitStatus(files), !status.error.isEmpty {
            awaitExit(rec.id, seconds: 5)
            throw Self.startError(status.error, executable: rec.path)
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

    /// Operations still on the CLI backend's guest-agent path; see the runtime roadmap.
    func requireCLIBackend(_ what: String) throws {
        if embedded != nil { throw APIError(501, "pratico: \(what) is not on the embedded runtime yet") }
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

    /// Container running but started by a previous daemon: poll until it stops.
    /// Its exit code is unknown to the Apple runtime, so it is reported as 0.
    private func watch(_ id: String) {
        Thread.detachNewThread { [self] in
            while true {
                Thread.sleep(forTimeInterval: 1)
                guard let rec = try? resolve(id), rec.state.running else { return }
                if runtime.state(rec.appleId) != "running" {
                    finished(id, code: 0)
                    return
                }
            }
        }
    }

    private func broadcast(_ id: String, _ data: Data) {
        lock.lock()
        let conns = attached[id] ?? []
        lock.unlock()
        for c in conns { c.write(data) }
    }

    private func finished(_ id: String, code: Int) {
        lock.lock()
        supervisors[id] = nil
        pauseAgents.removeValue(forKey: id)?.release()
        let log = logs[id]
        let conns = attached.removeValue(forKey: id) ?? []
        let waiters = exitWaiters.removeValue(forKey: id) ?? []
        let auto = records[id]?.autoRemove ?? false
        lock.unlock()

        log?.finish()
        health.stopped(id)
        networks.stopped(id)
        lock.lock()
        pausedVMs.remove(id)
        lock.unlock()
        update(id) {
            $0.state.status = "exited"
            $0.state.exitCode = code
            $0.state.finishedAt = Date()
        }
        if let rec = try? resolve(id) { networks.sync(Set(networks.active(rec).keys), wait: false) }
        if let rec = try? resolve(id) { emit(rec, "die", ["exitCode": "\(code)"]) }
        for c in conns { c.close() }
        if auto { removeNow(id, code: code) }
        for w in waiters { w(code) }
    }

    /// Waits (bounded) for the supervisor to record the exit.
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
        return pauseAgents[id] != nil || pausedVMs.contains(id)
    }

    func pause(_ ref: String) throws {
        let rec = try resolve(ref)
        guard rec.state.running else { throw APIError(409, "Container \(rec.id) is not running") }
        guard !isPaused(rec.id) else { throw APIError(409, "Container \(rec.id) is already paused") }
        if let embedded {
            // The whole VM pauses: no guest tools, nothing runs until resume.
            try embedded.shim.call(ShimFiles(dir: dir(rec.id)), "POST", "/pause")
            lock.lock()
            pausedVMs.insert(rec.id)
            lock.unlock()
            emit(rec, "pause")
            return
        }
        let agent = try PauseAgent.freeze(rec.appleId, runtime: runtime)
        lock.lock()
        pauseAgents[rec.id] = agent
        lock.unlock()
        emit(rec, "pause")
    }

    func unpause(_ ref: String) throws {
        let rec = try resolve(ref)
        if let embedded {
            lock.lock()
            let paused = pausedVMs.contains(rec.id)
            lock.unlock()
            guard paused else { throw APIError(409, "Container \(rec.id) is not paused") }
            try embedded.shim.call(ShimFiles(dir: dir(rec.id)), "POST", "/resume")
            lock.lock()
            pausedVMs.remove(rec.id)
            lock.unlock()
            emit(rec, "unpause")
            return
        }
        lock.lock()
        let agent = pauseAgents.removeValue(forKey: rec.id)
        lock.unlock()
        guard let agent else { throw APIError(409, "Container \(rec.id) is not paused") }
        agent.thaw()
        networks.sync(Set(networks.active(rec).keys), wait: false)  // skipped while frozen
        emit(rec, "unpause")
    }

    /// A frozen container ignores stop and kill, so lifecycle calls thaw it first.
    private func thawIfPaused(_ id: String) {
        lock.lock()
        let agent = pauseAgents.removeValue(forKey: id)
        let vm = pausedVMs.remove(id) != nil
        lock.unlock()
        agent?.thaw()
        if vm, let embedded { try? embedded.shim.call(ShimFiles(dir: dir(id)), "POST", "/resume") }
    }

    func stop(_ ref: String, timeout: Int?) throws -> Bool {
        let rec = try resolve(ref)
        guard rec.state.running else { return false }
        thawIfPaused(rec.id)
        let t = timeout ?? 10
        emit(rec, "kill", ["signal": "15"])
        if let embedded {
            try embedded.shim.call(ShimFiles(dir: dir(rec.id)), "POST", "/stop?t=\(t)")
        } else {
            let r = runtime.run(["stop", "-t", "\(t)", rec.appleId])
            guard r.ok else { throw APIError(500, "cannot stop container: \(r.errorText)") }
        }
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
        if let embedded {
            guard let n = Int(Self.signalNumber(sig)) else { throw APIError(400, "invalid signal: \(sig)") }
            try embedded.shim.call(ShimFiles(dir: dir(rec.id)), "POST", "/kill?signal=\(n)")
        } else {
            let r = runtime.run(["kill", "-s", sig, rec.appleId])
            guard r.ok else { throw APIError(500, "cannot kill container: \(r.errorText)") }
        }
        if ["KILL", "SIGKILL", "9"].contains(sig) { awaitExit(rec.id, seconds: 10) }
    }

    func restart(_ ref: String, timeout: Int?) throws {
        let rec = try resolve(ref)
        if let reason = startGate?(rec) { throw APIError(409, reason) }
        _ = try stop(rec.id, timeout: timeout)
        try launch(try resolve(rec.id))
        emit(rec, "restart")
    }

    func remove(_ ref: String, force: Bool) throws {
        let rec = try resolve(ref)
        if rec.state.running {
            guard force else {
                throw APIError(409, "cannot remove container \"/\(rec.name)\": container is running: stop the container before removing or force remove")
            }
            thawIfPaused(rec.id)
            emit(rec, "kill", ["signal": "9"])
            if let embedded {
                try? embedded.shim.call(ShimFiles(dir: dir(rec.id)), "POST", "/kill?signal=9")
            } else {
                _ = runtime.run(["kill", "-s", "KILL", rec.appleId])
            }
            awaitExit(rec.id, seconds: 10)
        }
        removeNow(rec.id, code: (try? resolve(rec.id))?.state.exitCode ?? 0)
    }

    private func removeNow(_ id: String, code: Int) {
        lock.lock()
        guard let rec = records.removeValue(forKey: id) else { lock.unlock(); return }
        logs[id] = nil
        let waiters = removeWaiters.removeValue(forKey: id) ?? []
        lock.unlock()
        if embedded == nil { _ = runtime.run(["delete", "--force", rec.appleId]) }
        try? FileManager.default.removeItem(at: ShimFiles(dir: dir(id)).socket)
        try? FileManager.default.removeItem(at: dir(id))  // embedded: rootfs and shim files too
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
        if stdin, rec.config["OpenStdin"]?.bool == true, let embedded { pumpStdin(rec, conn, embedded) }
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
        guard let embedded, rec.state.running, height > 0, width > 0 else { return }
        try? embedded.shim.call(ShimFiles(dir: dir(rec.id)), "POST", "/resize?h=\(height)&w=\(width)")
    }

    /// One healthcheck probe: through the shim's agent on the embedded runtime.
    func healthProbe(_ rec: ContainerRecord, _ check: HealthConfig) -> HealthState.Probe {
        guard let embedded else { return HealthMonitor.probe(runtime, appleId: rec.appleId, check: check) }
        let start = Date()
        let body: JSON = ["args": JSON(check.command), "timeout": .int(Int64(max(check.timeout.rounded(.up), 1)))]
        do {
            let r = try embedded.shim.request(ShimFiles(dir: dir(rec.id)), "POST", "/exec", body: body.encoded())
            let j = JSON.parse(r.body) ?? [:]
            return .init(start: start, end: Date(), exitCode: Int(j["exitCode"]?.int ?? -1), output: j["output"]?.string ?? "")
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

    // MARK: Networks

    /// `POST /networks/{id}/connect`. Apple fixes a container's networks at create, so a
    /// container that never ran is recreated on the new set; one that has run can only
    /// rejoin a network it was disconnected from, whose interface it still has (D-25).
    func connect(_ ref: String, to net: NetworkRecord, aliases: [String]) throws {
        let rec = try resolve(ref)
        var eps = networks.endpoints(rec)
        if let ep = eps[net.id], !ep.detached {
            throw APIError(403, "endpoint with name \(rec.name) already exists in network \(net.name)")
        }
        let onNone = networks.active(rec).keys.contains { (try? networks.resolve($0))?.name == "none" }
        if net.name == "none" || onNone {
            throw APIError(400, "container cannot be connected to network none and other networks")
        }
        if let ep = eps[net.id] {
            eps[net.id] = Endpoint(aliases: aliases.isEmpty ? ep.aliases : aliases)
            update(rec.id) { $0.endpoints = eps }
        } else if rec.state.startedAt == nil {
            eps[net.id] = Endpoint(aliases: aliases)
            try recreate(rec, eps)
        } else {
            throw APIError(409, "pratico: cannot connect \(rec.name) to \(net.name): the Apple runtime fixes a container's networks when it is created, and this container has already run; recreate it with --network \(net.name)")
        }
        networks.emit(net, "connect", container: rec.id)
        networks.sync([net.id], wait: true)
    }

    /// `POST /networks/{id}/disconnect`. A container that has run keeps its interface
    /// (the guest cannot bring it down), but leaves Docker's view and name resolution.
    func disconnect(_ ref: String, from net: NetworkRecord) throws {
        let rec = try resolve(ref)
        var eps = networks.endpoints(rec)
        guard let ep = eps[net.id], !ep.detached else {
            throw APIError(403, "container \(rec.id) is not connected to network \(net.name)")
        }
        if rec.state.startedAt == nil {
            eps[net.id] = nil
            try recreate(rec, eps)
        } else {
            eps[net.id] = Endpoint(aliases: ep.aliases, detached: true)
            update(rec.id) { $0.endpoints = eps }
        }
        networks.emit(net, "disconnect", container: rec.id)
        networks.sync([net.id], wait: true)
    }

    /// Replaces a never-started Apple container with one on other networks. Nothing is
    /// lost: its filesystem is still the image's.
    private func recreate(_ rec: ContainerRecord, _ eps: [String: Endpoint]) throws {
        guard let base = rec.createArgs else {
            throw APIError(409, "pratico: container \(rec.name) predates network support; recreate it")
        }
        _ = runtime.run(["delete", "--force", rec.appleId])
        let r = runtime.run(Self.withNetworks(base, appleNetworks(rec, eps)))
        guard r.ok else {
            _ = runtime.run(Self.withNetworks(base, appleNetworks(rec, networks.endpoints(rec))))
            throw APIError(500, "cannot change the networks of \(rec.name): \(r.errorText)")
        }
        update(rec.id) { $0.endpoints = eps }
    }

    /// Apple network names, `NetworkMode` first; no networks at all means Apple's `none`.
    private func appleNetworks(_ rec: ContainerRecord, _ eps: [String: Endpoint]) -> [String] {
        let nets = eps.keys.compactMap { try? networks.resolve($0) }
        guard !nets.isEmpty else { return ["none"] }
        let mode = rec.hostConfig["NetworkMode"]?.string ?? ""
        func primary(_ n: NetworkRecord) -> Bool { n.name == mode || n.id == mode }
        return nets.sorted { primary($0) != primary($1) ? primary($0) : $0.name < $1.name }.map(\.appleName)
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

    func ports(_ rec: ContainerRecord) -> [JSON] {
        var out: [JSON] = []
        for (port, list) in (rec.hostConfig["PortBindings"]?.object ?? [:]).sorted(by: { $0.key < $1.key }) {
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
        for (port, list) in rec.hostConfig["PortBindings"]?.object ?? [:] { portMap[port] = list }
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

/// Pause via the guest's cgroup2 freezer (SPEC FR-12.a, D-15). The Apple runtime has no
/// pause, and a new exec joins PID 1's cgroup, so it would freeze with the container.
/// Instead an agent exec, started before the freeze, moves itself to the namespace root,
/// moves every other process into `pratico/`, freezes that, and holds until its stdin
/// gets a line or closes. If the daemon dies the pipe closes and the container thaws:
/// a frozen VM ignores stop and kill, so paused state must not outlive the daemon.
final class PauseAgent: @unchecked Sendable {
    static let script = """
        r=/sys/fs/cgroup; g=$r/pratico
        mkdir -p $g && echo $$ > $r/cgroup.procs || exit 1
        for i in 1 2 3; do for p in $(cat $r/cgroup.procs); do
          [ "$p" = $$ ] || echo $p > $g/cgroup.procs 2>/dev/null
        done; done
        echo 1 > $g/cgroup.freeze || exit 1
        until grep -q 'frozen 1' $g/cgroup.events; do sleep 0.05; done
        echo paused
        read x
        echo 0 > $g/cgroup.freeze
        echo resumed
        """

    private let process: Process
    private let input: FileHandle
    private let output: FileHandle

    private init(process: Process, input: FileHandle, output: FileHandle) {
        self.process = process
        self.input = input
        self.output = output
    }

    static func freeze(_ appleId: String, runtime: AppleContainer) throws -> PauseAgent {
        let p = runtime.process(["exec", "-i", "-u", "0", appleId, "sh", "-c", script])
        let stdin = Pipe()
        let stdout = Pipe()
        p.standardInput = stdin
        p.standardOutput = stdout
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { throw APIError(500, "cannot pause container: \(error)") }
        let agent = PauseAgent(process: p, input: stdin.fileHandleForWriting, output: stdout.fileHandleForReading)
        guard agent.readLine(timeout: 10) == "paused" else {
            agent.release()
            throw APIError(500, "cannot pause container: the guest freezer is unavailable (the image needs /bin/sh)")
        }
        return agent
    }

    /// Thaws and waits (bounded) for the guest to confirm.
    func thaw() {
        try? input.write(contentsOf: Data("go\n".utf8))
        _ = readLine(timeout: 10)
        release()
    }

    /// Closing stdin thaws the guest; the host exec then exits.
    func release() {
        try? input.close()
        let p = process
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) { if p.isRunning { p.terminate() } }
    }

    private func readLine(timeout: TimeInterval) -> String? {
        let result = Box<String?>(nil)
        let done = DispatchSemaphore(value: 0)
        let h = output
        Thread.detachNewThread {
            var buf = Data()
            while case let d = h.availableData, !d.isEmpty {
                buf.append(d)
                if let nl = buf.firstIndex(of: 0x0A) {
                    result.value = String(decoding: buf[..<nl], as: UTF8.self)
                    break
                }
            }
            done.signal()
        }
        return done.wait(timeout: .now() + timeout) == .success ? result.value : nil
    }
}
