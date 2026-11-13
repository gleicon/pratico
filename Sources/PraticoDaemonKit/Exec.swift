import Foundation

/// One `docker exec` instance (SPEC FR-17). Lives in memory only, as in Docker.
final class ExecInstance: @unchecked Sendable {
    let id: String
    let containerId: String
    let cmd: [String]
    let tty: Bool
    let attachStdin: Bool
    let attachStdout: Bool
    let attachStderr: Bool
    let env: [String]
    let workdir: String
    let user: String

    let lock = NSLock()
    var running = false
    var started = false
    var exitCode: Int?
    var shim: ShimFiles?  // the shim the exec runs in, once started

    init(id: String, containerId: String, body: JSON) {
        self.id = id
        self.containerId = containerId
        cmd = body["Cmd"]?.strings ?? []
        tty = body["Tty"]?.bool ?? false
        attachStdin = body["AttachStdin"]?.bool ?? false
        attachStdout = body["AttachStdout"]?.bool ?? true
        attachStderr = body["AttachStderr"]?.bool ?? true
        env = body["Env"]?.strings ?? []
        workdir = body["WorkingDir"]?.string ?? ""
        user = body["User"]?.string ?? ""
    }
}

/// The exec API, run by the container's shim through the guest agent.
final class ExecService: @unchecked Sendable {
    let containers: ContainerService
    private let lock = NSLock()
    private var instances: [String: ExecInstance] = [:]

    init(containers: ContainerService) {
        self.containers = containers
    }

    func create(_ ref: String, body: JSON) throws -> ExecInstance {
        let rec = try containers.resolve(ref)
        guard rec.state.running else { throw APIError(409, "Container \(rec.id) is not running") }
        guard !containers.isPaused(rec.id) else {
            throw APIError(409, "Container \(rec.id) is paused, unpause the container before exec")
        }
        guard body["Cmd"]?.strings?.isEmpty == false else { throw APIError(400, "No exec command specified") }
        let e = ExecInstance(id: randomHexID(), containerId: rec.id, body: body)
        lock.lock()
        instances[e.id] = e
        lock.unlock()
        return e
    }

    func get(_ id: String) throws -> ExecInstance {
        lock.lock()
        defer { lock.unlock() }
        if let e = instances[id] { return e }
        throw APIError(404, "No such exec instance: \(id)")
    }

    /// `POST /exec/{id}/start`. Detached: runs and replies 200. Attached: hijacks the
    /// connection, streams output, pumps stdin, and closes when the process exits.
    func start(_ id: String, body: JSON, conn: Connection) throws -> Disposition {
        let e = try get(id)
        e.lock.lock()
        if e.started {
            e.lock.unlock()
            throw APIError(409, "exec \(id) has already been started")
        }
        e.started = true
        e.lock.unlock()
        let rec = try containers.resolve(e.containerId)
        guard rec.state.running else { throw APIError(409, "Container \(rec.id) is not running") }
        return try startInShim(e, rec, body: body, conn)
    }

    /// The shim runs the process and frames its output as Docker does, so the daemon only
    /// splices bytes between the client and the shim, then asks for the exit code.
    private func startInShim(_ e: ExecInstance, _ rec: ContainerRecord, body: JSON, _ conn: Connection) throws -> Disposition {
        let embedded = containers.embedded
        let detach = body["Detach"]?.bool ?? false
        let files = containers.shimFiles(rec.id)
        var req: [String: JSON] = [
            "id": .string(e.id), "args": JSON(e.cmd), "env": JSON(e.env), "workdir": .string(e.workdir),
            "user": .string(e.user), "tty": .bool(e.tty), "stdin": .bool(e.attachStdin && !detach),
            "stdout": .bool(e.attachStdout && !detach), "stderr": .bool(e.attachStderr && !detach),
        ]
        if let size = body["ConsoleSize"]?.array, size.count == 2 {
            req["height"] = size[0]
            req["width"] = size[1]
        }
        let fd = try embedded.shim.openStream(files, "/exec-stream", body: JSON.object(req).encoded())
        e.lock.lock()
        e.running = true
        e.shim = files
        e.lock.unlock()

        let finishFromShim: @Sendable () -> Void = { [self] in
            let status = (try? embedded.shim.request(files, "GET", "/exec-status?id=\(e.id)")).flatMap { JSON.parse($0.body) }
            finish(e, code: Int(status?["exitCode"]?.int ?? 137))
        }
        if detach {
            conn.respond(200)
            Thread.detachNewThread {
                var buf = [UInt8](repeating: 0, count: 65536)
                while Darwin.read(fd, &buf, buf.count) > 0 {}
                close(fd)
                finishFromShim()
            }
            return .keepAlive
        }
        conn.hijack(contentType: e.tty ? "application/vnd.docker.raw-stream" : "application/vnd.docker.multiplexed-stream")
        if e.attachStdin {
            Thread.detachNewThread {
                while let data = conn.readRaw() {
                    let ok = data.withUnsafeBytes { buf -> Bool in
                        var off = 0
                        while off < buf.count {
                            let n = write(fd, buf.baseAddress! + off, buf.count - off)
                            if n <= 0 { return false }
                            off += n
                        }
                        return true
                    }
                    if !ok { return }
                }
                shutdown(fd, SHUT_WR)  // the shim's stdin ends; output keeps flowing
            }
        }
        Thread.detachNewThread {
            var buf = [UInt8](repeating: 0, count: 65536)
            while case let n = Darwin.read(fd, &buf, buf.count), n > 0 {
                if !conn.write(Data(buf[0..<n])) { break }
            }
            close(fd)
            finishFromShim()
            conn.close()
        }
        return .detached
    }

    private func finish(_ e: ExecInstance, code: Int) {
        e.lock.lock()
        e.running = false
        e.exitCode = code
        e.lock.unlock()
    }

    func resize(_ id: String, height: Int, width: Int) throws {
        let e = try get(id)
        e.lock.lock()
        let shim = e.shim
        e.lock.unlock()
        if let shim, height > 0, width > 0 {
            _ = try? containers.embedded.shim.call(shim, "POST", "/exec-resize?id=\(id)&h=\(height)&w=\(width)")
        }
    }

    func inspect(_ e: ExecInstance) -> JSON {
        e.lock.lock()
        defer { e.lock.unlock() }
        return [
            "ID": .string(e.id),
            "Running": .bool(e.running),
            "ExitCode": e.exitCode.map { .int(Int64($0)) } ?? .null,
            "ProcessConfig": [
                "tty": .bool(e.tty), "entrypoint": .string(e.cmd.first ?? ""),
                "arguments": JSON(Array(e.cmd.dropFirst())), "privileged": false, "user": .string(e.user),
            ],
            "OpenStdin": .bool(e.attachStdin),
            "OpenStdout": .bool(e.attachStdout),
            "OpenStderr": .bool(e.attachStderr),
            "CanRemove": false,
            "ContainerID": .string(e.containerId),
            "DetachKeys": "",
            "Pid": 0,
        ]
    }
}
