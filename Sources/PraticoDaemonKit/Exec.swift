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
    var master: Int32 = -1  // pty master when tty

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

/// Maps the exec API onto `container exec`. A TTY exec gets a pty the daemon owns, so
/// the Apple CLI sees a real terminal and resize reaches it through the master side.
final class ExecService: @unchecked Sendable {
    let runtime: AppleContainer
    let containers: ContainerService
    private let lock = NSLock()
    private var instances: [String: ExecInstance] = [:]

    init(runtime: AppleContainer, containers: ContainerService) {
        self.runtime = runtime
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

        var args = ["exec"]
        if e.attachStdin { args.append("-i") }
        if e.tty { args.append("-t") }
        for v in e.env { args += ["-e", v] }
        if !e.workdir.isEmpty { args += ["-w", e.workdir] }
        if !e.user.isEmpty { args += ["-u", e.user] }
        args += [rec.appleId] + e.cmd
        let p = runtime.process(args)

        let detach = body["Detach"]?.bool ?? false
        var stdinWriter: FileHandle?
        var readers: [(UInt8, FileHandle)] = []
        if e.tty {
            let master = posix_openpt(O_RDWR | O_NOCTTY)
            guard master >= 0, grantpt(master) == 0, unlockpt(master) == 0, let name = ptsname(master) else {
                throw APIError(500, "cannot allocate a pty: \(String(cString: strerror(errno)))")
            }
            let slave = open(name, O_RDWR | O_NOCTTY)
            guard slave >= 0 else { Darwin.close(master); throw APIError(500, "cannot open pty") }
            // Raw: the guest's pty already does line discipline; a second one doubles CRs.
            var tio = termios()
            if tcgetattr(slave, &tio) == 0 {
                cfmakeraw(&tio)
                tcsetattr(slave, TCSANOW, &tio)
            }
            if let size = body["ConsoleSize"]?.array, size.count == 2,
                let h = size[0].int, let w = size[1].int
            {
                Self.resize(master, height: Int(h), width: Int(w))
            }
            let slaveHandle = FileHandle(fileDescriptor: slave, closeOnDealloc: true)
            p.standardInput = slaveHandle
            p.standardOutput = slaveHandle
            p.standardError = slaveHandle
            e.master = master
            let masterHandle = FileHandle(fileDescriptor: master, closeOnDealloc: false)
            stdinWriter = masterHandle
            readers = [(1, masterHandle)]
        } else {
            if e.attachStdin && !detach {
                let inPipe = Pipe()
                p.standardInput = inPipe
                stdinWriter = inPipe.fileHandleForWriting
            }
            let out = Pipe()
            let err = Pipe()
            p.standardOutput = out
            p.standardError = err
            readers = [(1, out.fileHandleForReading), (2, err.fileHandleForReading)]
        }

        do { try p.run() } catch {
            if e.master >= 0 { Darwin.close(e.master) }
            throw APIError(500, "cannot exec: \(error)")
        }
        // The child holds its own copies; the daemon's must go or EOF never arrives.
        if e.tty { try? (p.standardInput as? FileHandle)?.close() }
        if !e.tty, let pipe = p.standardOutput as? Pipe { try? pipe.fileHandleForWriting.close() }
        if !e.tty, let pipe = p.standardError as? Pipe { try? pipe.fileHandleForWriting.close() }
        if !e.tty, let pipe = p.standardInput as? Pipe { try? pipe.fileHandleForReading.close() }
        e.lock.lock()
        e.running = true
        e.lock.unlock()

        if detach {
            conn.respond(200)
            for (_, h) in readers {
                Thread.detachNewThread { while !h.availableData.isEmpty {} }
            }
            Thread.detachNewThread { [self] in
                p.waitUntilExit()
                finish(e, code: Int(p.terminationStatus))
            }
            return .keepAlive
        }

        conn.hijack(contentType: e.tty ? "application/vnd.docker.raw-stream" : "application/vnd.docker.multiplexed-stream")
        if let stdinWriter {
            Thread.detachNewThread {
                while let data = conn.readRaw() {
                    if (try? stdinWriter.write(contentsOf: data)) == nil { return }
                }
                // Client closed its side: end the process's stdin (a pty has no half-close).
                if !e.tty { try? stdinWriter.close() }
            }
        }
        let group = DispatchGroup()
        for (stream, h) in readers {
            group.enter()
            Thread.detachNewThread {
                let wanted = stream == 1 ? e.attachStdout : e.attachStderr
                // A pty master read fails with EIO once the slave side is gone.
                while case let data = h.availableData, !data.isEmpty {
                    if wanted { conn.write(e.tty ? data : StdCopy.frame(stream: stream, data)) }
                }
                group.leave()
            }
        }
        Thread.detachNewThread { [self] in
            p.waitUntilExit()
            finish(e, code: Int(p.terminationStatus))
            group.wait()
            conn.close()
        }
        return .detached
    }

    private func finish(_ e: ExecInstance, code: Int) {
        e.lock.lock()
        e.running = false
        e.exitCode = code
        let master = e.master
        e.lock.unlock()
        if master >= 0 {
            // Unblock a reader still waiting on a pty with no remaining writers.
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) { Darwin.close(master) }
        }
    }

    func resize(_ id: String, height: Int, width: Int) throws {
        let e = try get(id)
        e.lock.lock()
        let master = e.master
        e.lock.unlock()
        if master >= 0 { Self.resize(master, height: height, width: width) }
    }

    private static func resize(_ fd: Int32, height: Int, width: Int) {
        guard height > 0, width > 0 else { return }
        var ws = winsize(ws_row: UInt16(clamping: height), ws_col: UInt16(clamping: width), ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(fd, TIOCSWINSZ, &ws)
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
