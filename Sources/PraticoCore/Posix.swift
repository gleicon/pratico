import Foundation
#if os(Linux)
import CPratico
#endif
#if canImport(Darwin)
@_exported import Darwin
#elseif canImport(Glibc)
@_exported import Glibc
#elseif canImport(Musl)
@_exported import Musl
#endif

/// The C library's calls under names no Swift method shadows (`read`, `close`, and the rest
/// are also methods of types that call them), and the constants Glibc spells differently.
public enum Posix {
    #if canImport(Darwin)
    public static let stream = SOCK_STREAM
    public static let datagram = SOCK_DGRAM
    #else
    public static let stream = Int32(SOCK_STREAM.rawValue)
    public static let datagram = Int32(SOCK_DGRAM.rawValue)
    #endif

    #if canImport(Darwin)
    public static let shutWrite = SHUT_WR
    public static let shutBoth = SHUT_RDWR
    public static let tcp = IPPROTO_TCP
    public static let icmp = IPPROTO_ICMP
    #else
    public static let shutWrite = Int32(SHUT_WR)
    public static let shutBoth = Int32(SHUT_RDWR)
    public static let tcp = Int32(IPPROTO_TCP)
    public static let icmp = Int32(IPPROTO_ICMP)
    #endif

    public typealias Stat = stat

    public static func read(_ fd: Int32, _ buf: UnsafeMutableRawPointer?, _ count: Int) -> Int {
        #if canImport(Darwin)
        Darwin.read(fd, buf, count)
        #elseif canImport(Glibc)
        Glibc.read(fd, buf, count)
        #else
        Musl.read(fd, buf, count)
        #endif
    }

    public static func write(_ fd: Int32, _ buf: UnsafeRawPointer?, _ count: Int) -> Int {
        #if canImport(Darwin)
        Darwin.write(fd, buf, count)
        #elseif canImport(Glibc)
        Glibc.write(fd, buf, count)
        #else
        Musl.write(fd, buf, count)
        #endif
    }

    @discardableResult
    public static func close(_ fd: Int32) -> Int32 {
        #if canImport(Darwin)
        Darwin.close(fd)
        #elseif canImport(Glibc)
        Glibc.close(fd)
        #else
        Musl.close(fd)
        #endif
    }

    /// Never raises SIGPIPE: on Linux, which has no `SO_NOSIGPIPE`, through `MSG_NOSIGNAL`.
    public static func send(_ fd: Int32, _ buf: UnsafeRawPointer?, _ count: Int) -> Int {
        #if canImport(Darwin)
        Darwin.send(fd, buf, count, 0)
        #elseif canImport(Glibc)
        Glibc.send(fd, buf, count, Int32(MSG_NOSIGNAL))
        #else
        Musl.send(fd, buf, count, MSG_NOSIGNAL)
        #endif
    }

    public static func connect(_ fd: Int32, _ addr: UnsafePointer<sockaddr>, _ len: socklen_t) -> Int32 {
        #if canImport(Darwin)
        Darwin.connect(fd, addr, len)
        #elseif canImport(Glibc)
        Glibc.connect(fd, addr, len)
        #else
        Musl.connect(fd, addr, len)
        #endif
    }

    public static func socket(_ domain: Int32, _ type: Int32, _ proto: Int32) -> Int32 {
        #if canImport(Darwin)
        Darwin.socket(domain, type, proto)
        #elseif canImport(Glibc)
        Glibc.socket(domain, type, proto)
        #else
        Musl.socket(domain, type, proto)
        #endif
    }

    public static func accept(_ fd: Int32) -> Int32 {
        #if canImport(Darwin)
        Darwin.accept(fd, nil, nil)
        #elseif canImport(Glibc)
        Glibc.accept(fd, nil, nil)
        #else
        Musl.accept(fd, nil, nil)
        #endif
    }

    /// Writes to a closed peer return EPIPE instead of raising SIGPIPE. Linux has no socket
    /// option for it: there the daemon ignores SIGPIPE (`ignoreBrokenPipes`).
    public static func noSigpipe(_ fd: Int32) {
        #if canImport(Darwin)
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        #endif
    }

    /// Once at start, before any socket: see `noSigpipe`.
    public static func ignoreBrokenPipes() {
        #if !canImport(Darwin)
        signal(SIGPIPE, SIG_IGN)
        #endif
    }

    public static func modified(_ st: Stat) -> Int {
        #if canImport(Darwin)
        st.st_mtimespec.tv_sec
        #else
        st.st_mtim.tv_sec
        #endif
    }

    /// Bytes free for new data at `path`: on the Mac what the system reports as available
    /// for important use (purgeable space included), elsewhere what an unprivileged user may fill.
    public static func freeBytes(_ url: URL) -> Int64? {
        #if canImport(Darwin)
        (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
        #else
        var st = statvfs()
        guard statvfs(url.path, &st) == 0 else { return nil }
        return Int64(st.f_bavail) * Int64(st.f_frsize)
        #endif
    }

    /// A copy of `source` at `destination` that shares or skips what it can: an APFS clone on
    /// the Mac; elsewhere only the data extents are written, so holes (most of a disk
    /// image) stay holes. False when nothing was made; the caller then copies plainly.
    public static func cloneOrSparseCopy(_ source: String, _ destination: String) -> Bool {
        #if canImport(Darwin)
        return clonefile(source, destination, 0) == 0
        #else
        let from = open(source, O_RDONLY | O_CLOEXEC)
        guard from >= 0 else { return false }
        defer { close(from) }
        var st = Stat()
        guard fstat(from, &st) == 0 else { return false }
        let to = open(destination, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode_t(st.st_mode & 0o7777))
        guard to >= 0 else { return false }
        defer { close(to) }
        let size = Int64(st.st_size)
        var at: Int64 = 0
        var copied = true
        while at < size {
            let data = pratico_seek_data(from, at)
            if data < 0 { break }  // ENXIO: only a hole remains
            let hole = pratico_seek_hole(from, data)
            guard hole > data else { copied = false; break }
            var inOff = data, outOff = data
            var left = hole - data
            while left > 0 {
                let n = pratico_copy_file_range(from, &inOff, to, &outOff, UInt(left))
                if n <= 0 { copied = false; break }
                left -= n
            }
            if !copied { break }
            at = hole
        }
        guard copied, ftruncate(to, off_t(size)) == 0 else {
            unlink(destination)
            return false
        }
        return true
        #endif
    }

    /// Moves `source` over `destination` in one step, whether or not `destination` exists
    /// (`rename(2)`; `FileManager.replaceItemAt` fails on Linux when it does not).
    public static func replace(_ destination: URL, with source: URL) throws {
        guard rename(source.path, destination.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}
