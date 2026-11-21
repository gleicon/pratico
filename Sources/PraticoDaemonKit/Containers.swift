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
    /// Restarts by the restart policy since the last start by hand.
    var restartCount: Int?
    /// `docker stop` or `docker kill`: the restart policy holds off (Docker's
    /// HasBeenManuallyStopped).
    var stoppedByHand: Bool?

    var running: Bool { status == "running" }
}

public struct APIError: Error, Sendable {
    public var status: Int
    public var message: String
    /// A start refused while a change holds the container: worth trying again.
    var busy = false
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
    /// `FromImage` on exec events, with its hashes cached.
    let execOrigin = ExecOrigin()
    /// The runtime: kernel, init, and the shim that owns each VM (docs/design/runtime.md).
    let embedded: EmbeddedContainers
    /// The daemon's own API socket: what `-v /var/run/docker.sock:...` gives a container.
    let dockerSocket: String
    let health = HealthMonitor()
    let restarts = RestartSupervisor()
    /// Returns why a container may not start (pratico's image scan, D-24), if it may not.
    var startGate: (@Sendable (ContainerRecord) -> String?)?

    private let lock = NSLock()
    private var records: [String: ContainerRecord] = [:]
    private var logs: [String: LogStore] = [:]
    private var exitWaiters: [String: [@Sendable (Int) -> Void]] = [:]
    private var removeWaiters: [String: [@Sendable (Int) -> Void]] = [:]
    private var attached: [String: [Connection]] = [:]
    private var pausedVMs: Set<String> = []
    /// Containers whose rootfs (`docker cp`) or limits (`docker update`) are being changed,
    /// with what: no start until it is done.
    private var busy: [String: String] = [:]
    /// Names of containers being created, held until their records exist.
    private var reservedNames: Set<String> = []
    /// Containers between `start` and running: a second start waits its turn, not a second VM.
    private var starting: Set<String> = []
    /// Disk volume → the running container whose VM it is attached to: one at a time (D-49).
    private var diskHolders: [String: String] = [:]
    /// Disk volumes being rewritten on the Mac (`docker cp` into a stopped container): no
    /// VM may attach them meanwhile.
    private var editedDisks: Set<String> = []
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
        restarts.containers = self
        networks.containers = self
        load()
    }

    // MARK: Persistence

    private func dir(_ id: String) -> URL { root.appending(path: id, directoryHint: .isDirectory) }

    private func load() {
        let ids = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        for id in ids {
            guard var rec = Records.read(ContainerRecord.self, from: dir(id).appending(path: "config.json")) else { continue }
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
                // Its disks stay attached to its VM across the daemon's restart.
                for m in (try? mounts(rec.hostConfig)) ?? [] where m.disk { diskHolders[m.volume!] = id }
                log.tailExternalWriter()
                track(id, pid: pid, log: log, shim: embedded.shim)
                health.started(rec)
            }
        }
    }

    private func save(_ rec: ContainerRecord) {
        try? FileManager.default.createDirectory(at: dir(rec.id), withIntermediateDirectories: true)
        try? Records.write(rec, to: dir(rec.id).appending(path: "config.json"))
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
        let name = try reserveName(requested)
        defer { lock.withLock { _ = reservedNames.remove(name) } }
        guard let imageRef = body["Image"]?.string, !imageRef.isEmpty else { throw APIError(400, "No image specified") }
        guard let img = images.find(imageRef) else {
            throw APIError(404, "No such image: \(ImageRef.familiar(ImageRef.normalize(imageRef)))")
        }
        let id = randomHexID()
        let imageConfig = ImageService.config(img)
        let attach = try networks.attachments(host: body["HostConfig"] ?? [:], networking: body["NetworkingConfig"])
        var hostFields = body["HostConfig"]?.object ?? [:]
        if ["", "default"].contains(hostFields["NetworkMode"]?.string ?? "") { hostFields["NetworkMode"] = "bridge" }
        let (config, command) = Self.containerConfig(body, image: imageConfig, imageRef: imageRef, hostname: String(id.prefix(12)))
        guard !command.isEmpty else { throw APIError(400, "no command specified") }

        // Every option is checked before anything is made (D-45).
        let asked = try Self.publishingAll(.object(hostFields), exposed: config["ExposedPorts"])
        _ = try RunOptions.parse(host: asked, config: .object(config), defaultCPUs: self.config.defaultCPUs, defaultMemoryMiB: self.config.defaultMemoryMiB)
        for link in try Self.links(asked, attach.map(\.1)) { _ = try resolve(link.target) }
        // Paths that want an anonymous volume: the image's `VOLUME`s and a bare `-v /path`,
        // which the Docker CLI sends as `Volumes`, not in `Binds`.
        let wanted = [imageConfig["Volumes"], body["Volumes"]].flatMap { $0?.object.map { Array($0.keys) } ?? [] }
        let host = try namingVolumes(asked, imageVolumes: Array(Set(wanted)))
        // Unpacked by a name the store has: the request may name the image by ID.
        guard let stored = images.resolve(imageRef)?.image.refs.first else { throw APIError(404, "No such image: \(imageRef)") }
        try makeRootfs(id, host: host, imageRef: stored)

        let rec = ContainerRecord(
            id: id, name: name, appleId: String(id.prefix(12)), image: imageRef, imageId: ImageService.id(img),
            created: Date(), path: command.first ?? "", args: Array(command.dropFirst()),
            config: .object(config), hostConfig: host,
            endpoints: Dictionary(attach.map { ($0.0.id, $0.1) }, uniquingKeysWith: { a, _ in a }))
        let log = LogStore(path: dir(id).appending(path: "log"))
        lock.withLock {
            precondition(records[id] == nil, "container ID \(id) taken twice")
            records[id] = rec
            logs[id] = log
        }
        save(rec)
        emit(rec, "create")
        return rec
    }

    /// Checks the name and holds it from here until the record exists: creates take a
    /// while (the rootfs is unpacked), and two at once must not both get one name.
    private func reserveName(_ requested: String?) throws -> String {
        let name = requested.flatMap { $0.isEmpty ? nil : $0 } ?? uniqueName()
        let short = name.hasPrefix("/") ? String(name.dropFirst()) : name
        guard Names.valid(short) else {
            throw APIError(400, "Invalid container name (\(short)), only [a-zA-Z0-9][a-zA-Z0-9_.-] are allowed")
        }
        try lock.withLock {
            if let existing = records.values.first(where: { $0.name == short }) {
                throw APIError(409, "Conflict. The container name \"/\(short)\" is already in use by container \"\(existing.id)\". You have to remove (or rename) that container to be able to reuse that name.")
            }
            guard reservedNames.insert(short).inserted else {
                throw APIError(409, "Conflict. The container name \"/\(short)\" is already being created.")
            }
        }
        return short
    }

    /// The container's `Config` and command, with the image's defaults merged as moby's
    /// `merge` does: an Entrypoint left out takes the image's, `[]` clears it, and any
    /// other Entrypoint (`[""]` too, which then means none: `--entrypoint ""`, buildpacks'
    /// lifecycle) replaces it and drops the image's Cmd.
    static func containerConfig(_ body: JSON, image: JSON, imageRef: String, hostname: String) -> (config: [String: JSON], command: [String]) {
        let userEntry = body["Entrypoint"]?.strings
        let userCmd = body["Cmd"]?.strings.flatMap { $0.isEmpty ? nil : $0 }
        let entry: [String], cmd: [String]
        if let userEntry, !userEntry.isEmpty {
            entry = userEntry == [""] ? [] : userEntry
            cmd = userCmd ?? []
        } else {
            entry = userEntry == nil ? image["Entrypoint"]?.strings ?? [] : []
            cmd = userCmd ?? image["Cmd"]?.strings ?? []
        }
        let userEnv = body["Env"]?.strings ?? []
        let userKeys = Set(userEnv.map { $0.splitOnce("=").0 })
        let env = (image["Env"]?.strings ?? []).filter { !userKeys.contains($0.splitOnce("=").0) } + userEnv
        func merged(_ key: String) -> JSON {
            .object((image[key]?.object ?? [:]).merging(body[key]?.object ?? [:]) { _, mine in mine })
        }
        var config = body.object ?? [:]
        config["HostConfig"] = nil
        config["NetworkingConfig"] = nil
        if (body["Hostname"]?.string ?? "").isEmpty { config["Hostname"] = .string(hostname) }
        for key in ["User", "StopSignal"] where (body[key]?.string ?? "").isEmpty {
            config[key] = image[key] ?? .string("")
        }
        config["ExposedPorts"] = merged("ExposedPorts")
        config["Labels"] = merged("Labels")
        config["Env"] = JSON(env)
        config["Cmd"] = JSON(cmd)
        config["Entrypoint"] = entry.isEmpty ? .null : JSON(entry)
        config["WorkingDir"] = .string(body["WorkingDir"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? image["WorkingDir"]?.string ?? "")
        config["Image"] = .string(imageRef)
        config["Healthcheck"] = body["Healthcheck"] ?? image["Healthcheck"]
        return (config, entry + cmd)
    }

    /// The container's directory and root filesystem (a clone of the unpacked image), the
    /// host folders `-v` asks for, and copy-up into new volumes.
    private func makeRootfs(_ id: String, host: JSON, imageRef: String) throws {
        // `-v` creates a missing host directory, as Docker does.
        for m in try mounts(host) where m.createSource && !FileManager.default.fileExists(atPath: m.source) {
            do { try FileManager.default.createDirectory(atPath: m.source, withIntermediateDirectories: true) } catch {
                throw APIError(400, "error while creating mount source path '\(m.source)': \(error.localizedDescription)")
            }
        }
        let rootfs = dir(id).appending(path: "rootfs.ext4")
        do {
            try FileManager.default.createDirectory(at: dir(id), withIntermediateDirectories: true)
            try embedded.prepareRootfs(image: imageRef, at: rootfs)
        } catch {
            try? FileManager.default.removeItem(at: dir(id))
            throw APIError(500, "container create failed: \(error)")
        }
        copyUp(host, rootfs: rootfs)
    }

    private func uniqueName() -> String {
        for _ in 0..<32 {
            let n = Names.random()
            if (try? resolve(n)) == nil { return n }
        }
        return "pratico_\(randomHexID().prefix(8))"
    }

    /// Runs `body` with a stopped container's rootfs, which it may read or replace; the
    /// container cannot start until it returns.
    func whileStopped<T>(_ ref: String, _ body: (ContainerRecord, URL) throws -> T) throws -> T {
        try holding(ref, "a copy into it is in progress") { rec, running in
            guard !running else { throw APIError(409, "container \(rec.name) started or is busy; try again") }
            return try body(rec, dir(rec.id).appending(path: "rootfs.ext4"))
        }
    }

    /// Runs `body` with the container's current record, and whether it runs, while it
    /// cannot start nor be held by another change; `doing` is what a start is told.
    func holding<T>(_ ref: String, _ doing: String, _ body: (ContainerRecord, Bool) throws -> T) throws -> T {
        let id = try resolve(ref).id
        lock.lock()
        guard let rec = records[id], !starting.contains(id), busy[id] == nil else {
            let name = records[id]?.name ?? id
            lock.unlock()
            throw APIError(409, "container \(name) is starting or busy; try again")
        }
        busy[id] = doing
        lock.unlock()
        defer { lock.withLock { _ = busy.removeValue(forKey: id) } }
        return try body(rec, rec.state.running)
    }


    // MARK: Lifecycle

    /// `docker start`: by hand, so the restart policy's count and hold are reset.
    func start(_ ref: String) throws -> Bool {
        let rec = try resolve(ref)
        restarts.cancel(rec.id)
        return try startOnce(rec.id) {
            $0.restartCount = 0
            $0.stoppedByHand = false
        }
    }

    /// A start by the restart policy; see `RestartSupervisor`.
    func restartByPolicy(_ id: String, atDaemonStart: Bool = false) throws {
        guard try startOnce(id, mark: {
            if atDaemonStart { $0.stoppedByHand = false } else { $0.restartCount = ($0.restartCount ?? 0) + 1 }
        }) else { return }
        // A `docker stop` that came while it was starting wins.
        if (try? resolve(id))?.state.stoppedByHand == true && !atDaemonStart { _ = try? stop(id, timeout: nil) }
    }

    /// Starts the container unless it runs or is starting; `mark` updates its state first.
    private func startOnce(_ id: String, mark: (inout ContainerState) -> Void) throws -> Bool {
        lock.lock()
        guard let rec = records[id], !rec.state.running, !starting.contains(id) else {
            lock.unlock()
            return false
        }
        if let doing = busy[id] {
            lock.unlock()
            var e = APIError(409, "container \(rec.name) is busy: \(doing)")
            e.busy = true
            throw e
        }
        starting.insert(id)
        lock.unlock()
        defer { lock.withLock { _ = starting.remove(id) } }
        if let reason = startGate?(rec) { throw APIError(409, reason) }
        update(id) { mark(&$0.state) }
        do { try launch(try resolve(id)) } catch {
            // `--rm` takes a container that could not start, as Docker does; `run` waits on it.
            if rec.autoRemove, (try? resolve(id))?.state.running == false { removeNow(id, code: 125) }
            throw error
        }
        return true
    }

    /// Starts the container's shim. Its output reaches attached clients and log followers
    /// through the log file the shim writes.
    private func launch(_ rec: ContainerRecord) throws {
        let files = ShimFiles(dir: dir(rec.id))
        try claimDisks(rec)
        let (nics, options): (NICSlots, RunOptions)
        do { (nics, options) = try writeSpec(rec, files) } catch {
            releaseDisks(rec.id)
            throw error
        }
        lock.lock()
        let log = LogStore(path: files.log, maxBytes: options.logBytes)
        logs[rec.id] = log
        lock.unlock()
        log.tailExternalWriter()
        let pid: pid_t
        var trace = Trace("start \(rec.appleId)")
        trace.mark("spec written")
        defer { trace.mark("start returned") }
        do { pid = try embedded.shim.spawn(files) } catch {
            networks.stopped(rec.id)
            releaseDisks(rec.id)
            throw error
        }
        trace.mark("shim reported created")
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
        update(rec.id) {
            $0.state = ContainerState(status: "running", startedAt: Date(), restartCount: $0.state.restartCount, stoppedByHand: $0.state.stoppedByHand)
        }
        track(rec.id, pid: pid, log: log, shim: embedded.shim)
        // Networks, ports, and state are in place: now the process runs (Docker's order).
        // One that cannot (bad image config, missing executable) fails the start, as Docker
        // does, instead of reporting a container that exited at once.
        var failure = ShimClient.exitStatus(files)?.error ?? ""
        if failure.isEmpty {
            trace.mark("networks attached, ports published, recorded running")
            do { try embedded.shim.call(files, "POST", "/start") } catch let e as APIError { failure = e.message } catch { failure = "\(error)" }
            trace.mark("shim started the process")
        }
        if !failure.isEmpty {
            awaitExit(rec.id, seconds: 5)
            throw Self.startError(failure, executable: rec.path)
        }
        emit(rec, "start")
        health.started(rec)
    }

    /// Repairs the rootfs if it needs it, plans the networks, and writes `spec.json` for the
    /// shim. Addresses planned are released again on any failure after that.
    private func writeSpec(_ rec: ContainerRecord, _ files: ShimFiles) throws -> (NICSlots, RunOptions) {
        let mounts = try mounts(rec.hostConfig).map { Self.shimMount($0, dockerSocket: dockerSocket) }
        let options = try runOptions(rec)
        let rootfs = files.dir.appending(path: "rootfs.ext4")
        if !RootfsEdit.isClean(rootfs) {
            Pratico.log("pratico-daemon: \(rec.name)'s root filesystem was not unmounted cleanly; rebuilding it from its files")
            do { try rewritingRootfs(rec, written: []) { try RootfsEdit.repair(rootfs) } } catch { throw APIError(500, "cannot repair the root filesystem of \(rec.name): \(error)") }
        }
        let nics = try networks.allocateNICs(rec, runDir: files.socket.deletingLastPathComponent())
        do {
            var spec = ShimSpec(
                id: rec.appleId, kernel: embedded.kernel, initfs: embedded.initfs, rootfs: rootfs.path,
                arguments: [rec.path] + rec.args, environment: rec.config["Env"]?.strings ?? [],
                workingDirectory: rec.config["WorkingDir"]?.string ?? "", user: rec.config["User"]?.string ?? "",
                tty: rec.tty, openStdin: rec.config["OpenStdin"]?.bool ?? false, hostname: rec.config["Hostname"]?.string ?? rec.appleId,
                cpus: options.cpus, memoryMiB: options.memoryMiB, mounts: mounts)
            spec.nics = nics
            spec.options = try resolved(options, rec, nics: nics, rootfs: rootfs)
            spec.switchSocket = networks.netSwitch.socketPath
            try JSONEncoder().encode(spec).write(to: files.spec, options: .atomic)
        } catch {
            networks.stopped(rec.id)
            throw error
        }
        return (nics, options)
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
        let watch = LogWatch(log)
        shim.onExit(pid) { [weak self] in
            watch.cancel()
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
        releaseDisks(id)
        health.stopped(id)
        networks.unpublish(id)
        networks.stopped(id)
        networks.netSwitch.egress.stopped(id)
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
        if !auto, let rec = try? resolve(id) { restarts.exited(rec, code: code) }
    }

    /// Waits, at most `seconds`, for the shim's exit to be recorded.
    private func awaitExit(_ id: String, seconds: Double) {
        // `docker stop -t` comes from the client: bounded here, not asserted.
        let seconds = min(max(seconds, 0), 3600)
        let exited = DispatchSemaphore(value: 0)
        lock.lock()
        guard records[id]?.state.running == true else { lock.unlock(); return }
        exitWaiters[id, default: []].append { _ in exited.signal() }
        lock.unlock()
        _ = exited.wait(timeout: .now() + seconds)
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
        // Also between two runs of a restart policy: the next one is called off.
        restarts.cancel(rec.id)
        update(rec.id) { $0.state.stoppedByHand = true }
        guard rec.state.running else { return false }
        thawIfPaused(rec.id)
        let options = try? runOptions(rec)
        let t = timeout ?? options?.stopTimeout ?? 10
        let signal = Signals.number(options?.stopSignal ?? "TERM") ?? 15
        emit(rec, "kill", ["signal": "\(signal)"])
        try embedded.shim.call(ShimFiles(dir: dir(rec.id)), "POST", "/stop?t=\(t)&signal=\(signal)")
        // -1 waits for the process however long it takes; the call returns within an hour.
        awaitExit(rec.id, seconds: t < 0 ? 3600 : Double(t) + 10)
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
        guard let n = Signals.number(sig) else { throw APIError(400, "invalid signal: \(sig)") }
        // A signal that ends the process counts as a stop by hand; a reload (HUP, USR1) does not.
        if [9, 15, Signals.number((try? runOptions(rec))?.stopSignal ?? "TERM")].contains(n) {
            restarts.cancel(rec.id)
            update(rec.id) { $0.state.stoppedByHand = true }
        }
        emit(rec, "kill", ["signal": "\(n)"])
        try embedded.shim.call(ShimFiles(dir: dir(rec.id)), "POST", "/kill?signal=\(n)")
        if ["KILL", "SIGKILL", "9"].contains(sig) { awaitExit(rec.id, seconds: 10) }
    }

    func restart(_ ref: String, timeout: Int?) throws {
        let rec = try resolve(ref)
        if let reason = startGate?(rec) { throw APIError(409, reason) }
        _ = try stop(rec.id, timeout: timeout)
        _ = try start(rec.id)
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
        restarts.forget(id)
        networks.netSwitch.egress.forget(id)
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
        let window = try LogWindow(since: query.query["since"], until: query.query["until"])
        // Following stops at `until`; one already past is a plain read.
        let follow = query.flag("follow") && rec.state.running && (window.until.map { $0 > Date() } ?? true)
        let tail = query.query["tail"].flatMap(Int.init)
        let tty = rec.tty

        @Sendable func encode(_ l: LogLine) -> Data? {
            guard (l.stream == 1 && wantOut) || (l.stream == 2 && wantErr), window.contains(l.time) else { return nil }
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
        let ended = LogFollowEnd()
        var past: [LogLine]
        if follow {
            past = store.follow { line in
                guard let line, !ended.isSet else { done.signal(); return false }
                if let d = encode(line) { return conn.chunk(d) }
                return true
            }
            if let until = window.until {
                DispatchQueue.global().asyncAfter(wallDeadline: .now() + until.timeIntervalSinceNow) {
                    ended.set()
                    done.signal()
                }
            }
        } else {
            past = store.read()
        }
        past = past.filter { (($0.stream == 1 && wantOut) || ($0.stream == 2 && wantErr)) && window.contains($0.time) }
        if let tail, tail >= 0 { past = Array(past.suffix(tail)) }
        var batch = Data()
        for l in past { if let d = encode(l) { batch.append(d) } }
        conn.chunk(batch)
        if follow { done.wait() }
        conn.endChunked()
    }

    /// Renames the record, checked against every name in use or being created.
    func renameRecord(_ id: String, to name: String) throws -> String {
        guard Names.valid(name) else { throw APIError(400, "Invalid container name (\(name)), only [a-zA-Z0-9][a-zA-Z0-9_.-] are allowed") }
        let old: String = try lock.withLock {
            guard var rec = records[id] else { throw APIError.noContainer(id) }
            if let other = records.values.first(where: { $0.name == name && $0.id != id }) {
                throw APIError(409, "Conflict. The container name \"/\(name)\" is already in use by container \"\(other.id)\". You have to remove (or rename) that container to be able to reuse that name.")
            }
            guard !reservedNames.contains(name) else { throw APIError(409, "Conflict. The container name \"/\(name)\" is already being created.") }
            let old = rec.name
            rec.name = name
            records[id] = rec
            return old
        }
        if let rec = try? resolve(id) { save(rec) }
        return old
    }

    /// Runs `body` with a running container's disk image consistent on the Mac: the guest
    /// flushes its page cache, then its VM pauses until `body` returns (`pause: false`, as
    /// `docker commit --pause=false`, only flushes). A paused container stays paused; a
    /// stopped one cannot start meanwhile.
    func withQuietRootfs<T>(_ ref: String, pause: Bool = true, _ body: (ContainerRecord, URL) throws -> T) throws -> T {
        let rec = try resolve(ref)
        guard rec.state.running else { return try whileStopped(rec.id, body) }
        let files = ShimFiles(dir: dir(rec.id))
        guard pause else {
            try embedded.shim.call(files, "POST", "/sync")
            return try body(rec, files.dir.appending(path: "rootfs.ext4"))
        }
        let pauseHere: Bool = lock.withLock { pausedVMs.insert(rec.id).inserted }
        defer {
            if pauseHere {
                _ = try? embedded.shim.call(files, "POST", "/resume")
                lock.withLock { _ = pausedVMs.remove(rec.id) }
            }
        }
        if pauseHere {
            try embedded.shim.call(files, "POST", "/sync")
            try embedded.shim.call(files, "POST", "/pause")
        }
        return try body(rec, files.dir.appending(path: "rootfs.ext4"))
    }

    /// The container's next exit, watched from now: registered before a start, so a process
    /// that exits at once is not missed.
    func watchNextExit(_ id: String) -> ExitWatch {
        let w = ExitWatch()
        lock.withLock { exitWaiters[id, default: []].append { w.exited($0) } }
        return w
    }

    /// Everything the container's log holds.
    func logLines(_ id: String) -> [LogLine] { lock.withLock { logs[id] }?.read() ?? [] }

    /// Attaches the container's disk volumes to it, made if missing: a disk is one ext4
    /// filesystem and two kernels writing it would corrupt it, so a second running
    /// container is refused; a share (`--opt type=share`) can be mounted by many.
    private func claimDisks(_ rec: ContainerRecord) throws {
        let disks = try mounts(rec.hostConfig).filter(\.disk)
        for m in disks where !FileManager.default.fileExists(atPath: m.source) { try volumes.formatDisk(m.volume!, content: nil) }
        try lock.withLock {
            for m in disks {
                if editedDisks.contains(m.volume!) { throw APIError(409, "volume \(m.volume!) is being written by a copy; try again") }
                if let holder = diskHolders[m.volume!], holder != rec.id, records[holder]?.state.running == true || starting.contains(holder) {
                    let name = records[holder]?.name ?? holder
                    throw APIError(409, "volume \(m.volume!) is a disk attached to running container \(name); a disk volume serves one container at a time. Stop \(name), or create the volume with --opt type=share to share it")
                }
            }
            for m in disks { diskHolders[m.volume!] = rec.id }
        }
    }

    /// Rewrites a stopped container's rootfs with `rewrite`, keeping track of which of its
    /// files are still the image's (`ExecOrigin.carry`); `written` are the paths replaced.
    func rewritingRootfs(_ rec: ContainerRecord, written: Set<String>, _ rewrite: () throws -> Void) throws {
        let dir = dir(rec.id)
        let files = execOrigin.files(container: dir, image: imageRootfs(rec))
        try ExecOrigin.carry(dir.appending(path: "rootfs.ext4"), files: files, written: written, rewrite: rewrite)
    }

    /// The unpacked image a container's rootfs was cloned from.
    func imageRootfs(_ rec: ContainerRecord) -> URL { embedded.rootfsCache.appending(path: "\(rec.imageId.dropFirst(7)).ext4") }

    /// Runs `body` on disk volume `name`'s image while no VM has it attached nor can attach it.
    func editingDisk<T>(_ name: String, _ body: (URL) throws -> T) throws -> T {
        try lock.withLock {
            if let holder = diskHolders[name], records[holder]?.state.running == true || starting.contains(holder) {
                throw APIError(409, "volume \(name) is a disk attached to running container \(records[holder]?.name ?? holder); stop it to copy into the volume")
            }
            guard editedDisks.insert(name).inserted else { throw APIError(409, "volume \(name) is being written by another copy; try again") }
        }
        defer { lock.withLock { _ = editedDisks.remove(name) } }
        return try body(URL(filePath: volumes.diskPath(name)))
    }

    private func releaseDisks(_ id: String) {
        lock.withLock { diskHolders = diskHolders.filter { $0.value != id } }
    }

    /// Host ports bound for the container's published ports while it runs.
    func boundPorts(_ id: String) -> [String: [(ip: String, port: String)]]? {
        lock.withLock { published[id] }
    }
}

/// One exit, waited for with a bound.
final class ExitWatch: @unchecked Sendable {
    private let done = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var code: Int?

    fileprivate func exited(_ code: Int) {
        lock.withLock { self.code = code }
        done.signal()
    }

    /// The exit code, or nil if it did not exit within `seconds`.
    func wait(seconds: Double) -> Int? {
        precondition(seconds > 0 && seconds <= 3600, "exit wait out of bounds")
        guard done.wait(timeout: .now() + seconds) == .success else { return nil }
        return lock.withLock { code }
    }
}

/// Set once a followed log's `until` passes: the follower stops at its next line.
private final class LogFollowEnd: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}
