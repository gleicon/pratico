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
}
