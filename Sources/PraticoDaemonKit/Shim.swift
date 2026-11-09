import Containerization
import ContainerizationOCI
import Foundation

/// What a shim runs, written by the daemon to `containers/<id>/spec.json`
/// (docs/design/runtime.md). Paths are absolute.
struct ShimSpec: Codable, Sendable {
    var id: String  // VM/container name (the Docker short ID)
    var kernel: String
    var initfs: String
    var rootfs: String
    var arguments: [String]
    var environment: [String]
    var workingDirectory: String
    var user: String
    var tty: Bool
    var hostname: String
    var cpus: Int
    var memoryMiB: Int
    var mounts: [ShimMount]
}

struct ShimMount: Codable, Sendable, Equatable {
    var source: String
    var destination: String
    var readOnly: Bool
}

/// Files a shim keeps in its container directory (`<home>/containers/<id>`).
struct ShimFiles: Sendable {
    let dir: URL
    var spec: URL { dir.appending(path: "spec.json") }
    /// `<home>/run/<short id>.sock`: a path in the container directory would exceed the
    /// 104-byte Unix socket limit.
    var socket: URL {
        dir.deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "run/\(dir.lastPathComponent.prefix(12)).sock")
    }
    var state: URL { dir.appending(path: "state.json") }  // {"pid", "status": "starting|running"}
    var exit: URL { dir.appending(path: "exit.json") }  // {"exitCode", "finishedAt"}; written last
    var log: URL { dir.appending(path: "log") }
    var shimLog: URL { dir.appending(path: "shim.log") }
}

// MARK: - Shim side

/// Runs one container's VM for its whole life, independent of the daemon: it boots the
/// VM, writes the container's output to the log, serves `shim.sock`, and records the exit
/// code in `exit.json` before exiting. A daemon restart does not touch it.
public enum ShimHost {
    public static func run(directory: String) async -> Int32 {
        let files = ShimFiles(dir: URL(filePath: directory, directoryHint: .isDirectory))
        func fail(_ message: String) -> Int32 {
            FileHandle.standardError.write(Data("pratico-shim: \(message)\n".utf8))
            writeExit(files, code: 127, error: message)
            return 1
        }
        guard let data = try? Data(contentsOf: files.spec), let spec = try? JSONDecoder().decode(ShimSpec.self, from: data) else {
            return fail("cannot read \(files.spec.path)")
        }
        writeJSON(["pid": .int(Int64(getpid())), "status": "starting"], to: files.state)

        let log = LogStore(path: files.log)
        let vmm = VZVirtualMachineManager(
            kernel: Kernel(path: URL(filePath: spec.kernel), platform: .linuxArm),
            initialFilesystem: .block(format: "ext4", source: spec.initfs, destination: "/", options: ["ro"]))
        let container: LinuxContainer
        do {
            container = try LinuxContainer(
                spec.id, rootfs: .block(format: "ext4", source: spec.rootfs, destination: "/"), vmm: vmm,
                vm: VMResources(cpus: spec.cpus, memoryInBytes: UInt64(spec.memoryMiB).mib() + VMResources.guestMemoryOverhead)
            ) { config in
                config.cpus = spec.cpus
                config.memoryInBytes = UInt64(spec.memoryMiB).mib()
                config.hostname = spec.hostname
                config.process.arguments = spec.arguments
                config.process.environmentVariables = spec.environment
                config.process.workingDirectory = spec.workingDirectory.isEmpty ? "/" : spec.workingDirectory
                config.process.user = Self.user(spec.user)
                config.process.terminal = spec.tty
                config.process.stdout = LogWriter(log: log, stream: 1)
                config.process.stderr = LogWriter(log: log, stream: spec.tty ? 1 : 2)
                for m in spec.mounts {
                    config.mounts.append(.share(source: m.source, destination: m.destination, options: m.readOnly ? ["ro"] : []))
                }
            }
            try await container.create()
            try await container.start()
        } catch {
            log.finish()
            return fail("cannot start: \(error)")
        }
        writeJSON(["pid": .int(Int64(getpid())), "status": "running"], to: files.state)

        try? FileManager.default.createDirectory(at: files.socket.deletingLastPathComponent(), withIntermediateDirectories: true)
        let control = ShimControl(container: container, files: files)
        let server = HTTPServer(path: files.socket.path) { req, conn in control.handle(req, conn) }
        try? server.start()

        let code: Int32
        do { code = try await container.wait().exitCode } catch { code = 137 }
        log.finish()
        try? await container.stop()
        server.stop()
        writeExit(files, code: code, error: "")
        return 0
    }

    /// Docker `User`: `name`, `uid`, or `uid:gid`; names resolve inside the guest.
    static func user(_ s: String) -> ContainerizationOCI.User {
        var u = ContainerizationOCI.User()
        guard !s.isEmpty else { return u }
        let (name, group) = s.splitOnce(":")
        if let uid = UInt32(name) { u.uid = uid } else { u.username = name }
        if let group, let gid = UInt32(group) { u.gid = gid }
        return u
    }

    static func writeExit(_ files: ShimFiles, code: Int32, error: String) {
        writeJSON(["exitCode": .int(Int64(code)), "finishedAt": .string(Timestamp.format(Date())), "error": .string(error)],
                  to: files.exit)
    }

    static func writeJSON(_ value: JSON, to url: URL) {
        try? value.encoded().write(to: url, options: .atomic)
    }
}

/// The shim's control API on `shim.sock`, spoken only by the daemon.
final class ShimControl: Sendable {
    let container: LinuxContainer
    let files: ShimFiles

    init(container: LinuxContainer, files: ShimFiles) {
        self.container = container
        self.files = files
    }

