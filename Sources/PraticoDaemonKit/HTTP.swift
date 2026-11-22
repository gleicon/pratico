import Foundation
import PraticoCore

/// Fixed limits (SPEC NFR-4, Tiger Style): nothing here grows without bound.
public enum Limits {
    public static let maxConnections = 64
    public static let maxHeaderBytes = 64 * 1024
    public static let maxBodyBytes = 64 * 1024 * 1024
    /// A streamed body (`docker cp` in, `docker load`) goes to a file, not memory, up to this.
    public static let maxSpooledBytes: Int64 = 64 << 30
    static let readChunk = 64 * 1024
}

public struct Request: Sendable {
    public var method: String
    /// Path with any `/vX.Y` API version prefix removed.
    public var path: String
    public var query: [String: String]
    public var headers: [String: String]
    public var body: Data
    /// The `/vX.Y` prefix the client asked for, if any.
    public var apiVersion: String? = nil
    /// Every value of each query key (`names=a&names=b`); `query` keeps the last.
    public var queryAll: [String: [String]] = [:]
    /// The body, written to a temporary file, for routes that stream large bodies; `body`
    /// is then empty. Removed once the handler returns.
    public var bodyFile: URL? = nil

    public func flag(_ name: String) -> Bool {
        guard let v = query[name] else { return false }
        return Filters.isTrue(v)
    }
}

/// One client connection. Writes are serialized: attach and log streams fan out
/// from several supervisor threads onto the same socket.
public final class Connection: @unchecked Sendable {
    let fd: Int32
    private var buffer: [UInt8] = []
    private let writeLock = NSLock()
    private var closed = false

    init(fd: Int32) {
        self.fd = fd
        Posix.noSigpipe(fd)
    }

    deinit { close() }

    func close() {
        writeLock.lock()
        defer { writeLock.unlock() }
        if !closed {
            closed = true
            // Wakes a thread blocked in read() before the descriptor is released.
            shutdown(fd, Posix.shutBoth)
            Posix.close(fd)
        }
    }

    // MARK: Reading

    private func fill() -> Bool {
        var chunk = [UInt8](repeating: 0, count: Limits.readChunk)
        while true {
            let n = chunk.withUnsafeMutableBytes { Posix.read(fd, $0.baseAddress, Limits.readChunk) }
            if n > 0 {
                buffer.append(contentsOf: chunk[0..<n])
                return true
            }
            if n < 0 && errno == EINTR { continue }
            return false
        }
    }

    /// After a hijack: bytes already buffered, else the next read; nil at EOF.
    func readRaw() -> Data? {
        if buffer.isEmpty && !fill() { return nil }
        let out = Data(buffer)
        buffer.removeAll()
        return out
    }

    private func take(_ n: Int) -> [UInt8] {
        let out = Array(buffer[0..<n])
        buffer.removeFirst(n)
        return out
    }

    private func readUntil(_ marker: [UInt8], max: Int) -> [UInt8]? {
        var searchFrom = 0
        while true {
            if buffer.count >= marker.count {
                let last = buffer.count - marker.count
                if searchFrom <= last {
                    for i in searchFrom...last where buffer[i] == marker[0] && Array(buffer[i..<i + marker.count]) == marker {
                        let out = take(i)
                        buffer.removeFirst(marker.count)
                        return out
                    }
                    searchFrom = last + 1
                }
            }
            if buffer.count > max { return nil }
            if !fill() { return nil }
        }
    }

    private func readExact(_ n: Int) -> [UInt8]? {
        while buffer.count < n {
            if !fill() { return nil }
        }
        return take(n)
    }

    /// Reads one request, or nil on EOF / malformed input / limit exceeded. When `spool`
    /// says so for its method and path, the body goes to a file (`bodyFile`), not memory.
    func readRequest(spool: (String, String) -> Bool = { _, _ in false }) -> Request? {
        guard let head = readUntil(Array("\r\n\r\n".utf8), max: Limits.maxHeaderBytes),
            let text = String(bytes: head, encoding: .utf8)
        else { return nil }
        var lines = text.components(separatedBy: "\r\n")
        let parts = lines.removeFirst().split(separator: " ")
        guard parts.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].lowercased()
            headers[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }

