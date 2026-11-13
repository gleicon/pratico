import Darwin
import Foundation

/// Minimal HTTP client over the daemon's Unix socket, for the menubar's status checks.
public enum DaemonProbe {
    public struct Response: Sendable {
        public var status: Int
        public var body: Data
    }

    /// `GET <path>` with a short timeout; nil when the daemon is not answering.
    public static func get(_ path: String, socket: URL = Pratico.socketPath(), timeout: Int = 1) -> Response? {
        request("GET", path, socket: socket, timeout: timeout)
    }

    /// One bodiless request (`GET`, `DELETE`); nil when the daemon is not answering.
    public static func request(_ method: String, _ path: String, socket: URL = Pratico.socketPath(), timeout: Int = 1) -> Response? {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var tv = timeval(tv_sec: timeout, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(socket.path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { dst in
            for (i, b) in bytes.enumerated() { dst[i] = b }
        }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard rc == 0 else { return nil }

        let request = Array("\(method) \(path) HTTP/1.1\r\nHost: pratico\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
        guard write(fd, request, request.count) == request.count else { return nil }

        // Up to Content-Length when the reply has one, else until the daemon closes.
        var data = Data()
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        var expected: Int?
        while data.count < 16 << 20 {
            if expected == nil, let split = data.range(of: Data("\r\n\r\n".utf8)),
                let head = String(data: data[..<split.lowerBound], encoding: .utf8)
            {
                let length = head.split(separator: "\r\n").first { $0.lowercased().hasPrefix("content-length:") }
                    .flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) }
                expected = length.map { split.upperBound + $0 } ?? Int.max
            }
            if let expected, data.count >= expected { break }
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { break }
            data.append(contentsOf: chunk[0..<n])
        }
        guard let split = data.range(of: Data("\r\n\r\n".utf8)),
            let head = String(data: data[..<split.lowerBound], encoding: .utf8),
            let status = head.split(separator: " ").dropFirst().first.flatMap({ Int($0) })
        else { return nil }
        return Response(status: status, body: Data(data[split.upperBound...]))
    }
}

extension Pratico {
    /// Where the daemon records why it refused to start, for the menubar to show (SPEC FR-3, FR-38).
    /// Scan alerts the daemon writes for the menubar (SPEC D-24).
    public static func alertsPath(home: URL = home()) -> URL { home.appending(path: "alerts.json") }
    /// Registry trust settings in effect and kept logins (no passwords), written by the daemon.
    public static func registriesPath(home: URL = home()) -> URL { home.appending(path: "registries.json") }

    public static func startupErrorPath(home: URL = home()) -> URL {
        home.appending(path: "daemon.err", directoryHint: .notDirectory)
    }
}
