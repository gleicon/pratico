import ContainerizationArchive
import Foundation
import PraticoCore

/// tar in process, through ContainerizationArchive (libarchive); pratico runs no tar binary.
enum Tar {
    /// A member's uid and gid.
    struct Owner: Hashable {
        var uid: uid_t
        var gid: gid_t
        static let root = Owner(uid: 0, gid: 0)
    }

    /// Writes `names`, relative to `base`, with everything under them. Symlinks are stored as
    /// links, never followed, wherever they point, as Docker's `cp` does; files are streamed.
    /// `prefix` goes before every member's name; `owner`, given a member's path under
    /// `base`, replaces the file's own uid/gid.
    static func create(_ file: URL, base: URL, names: [String], gzip: Bool = false, prefix: String = "", owner: ((String) -> Owner)? = nil) throws {
        let writer = try ArchiveWriter(configuration: ArchiveWriterConfiguration(format: .pax, filter: gzip ? .gzip : .none))
        try writer.open(file: file)
        for name in names { try add(writer.makeTransactionWriter(), base: base, path: name, prefix: prefix, owner: owner) }
        try writer.finishEncoding()
    }

    private static func add(_ w: ArchiveWriterTransaction, base: URL, path: String, prefix: String, owner: ((String) -> Owner)?) throws {
        let full = base.appending(path: path).path
        var st = stat()
        guard lstat(full, &st) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ENOENT) }
        let entry = WriteEntry()
        entry.path = prefix + path
        entry.permissions = st.st_mode & 0o7777
        let id = owner?(path) ?? Owner(uid: st.st_uid, gid: st.st_gid)
        entry.owner = id.uid
        entry.group = id.gid
        entry.modificationDate = Date(timeIntervalSince1970: TimeInterval(Posix.modified(st)))
        entry.size = 0
        switch st.st_mode & S_IFMT {
        case S_IFDIR:
            entry.fileType = .directory
            try w.writeHeader(entry: entry)
            try w.finish()
            for child in try FileManager.default.contentsOfDirectory(atPath: full).sorted() {
                try add(w, base: base, path: path + "/" + child, prefix: prefix, owner: owner)
            }
        case S_IFLNK:
            entry.fileType = .symbolicLink
            entry.symlinkTarget = try FileManager.default.destinationOfSymbolicLink(atPath: full)
            try w.writeHeader(entry: entry)
            try w.finish()
        case S_IFREG:
            entry.fileType = .regular
            entry.size = Int64(st.st_size)
            let handle = try FileHandle(forReadingFrom: URL(filePath: full))
            defer { try? handle.close() }
            try w.writeHeader(entry: entry)
            while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
                try chunk.withUnsafeBytes { try w.writeChunk(data: $0) }
            }
            try w.finish()
        default:
            break  // sockets, FIFOs, devices: not copied, as with Docker's cp from a container
        }
    }

    /// Reads the regular files `accept` names into memory, never to disk, with hard caps
    /// counted on the bytes actually decompressed (headers can lie): an archive past
    /// `maxFile` for one member, `maxTotal` in all, or `maxEntries` members is rejected.
    /// Other members (directories, links) are skipped unread.
    static func readFiles(_ file: URL, accept: (String) -> Bool, maxFile: Int, maxTotal: Int, maxEntries: Int) throws -> [String: Data] {
        let reader = try ArchiveReader(file: file)
        var out: [String: Data] = [:]
        var total = 0
        var entries = 0
        var buffer = [UInt8](repeating: 0, count: 64 << 10)
        for (entry, stream) in reader.makeStreamingIterator() {
            entries += 1
            guard entries <= maxEntries else { throw APIError(400, "archive has more than \(maxEntries) members") }
            let name = (entry.path ?? "").hasPrefix("./") ? String(entry.path!.dropFirst(2)) : (entry.path ?? "")
            guard entry.fileType == .regular, accept(name) else { continue }
            var data = Data()
            while true {
                let n = buffer.withUnsafeMutableBufferPointer { stream.read($0.baseAddress!, maxLength: $0.count) }
                if n < 0 { throw APIError(400, "archive is damaged at \(name)") }
                if n == 0 { break }
                data.append(contentsOf: buffer[0..<n])
                total += n
                guard data.count <= maxFile else { throw APIError(400, "archive member \(name) is larger than \(maxFile >> 10) KiB") }
                guard total <= maxTotal else { throw APIError(400, "archive is larger than \(maxTotal >> 20) MiB unpacked") }
            }
            out[name] = data
        }
        try reader.throwIfStreamFailed()
        return out
    }

    /// Unpacks an untrusted archive into `dir`, an empty directory. Every path component is
    /// opened relative to its parent with `O_NOFOLLOW` (`openat`, `mkdirat`), so no member
    /// can reach outside `dir`, through `..` or any symlink, even one an earlier member made;
    /// a name that already exists is not reused. Symlinks are kept as links with `links`,
    /// else refused; hard links and devices are refused. Caps count what is actually
    /// written: past `maxBytes` unpacked or `maxEntries` members the archive is rejected.
    /// Files are the Mac user's; what each member's header said is returned, by path.
    @discardableResult
    static func extract(_ file: URL, to dir: URL, links: Bool, maxBytes: Int64, maxEntries: Int = 1_000_000) throws -> [String: Owner] {
        let root = open(dir.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard root >= 0 else { throw APIError(500, "cannot open \(dir.path)") }
        defer { close(root) }
        let reader = try ArchiveReader(file: file)
        var total: Int64 = 0
        var entries = 0
        var buffer = [UInt8](repeating: 0, count: 1 << 20)
        var modes: [(String, mode_t)] = []  // directories get their mode last, once filled
        var owners: [String: Owner] = [:]
        for (entry, stream) in reader.makeStreamingIterator() {
            entries += 1
            guard entries <= maxEntries else { throw APIError(400, "archive has more than \(maxEntries) members") }
            let raw = entry.path ?? ""
            let parts = raw.split(separator: "/").map(String.init).filter { $0 != "." }
            guard !parts.isEmpty else { continue }
            guard !parts.contains(".."), entry.hardlink == nil else { throw APIError(400, "archive member is not allowed: \(raw)") }
            let parent = try openParents(root, Array(parts.dropLast()))
            defer { if parent != root { close(parent) } }
            let name = parts.last!
            let mode = mode_t(entry.permissions & 0o7777)
            owners[parts.joined(separator: "/")] = Owner(uid: entry.owner ?? 0, gid: entry.group ?? 0)
            switch entry.fileType {
            case .directory:
                if mkdirat(parent, name, 0o700) != 0 && errno != EEXIST { throw APIError(400, "cannot make \(raw)") }
                let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard fd >= 0 else { throw APIError(400, "archive member is not a directory: \(raw)") }
                close(fd)
                modes.append((parts.joined(separator: "/"), mode))
            case .regular:
                let fd = openat(parent, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
                guard fd >= 0 else { throw APIError(400, "archive member exists twice or cannot be written: \(raw)") }
                defer { close(fd) }
                while true {
                    let n = buffer.withUnsafeMutableBufferPointer { stream.read($0.baseAddress!, maxLength: $0.count) }
                    if n < 0 { throw APIError(400, "archive is damaged at \(raw)") }
                    if n == 0 { break }
                    total += Int64(n)
                    guard total <= maxBytes else { throw APIError(400, "archive unpacks to more than \(maxBytes >> 20) MiB") }
                    let wrote = buffer.withUnsafeBufferPointer { write(fd, $0.baseAddress!, n) }
                    guard wrote == n else { throw APIError(500, "cannot write \(raw): \(String(cString: strerror(errno)))") }
                }
                fchmod(fd, mode)
            case .symbolicLink:
                guard links, let target = entry.symlinkTarget, !target.isEmpty else {
                    throw APIError(400, "archive member is a symlink, which is not allowed here: \(raw)")
                }
                guard symlinkat(target, parent, name) == 0 else { throw APIError(400, "archive member exists twice: \(raw)") }
            default:
                throw APIError(400, "archive member type is not allowed: \(raw)")
            }
        }
        try reader.throwIfStreamFailed()
        for (path, mode) in modes.reversed() {
            let parts = path.split(separator: "/").map(String.init)
            if let parent = try? openParents(root, Array(parts.dropLast())) {
                let fd = openat(parent, parts.last!, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                if fd >= 0 { fchmod(fd, mode); close(fd) }
                if parent != root { close(parent) }
            }
        }
        return owners
    }

    /// The directory `parts` names under `root`, made as needed, each step `O_NOFOLLOW`:
    /// a symlink anywhere on the way fails instead of being followed. The caller closes it.
    private static func openParents(_ root: Int32, _ parts: [String]) throws -> Int32 {
        var fd = root
        for part in parts {
            if mkdirat(fd, part, 0o755) != 0 && errno != EEXIST { throw APIError(400, "cannot make \(part)") }
            let next = openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if fd != root { close(fd) }
            guard next >= 0 else { throw APIError(400, "archive path goes through a link or a file: \(part)") }
            fd = next
        }
        return fd
    }

    /// What an archive may unpack to: the spooled-body cap, and never so much that the Mac
    /// is left with less than 5 GiB free.
    static func unpackLimit(at dir: URL) -> Int64 {
        let free = Posix.freeBytes(dir) ?? Limits.maxSpooledBytes
        return max(min(Limits.maxSpooledBytes, free - (5 << 30)), 0)
    }
}
