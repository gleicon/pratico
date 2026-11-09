import Foundation

/// One line of container output.
struct LogLine: Sendable {
    var stream: UInt8  // 1 stdout, 2 stderr (Docker stdcopy numbering)
    var time: Date
    var data: Data  // includes the trailing newline when present
}

/// Per-container log: an append-only file of framed lines plus live followers.
/// Frame layout: stream (1 byte) · unix time (Float64, 8 bytes LE) · length (UInt32 LE) · bytes.
/// Capped (SPEC NFR-11): when `log` reaches half the cap it becomes `log.1`, replacing
/// the previous one, so the two segments never exceed the cap and the oldest data goes first.
final class LogStore: @unchecked Sendable {
    typealias Follower = @Sendable (LogLine?) -> Bool  // nil = stream ended; return false to unsubscribe

    let path: URL
    let maxBytes: Int
    private var size = 0
    private let lock = NSLock()
    private var partial: [UInt8: Data] = [:]
    private var followers: [Int: Follower] = [:]
    private var nextFollower = 0
    /// Set when another process (a pratico-shim) writes the file: `refresh()` then
    /// delivers its new lines to followers.
    private var tailOffset: Int?
    private static let maxLine = 256 * 1024

    static let defaultCap = 100 * 1_048_576

    init(path: URL, maxBytes: Int = LogStore.defaultCap) {
        self.path = path
        self.maxBytes = maxBytes
        if !FileManager.default.fileExists(atPath: path.path) {
            FileManager.default.createFile(atPath: path.path, contents: nil)
        }
        size = (try? FileManager.default.attributesOfItem(atPath: path.path)[.size] as? Int) ?? 0
    }

    var olderPath: URL { path.deletingLastPathComponent().appending(path: path.lastPathComponent + ".1") }

    /// Bytes on disk across both segments.
    var diskBytes: Int {
        [path, olderPath].reduce(0) { $0 + ((try? FileManager.default.attributesOfItem(atPath: $1.path)[.size] as? Int) ?? 0) }
    }

    func append(stream: UInt8, _ data: Data) {
        lock.lock()
        var buf = partial[stream, default: Data()]
        buf.append(data)
        var lines: [LogLine] = []
        while let nl = buf.firstIndex(of: 0x0A) {
            lines.append(LogLine(stream: stream, time: Date(), data: Data(buf[buf.startIndex...nl])))
            buf.removeSubrange(buf.startIndex...nl)
        }
        if buf.count >= Self.maxLine {
            lines.append(LogLine(stream: stream, time: Date(), data: buf))
            buf = Data()
        }
        partial[stream] = buf
        lock.unlock()
        write(lines)
    }

    /// Followers will get lines another process appends, from the file's current end on.
    func tailExternalWriter() {
        lock.lock()
        tailOffset = (try? FileManager.default.attributesOfItem(atPath: path.path)[.size] as? Int) ?? 0
        lock.unlock()
    }

    /// Reads what the external writer appended since the last call; a shorter file means
    /// it rotated, so reading restarts at its beginning.
    func refresh() {
        lock.lock()
        guard var offset = tailOffset, let h = try? FileHandle(forReadingFrom: path) else { lock.unlock(); return }
        let size = Int((try? h.seekToEnd()) ?? 0)
        if size < offset { offset = 0 }
        try? h.seek(toOffset: UInt64(offset))
        let data = (try? h.readToEnd()) ?? Data()
        try? h.close()
        let (lines, used) = Self.parseCounting(data)
        tailOffset = offset + used
        let current = followers
        lock.unlock()
        deliver(lines, current)
    }

    /// Flushes unterminated output and tells followers the stream is over.
    func finish() {
        refresh()
        lock.lock()
        let rest = partial.filter { !$0.value.isEmpty }.map { LogLine(stream: $0.key, time: Date(), data: $0.value) }
        partial = [:]
        lock.unlock()
        write(rest)
        lock.lock()
        let current = followers
        followers = [:]
        lock.unlock()
        for f in current.values { _ = f(nil) }
    }

    private func write(_ lines: [LogLine]) {
        guard !lines.isEmpty else { return }
        lock.lock()
        var out = Data()
        for l in lines {
            out.append(l.stream)
            var t = l.time.timeIntervalSince1970.bitPattern.littleEndian
            withUnsafeBytes(of: &t) { out.append(contentsOf: $0) }
            var n = UInt32(l.data.count).littleEndian
            withUnsafeBytes(of: &n) { out.append(contentsOf: $0) }
            out.append(l.data)
        }
        if size > 0 && size + out.count > maxBytes / 2 {
            try? FileManager.default.removeItem(at: olderPath)
            try? FileManager.default.moveItem(at: path, to: olderPath)
            FileManager.default.createFile(atPath: path.path, contents: nil)
            size = 0
        }
        size += out.count
        if let h = try? FileHandle(forWritingTo: path) {
            h.seekToEndOfFile()
            h.write(out)
            try? h.close()
        }
        let current = followers
        lock.unlock()
        deliver(lines, current)
    }

    private func deliver(_ lines: [LogLine], _ current: [Int: Follower]) {
        for (id, f) in current {
            for l in lines where !f(l) {
                lock.lock()
                followers[id] = nil
                lock.unlock()
                break
            }
        }
    }

    func read() -> [LogLine] {
        Self.parse(try? Data(contentsOf: olderPath)) + Self.parse(try? Data(contentsOf: path))
    }

    private static func parse(_ data: Data?) -> [LogLine] {
        guard let data else { return [] }
        return parseCounting(data).lines
    }

    /// Complete frames, and how many bytes they took.
    private static func parseCounting(_ data: Data) -> (lines: [LogLine], used: Int) {
        var lines: [LogLine] = []
        var i = data.startIndex
        while i + 13 <= data.endIndex {
            let stream = data[i]
            let t = data[(i + 1)..<(i + 9)].withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }
            let n = Int(data[(i + 9)..<(i + 13)].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian)
            let start = i + 13
            guard start + n <= data.endIndex else { break }
            lines.append(LogLine(stream: stream, time: Date(timeIntervalSince1970: Double(bitPattern: t.littleEndian)),
                                 data: Data(data[start..<(start + n)])))
            i = start + n
        }
        return (lines, i - data.startIndex)
    }

    /// Live lines only, no snapshot.
    func subscribe(_ f: @escaping Follower) {
        lock.lock()
        followers[nextFollower] = f
        nextFollower += 1
        lock.unlock()
    }

    /// Snapshot of past lines, then live lines until `finish()`, atomically (no gap).
    func follow(_ f: @escaping Follower) -> [LogLine] {
        lock.lock()
        defer { lock.unlock() }
        followers[nextFollower] = f
        nextFollower += 1
        return read()
    }
}

/// Docker stdcopy multiplexing: 8-byte header [stream, 0, 0, 0, size (BE32)] per frame.
enum StdCopy {
    static func frame(stream: UInt8, _ data: Data) -> Data {
        var out = Data([stream, 0, 0, 0])
        var n = UInt32(data.count).bigEndian
        withUnsafeBytes(of: &n) { out.append(contentsOf: $0) }
        out.append(data)
        return out
    }
}