        let target = String(parts[1])
        let (rawPath, rawQuery) = target.splitOnce("?")
        let (path, version) = Self.splitVersion(rawPath.removingPercentEncoding ?? rawPath)

        var body = Data()
        var bodyFile: URL?
        if spool(String(parts[0]), path) {
            let file = FileManager.default.temporaryDirectory.appending(path: "pratico-body-\(UUID().uuidString)")
            guard FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]),
                let h = try? FileHandle(forWritingTo: file)
            else { return nil }
            let ok = readBody(headers, limit: Limits.maxSpooledBytes) { (try? h.write(contentsOf: $0)) != nil }
            try? h.close()
            guard ok else { try? FileManager.default.removeItem(at: file); return nil }
            bodyFile = file
        } else {
            guard readBody(headers, limit: Int64(Limits.maxBodyBytes), { body.append($0); return true }) else { return nil }
        }
        return Request(
            method: String(parts[0]),
            path: path,
            query: Self.parseQuery(rawQuery ?? "").mapValues { $0.last ?? "" },
            headers: headers,
            body: body,
            apiVersion: version,
            queryAll: Self.parseQuery(rawQuery ?? ""),
            bodyFile: bodyFile)
    }

    /// The body (chunked or `Content-Length`), handed to `sink` piece by piece, at most
    /// `limit` bytes; false if it breaks off, overruns, or `sink` fails.
    private func readBody(_ headers: [String: String], limit: Int64, _ sink: (Data) -> Bool) -> Bool {
        var total: Int64 = 0
        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            while true {
                guard let sizeLine = readUntil(Array("\r\n".utf8), max: 1024),
                    let size = Int(String(decoding: sizeLine, as: UTF8.self).split(separator: ";")[0], radix: 16), size >= 0
                else { return false }
                if size == 0 {
                    _ = readUntil(Array("\r\n".utf8), max: Limits.maxHeaderBytes)
                    return true
                }
                total += Int64(size)
                guard total <= limit else { return false }
                var left = size
                while left > 0 {
                    let n = min(left, 1 << 20)
                    guard let piece = readExact(n), sink(Data(piece)) else { return false }
                    left -= n
                }
                guard readExact(2) != nil else { return false }
            }
        } else if let len = headers["content-length"].flatMap(Int64.init), len > 0 {
            guard len <= limit else { return false }
            var left = len
            while left > 0 {
                let n = Int(min(left, 1 << 20))
                guard let piece = readExact(n), sink(Data(piece)) else { return false }
                left -= Int64(n)
            }
        }
        return true
    }

    /// `/v1.55/containers/json` is `/containers/json` at API 1.55.
    static func splitVersion(_ path: String) -> (path: String, version: String?) {
        guard path.hasPrefix("/v") else { return (path, nil) }
        let rest = path.dropFirst(2)
        guard let slash = rest.firstIndex(of: "/") else { return (path, nil) }
        let version = rest[..<slash]
        if !version.isEmpty && version.allSatisfy({ $0.isNumber || $0 == "." }) {
            return (String(rest[slash...]), String(version))
        }
        return (path, nil)
    }

    static func parseQuery(_ q: String) -> [String: [String]] {
        var out: [String: [String]] = [:]
        for pair in q.split(separator: "&") {
            let (k, v) = String(pair).splitOnce("=")
            func decode(_ s: String) -> String {
                s.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? s
            }
            out[decode(k), default: []].append(decode(v ?? ""))
        }
        return out
    }

    // MARK: Writing

    @discardableResult
    func write(_ data: Data) -> Bool {
        writeLock.lock()
        defer { writeLock.unlock() }
        if closed { return false }
        return data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = Posix.write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                offset += n
            }
            return true
        }
    }

    private func head(_ status: Int, _ headers: [(String, String)]) -> Data {
        var s = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        s += "Api-Version: \(DockerAPI.version)\r\nServer: pratico/\(DaemonInfo.version)\r\n"
        for (k, v) in headers { s += "\(k): \(v)\r\n" }
        return Data((s + "\r\n").utf8)
    }

    public func respond(_ status: Int, body: Data = Data(), contentType: String = "application/json",
                        extra: [(String, String)] = [], headOnly: Bool = false)
    {
        var headers = extra
        if status != 204 && status != 304 {
            headers.append(("Content-Type", contentType))
            headers.append(("Content-Length", "\(body.count)"))
        }
        var out = head(status, headers)
        if !headOnly { out.append(body) }
        write(out)
    }

    public func json(_ status: Int, _ value: JSON) { respond(status, body: value.encoded() + Data("\n".utf8)) }

    /// Docker-format error body (SPEC FR-7).
    public func error(_ status: Int, _ message: String) { json(status, ["message": .string(message)]) }

    public func beginChunked(_ status: Int = 200, contentType: String = "application/json", extra: [(String, String)] = []) {
        write(head(status, [("Content-Type", contentType), ("Transfer-Encoding", "chunked")] + extra))
    }

    @discardableResult
    public func chunk(_ data: Data) -> Bool {
        if data.isEmpty { return true }
        var out = Data(String(data.count, radix: 16).utf8)
        out.append(contentsOf: Array("\r\n".utf8))
        out.append(data)
        out.append(contentsOf: Array("\r\n".utf8))
        return write(out)
    }

    public func endChunked() { write(Data("0\r\n\r\n".utf8)) }

    /// Switches the connection to a raw stream (Docker attach / exec hijack).
    public func hijack(contentType: String) {
        write(head(101, [("Content-Type", contentType), ("Connection", "Upgrade"), ("Upgrade", "tcp")]))
    }

    static func reason(_ status: Int) -> String {
        switch status {
        case 101: "UPGRADED"
        case 200: "OK"
        case 201: "Created"
        case 204: "No Content"
        case 304: "Not Modified"
        case 400: "Bad Request"
        case 404: "Not Found"
        case 409: "Conflict"
        case 500: "Internal Server Error"
        case 501: "Not Implemented"
        case 503: "Service Unavailable"
        default: "Status"
        }
    }
}

