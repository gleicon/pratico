import ContainerizationArchive
import Foundation

/// tar in process, through ContainerizationArchive (libarchive); pratico runs no tar binary.
enum Tar {
    /// Writes `names`, relative to `base`, with everything under them. Symlinks are stored as
    /// links, never followed, wherever they point, as Docker's `cp` does; files are streamed.
    static func create(_ file: URL, base: URL, names: [String], gzip: Bool = false) throws {
        let writer = try ArchiveWriter(configuration: ArchiveWriterConfiguration(format: .pax, filter: gzip ? .gzip : .none))
        try writer.open(file: file)
        for name in names { try add(writer.makeTransactionWriter(), base: base, path: name) }
        try writer.finishEncoding()
    }

    private static func add(_ w: ArchiveWriterTransaction, base: URL, path: String) throws {
        let full = base.appending(path: path).path
        var st = stat()
        guard lstat(full, &st) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ENOENT) }
        let entry = WriteEntry()
        entry.path = path
        entry.permissions = st.st_mode & 0o7777
        entry.owner = st.st_uid
        entry.group = st.st_gid
        entry.modificationDate = Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec))
        entry.size = 0
        switch st.st_mode & S_IFMT {
        case S_IFDIR:
            entry.fileType = .directory
            try w.writeHeader(entry: entry)
            try w.finish()
            for child in try FileManager.default.contentsOfDirectory(atPath: full).sorted() {
                try add(w, base: base, path: path + "/" + child)
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

    /// Unpacks `file` into `dir`. Members that would land outside `dir`, by `..` or through a
    /// symlink, are refused and the archive is rejected.
    static func extract(_ file: URL, to dir: URL) throws {
        let rejected = try ArchiveReader(file: file).extractContents(to: dir)
        guard rejected.isEmpty else { throw APIError(400, "archive member escapes the destination: \(rejected[0])") }
    }
}
