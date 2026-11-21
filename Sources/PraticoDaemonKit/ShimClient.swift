import Containerization
import ContainerizationOCI
import ContainerizationExtras
import ContainerizationOS
import Foundation
import PraticoCore

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
        // CLOEXEC_DEFAULT: the shim gets only the descriptors below. Without it, it would
        // inherit the daemon's API connections and published-port listeners, which then
        // outlive a daemon restart.
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, files.shimLog.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        posix_spawn_file_actions_adddup2(&actions, 1, 2)
        // fd 3: the shim writes a byte once the container is created (`ShimHost.readyFD`),
        // and the pipe ends when it exits; either wakes the wait below, without polling.
        var ready: [Int32] = [-1, -1]
        guard pipe(&ready) == 0 else { throw APIError(500, "cannot create a pipe for pratico-shim") }
        defer { close(ready[0]) }
        posix_spawn_file_actions_adddup2(&actions, ready[1], ShimHost.readyFD)
        let argv = [binary, files.dir.path]
        var cargs = argv.map { strdup($0) } + [nil]
        defer { cargs.forEach { free($0) } }
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, binary, &actions, &attr, &cargs, environ)
        close(ready[1])
        guard rc == 0 else { throw APIError(500, "cannot start pratico-shim: \(String(cString: strerror(rc)))") }

        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline {
            var p = pollfd(fd: ready[0], events: Int16(POLLIN), revents: 0)
            _ = poll(&p, 1, Int32(max(deadline.timeIntervalSinceNow, 0) * 1000))
            if FileManager.default.fileExists(atPath: files.exit.path) { break }
            if ["created", "running", "paused"].contains(Self.read(files.state)?["status"]?.string),
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
        try request(files, method, path).status
    }

    /// One request with an optional JSON body; returns status and body.
    func request(_ files: ShimFiles, _ method: String, _ path: String, body: Data = Data()) throws -> (status: Int, body: Data) {
        let fd = try connectSocket(files)
        defer { close(fd) }
        var request = Data("\(method) \(path) HTTP/1.1\r\nHost: shim\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
        request.append(body)
        _ = request.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        var buf = [UInt8](repeating: 0, count: 4096)
        var response = Data()
        while case let n = Posix.read(fd, &buf, buf.count), n > 0 { response.append(contentsOf: buf[0..<n]) }
        let headEnd = response.range(of: Data("\r\n\r\n".utf8))
        let head = String(decoding: response[..<(headEnd?.lowerBound ?? response.endIndex)], as: UTF8.self)
        let payload = headEnd.map { response[$0.upperBound...] } ?? Data()
        let status = Int(head.split(separator: " ").dropFirst().first ?? "") ?? 500
        guard status < 300 else {
            throw APIError(status, JSON.parse(Data(payload))?["message"]?.string ?? String(decoding: payload, as: UTF8.self))
        }
        return (status, Data(payload))
    }

    /// A hijacked raw stream (`/stdin`, `/exec-stream`): returns the socket once the shim
    /// switched protocols.
    func openStream(_ files: ShimFiles, _ path: String, body: Data = Data()) throws -> Int32 {
        let fd = try connectSocket(files)
        var request = Data("POST \(path) HTTP/1.1\r\nHost: shim\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\n\r\n".utf8)
        request.append(body)
        _ = request.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        var head = Data()
        var byte: UInt8 = 0
        while head.count < 4096, Posix.read(fd, &byte, 1) == 1 {
            head.append(byte)
            if head.suffix(4) == Data("\r\n\r\n".utf8) { break }
        }
        let text = String(decoding: head, as: UTF8.self)
        guard text.hasPrefix("HTTP/1.1 101") else {
            // An error reply: relay its status and message.
            let status = Int(text.split(separator: " ").dropFirst().first ?? "") ?? 500
            let length = text.split(separator: "\r\n").first { $0.lowercased().hasPrefix("content-length:") }
                .flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) } ?? 0
            var body = [UInt8](repeating: 0, count: min(max(length, 0), 65536))
            var got = 0
            while got < body.count, case let n = Posix.read(fd, &body[got], body.count - got), n > 0 { got += n }
            close(fd)
            throw APIError(status, JSON.parse(Data(body[0..<got]))?["message"]?.string ?? "shim refused \(path)")
        }
        return fd
    }

    private func connectSocket(_ files: ShimFiles) throws -> Int32 {
        let fd = socket(AF_UNIX, Posix.stream, 0)
        guard fd >= 0 else { throw APIError(500, "shim: socket failed") }
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
        guard ok == 0 else {
            close(fd)
            throw APIError(409, "container is not running (shim unreachable)")
        }
        return fd
    }
}