/// What a handler wants done with the connection afterwards.
public enum Disposition: Sendable {
    case keepAlive
    case close
    /// The handler took ownership (hijack or long-lived stream); do not touch it.
    case detached
}

/// HTTP/1.1 server on a Unix socket, one thread per connection, at most
/// `Limits.maxConnections` at once.
public final class HTTPServer: @unchecked Sendable {
    public typealias Handler = @Sendable (Request, Connection) -> Disposition

    let path: String
    /// Set for a server on 127.0.0.1 (the MCP endpoint, D-48) instead of a Unix socket.
    let loopbackPort: UInt16?
    let handler: Handler
    /// Routes whose request bodies are streamed to a file (see `Request.bodyFile`).
    let spool: @Sendable (String, String) -> Bool
    /// The socket's mode: the owner only (NFR-9), or its group too on a Linux host, where
    /// the `pratico` group are the users the service serves.
    let mode: mode_t
    private var listenFD: Int32 = -1
    private let slots = DispatchSemaphore(value: Limits.maxConnections)

    public init(path: String, mode: mode_t = 0o600, spool: @escaping @Sendable (String, String) -> Bool = { _, _ in false }, handler: @escaping Handler) {
        self.path = path
        self.mode = mode
        self.loopbackPort = nil
        self.spool = spool
        self.handler = handler
    }

