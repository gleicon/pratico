import Foundation
import PraticoCore

/// `pratico-daemon dial-stdio`, and `docker system dial-stdio` through the link install
/// makes: what the Mac's docker CLI runs on an `ssh://` host, so the host needs nothing from
/// Docker (docs/linux-hosts.md). Bridges stdin and stdout to pratico's socket until the daemon
/// closes the connection; stdin's end half-closes it, as Docker's own does.
public enum DialStdio {
    public static func run(socket path: String) -> Int32 {
        let fd = Posix.socket(AF_UNIX, Posix.stream, 0)
        guard fd >= 0 else { return fail("cannot make a socket: errno \(errno)") }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return fail("\(path) is too long") }
        withUnsafeMutableBytes(of: &addr.sun_path) { dst in for (i, b) in bytes.enumerated() { dst[i] = b } }
        let rc = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Posix.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard rc == 0 else { return fail("cannot reach pratico at \(path): errno \(errno) (is pratico.service running, and are you in the pratico group?)") }

        let upstream = Thread {
            copy(from: STDIN_FILENO, to: fd)
            shutdown(fd, Posix.shutWrite)
        }
        upstream.start()
        copy(from: fd, to: STDOUT_FILENO)
        Posix.close(fd)
        return 0
    }

    /// Until `from` ends or `to` refuses a write.
    static func copy(from: Int32, to: Int32) {
        var buffer = [UInt8](repeating: 0, count: 64 << 10)
        while true {
            let n = Posix.read(from, &buffer, buffer.count)
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { return }
            var off = 0
            while off < n {
                let w = buffer.withUnsafeBytes { Posix.write(to, $0.baseAddress! + off, n - off) }
                if w < 0 && errno == EINTR { continue }
                guard w > 0 else { return }
                off += w
            }
        }
    }

    static func fail(_ message: String) -> Int32 {
        FileHandle.standardError.write(Data("pratico dial-stdio: \(message)\n".utf8))
        return 1
    }
}