    /// `state.json` tells a restarted daemon whether the VM is paused.
    private func record(_ status: String) {
        ShimHost.writeJSON(["pid": .int(Int64(getpid())), "status": .string(status)], to: files.state)
    }

    func handle(_ req: Request, _ conn: Connection) -> Disposition {
        let c = container
        let parts = req.path.split(separator: "/").map(String.init)
        do {
            switch (req.method, parts.first) {
            case ("POST", "kill"):
                let sig = Int32(req.query["signal"] ?? "") ?? 9
                try blocking { try await c.kill(Signal(rawValue: sig)) }
            case ("POST", "stop"):
                // SIGTERM, then SIGKILL after the grace period, as `docker stop`.
                let grace = Double(req.query["t"] ?? "") ?? 10
                try blocking { try await c.kill(Signal(rawValue: 15)) }
                DispatchQueue.global().asyncAfter(deadline: .now() + grace) {
                    Task { try? await c.kill(Signal(rawValue: 9)) }
                }
            case ("POST", "pause"):
                try blocking { try await c.withVirtualMachineInstance { try await $0.pause() } }
                record("paused")
            case ("POST", "resume"):
                try blocking { try await c.withVirtualMachineInstance { try await $0.resume() } }
                record("running")
            default:
                conn.error(404, "shim: unknown \(req.method) \(req.path)")
                return .close
            }
            conn.respond(204)
        } catch {
            conn.error(500, "shim: \(error)")
        }
        return .close  // one request per connection; the client reads to EOF
    }
}

/// Container output into the log, line-framed by `LogStore`.
struct LogWriter: Writer {
    let log: LogStore
    let stream: UInt8
    func write(_ data: Data) throws { log.append(stream: stream, data) }
    func close() throws {}
}

// MARK: - Daemon side

/// The daemon's handle on shims: spawn, control, and exit tracking (docs/design/runtime.md).
struct ShimClient: Sendable {
    let binary: String

    /// `pratico-shim` next to the daemon (both live in `Contents/MacOS`).
    static func locate() -> String? {
        let candidates = [ProcessInfo.processInfo.environment["PRATICO_SHIM_BIN"],
                          Bundle.main.executableURL?.deletingLastPathComponent().appending(path: "pratico-shim").path]
        return candidates.compactMap { $0 }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Starts a shim in its own session, so it outlives the daemon, and waits until the
    /// container runs or has already exited.
    func spawn(_ files: ShimFiles) throws -> pid_t {
        for f in [files.exit, files.state, files.socket] { try? FileManager.default.removeItem(at: f) }
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID))
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, files.shimLog.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        posix_spawn_file_actions_adddup2(&actions, 1, 2)
        let argv = [binary, files.dir.path]
        var cargs = argv.map { strdup($0) } + [nil]
        defer { cargs.forEach { free($0) } }
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, binary, &actions, &attr, &cargs, environ)
        guard rc == 0 else { throw APIError(500, "cannot start pratico-shim: \(String(cString: strerror(rc)))") }

        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: files.exit.path) { break }
            if ["running", "paused"].contains(Self.read(files.state)?["status"]?.string),
                FileManager.default.fileExists(atPath: files.socket.path)
            { break }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return pid
    }

    /// Calls once when the shim process ends (also for shims from an earlier daemon).
    func onExit(_ pid: pid_t, _ handler: @escaping @Sendable () -> Void) {
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .global())
        let fired = Box(false)
        source.setEventHandler {
            guard !fired.value else { return }
            fired.value = true
            source.cancel()
            handler()
        }
        source.resume()
        if kill(pid, 0) != 0 && errno == ESRCH, !fired.value {  // exited before the source armed
            fired.value = true
            source.cancel()
            handler()
        }
    }

    /// The live shim's pid, if any.
    static func livePid(_ files: ShimFiles) -> pid_t? {
        guard let pid = read(files.state)?["pid"]?.int.map({ pid_t($0) }), pid > 0, kill(pid, 0) == 0,
            !FileManager.default.fileExists(atPath: files.exit.path)
        else { return nil }
        return pid
    }

    static func exitStatus(_ files: ShimFiles) -> (code: Int, error: String, finishedAt: Date?)? {
        guard let j = read(files.exit) else { return nil }
        return (Int(j["exitCode"]?.int ?? 0), j["error"]?.string ?? "", j["finishedAt"]?.string.flatMap(Timestamp.parse))
    }

    static func read(_ url: URL) -> JSON? { (try? Data(contentsOf: url)).flatMap(JSON.parse) }

    /// One request on the shim's control socket.
    @discardableResult
    func call(_ files: ShimFiles, _ method: String, _ path: String) throws -> Int {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw APIError(500, "shim: socket failed") }
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let sockPath = files.socket.path
        guard sockPath.utf8.count < MemoryLayout.size(ofValue: addr.sun_path) else { throw APIError(500, "shim: socket path too long") }
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            buf.copyBytes(from: sockPath.utf8)
            buf[sockPath.utf8.count] = 0
        }
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard ok == 0 else { throw APIError(409, "container is not running (shim unreachable)") }
        let request = "\(method) \(path) HTTP/1.1\r\nHost: shim\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        _ = request.withCString { write(fd, $0, strlen($0)) }
        var buf = [UInt8](repeating: 0, count: 4096)
        var response = Data()
        while case let n = Darwin.read(fd, &buf, buf.count), n > 0 { response.append(contentsOf: buf[0..<n]) }
        let text = String(decoding: response, as: UTF8.self)
        let status = Int(text.split(separator: " ").dropFirst().first ?? "") ?? 500
        guard status < 300 else {
            let body = text.components(separatedBy: "\r\n\r\n").dropFirst().joined()
            throw APIError(status, JSON.parse(Data(body.utf8))?["message"]?.string ?? body)
        }
        return status
    }
}