    /// A server on 127.0.0.1:`port` only, never another interface.
    public init(loopbackPort port: UInt16, handler: @escaping Handler) {
        precondition(port > 0, "port 0 is not a fixed endpoint")
        self.path = ""
        self.mode = 0o600
        self.loopbackPort = port
        self.spool = { _, _ in false }
        self.handler = handler
    }

    public func start() throws {
        signal(SIGPIPE, SIG_IGN)
        if let port = loopbackPort {
            listenFD = try Self.listenLoopback(port)
        } else {
            listenFD = try listenUnix()
        }
        let thread = Thread { [self] in acceptLoop() }
        thread.name = "pratico.accept"
        thread.start()
    }

    private static func listenLoopback(_ port: UInt16) throws -> Int32 {
        let fd = socket(AF_INET, Posix.stream, 0)
        guard fd >= 0 else { throw DaemonError.system("socket", errno) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        #if canImport(Darwin)
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = UInt32(0x7F00_0001).bigEndian  // 127.0.0.1
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard rc == 0 else {
            close(fd)
            throw DaemonError.system("bind 127.0.0.1:\(port)", errno)
        }
        guard listen(fd, 64) == 0 else {
            close(fd)
            throw DaemonError.system("listen", errno)
        }
        return fd
    }

    private func listenUnix() throws -> Int32 {
        let fd = socket(AF_UNIX, Posix.stream, 0)
        guard fd >= 0 else { throw DaemonError.system("socket", errno) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count < capacity else { throw DaemonError.message("socket path too long: \(path)") }
        withUnsafeMutableBytes(of: &addr.sun_path) { dst in
            for (i, b) in bytes.enumerated() { dst[i] = b }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        // A live daemon keeps its socket: a second one must not take it over.
        let probe = socket(AF_UNIX, Posix.stream, 0)
        let live = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(probe, $0, len) } } == 0
        close(probe)
        if live {
            close(fd)
            throw DaemonError.alreadyServing(path)
        }
        unlink(path)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) }
        }
        guard rc == 0 else { throw DaemonError.system("bind \(path)", errno) }
        chmod(path, mode)  // NFR-9
        guard listen(fd, 128) == 0 else { throw DaemonError.system("listen", errno) }
        return fd
    }

    public func stop() {
        if listenFD >= 0 {
            Posix.close(listenFD)
            listenFD = -1
        }
        if loopbackPort == nil { unlink(path) }
    }

    private func acceptLoop() {
        while listenFD >= 0 {
            slots.wait()
            let client = accept(listenFD, nil, nil)
            if client < 0 {
                slots.signal()
                if errno == EINTR { continue }
                return
            }
            let conn = Connection(fd: client)
            let thread = Thread { [self] in
                serve(conn)
                slots.signal()
            }
            thread.stackSize = 512 * 1024
            thread.start()
        }
    }

    private func serve(_ conn: Connection) {
        while let req = conn.readRequest(spool: spool) {
            let disposition = handler(req, conn)
            if let file = req.bodyFile { try? FileManager.default.removeItem(at: file) }
            switch disposition {
            // HTTP/1.1: the client asked for the connection to end with this response.
            case .keepAlive where req.headers["connection"]?.lowercased() == "close": conn.close(); return
            case .keepAlive: continue
            case .close: conn.close(); return
            case .detached: return
            }
        }
        conn.close()
    }
}

public enum DaemonError: Error, CustomStringConvertible {
    case system(String, Int32)
    case message(String)
    /// Another daemon answers on the socket; it is left alone.
    case alreadyServing(String)

    public var description: String {
        switch self {
        case .system(let what, let code): "\(what): \(String(cString: strerror(code)))"
        case .message(let m): m
        case .alreadyServing(let path): "another pratico-daemon is already serving \(path)"
        }
    }
}

extension String {
    func splitOnce(_ sep: Character) -> (String, String?) {
        guard let i = firstIndex(of: sep) else { return (self, nil) }
        return (String(self[..<i]), String(self[index(after: i)...]))
    }
}
