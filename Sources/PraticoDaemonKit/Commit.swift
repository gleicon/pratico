import ContainerizationArchive
import ContainerizationEXT4
import CryptoKit
import Foundation
import SystemPackage

/// `docker commit` (D-47): what the container changed against its image becomes one new
/// layer on top of the image's, with the container's config (and `--change`) as the new
/// image's. The layer holds the files `docker diff` reports, deletions as OCI whiteouts.
extension ContainerService {
    struct CommitRequest {
        var repo: String
        var tag: String
        var comment: String
        var author: String
        var pause: Bool
        var changes: [String]
        var config: JSON
    }

    func commit(_ ref: String, _ r: CommitRequest) throws -> String {
        let rec = try resolve(ref)
        guard let base = images.resolve(rec.imageId)?.image else {
            throw APIError(409, "pratico: the image of \(rec.name) is no longer stored, so there is nothing to commit onto")
        }
        let cache = embedded.rootfsCache.appending(path: "\(rec.imageId.dropFirst(7)).ext4")
        guard FileManager.default.fileExists(atPath: cache.path) else {
            throw APIError(409, "pratico: the unpacked copy of \(rec.name)'s image is gone; pull the image again")
        }
        let work = FileManager.default.temporaryDirectory.appending(path: "pratico-commit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let layer = work.appending(path: "layer.tar")
        let imageTree = try RootfsTree.read(cache)
        try withQuietRootfs(rec.id, pause: r.pause) { _, rootfs in
            let changes = RootfsTree.changes(from: imageTree, to: try RootfsTree.read(rootfs))
            try CommitLayer.write(changes, from: rootfs, to: layer, maxBytes: Tar.unpackLimit(at: work))
        }
        var config = try Dockerfile.apply(r.changes, to: Self.committedConfig(rec, overrides: r.config))
        config["Image"] = nil
        let target = r.repo.isEmpty ? nil : ImageRef.normalize(ImageRef.join(r.repo, tag: r.tag.isEmpty ? "latest" : r.tag))
        let id = try images.commit(onto: base, layer: layer, config: .object(config), comment: r.comment, author: r.author,
                                   createdBy: ([rec.path] + rec.args).joined(separator: " "), as: target, work: work)
        emit(rec, "commit", ["comment": r.comment])
        return id
    }

    /// The container's config as an image's: what `docker run` would start it with.
    static func committedConfig(_ rec: ContainerRecord, overrides: JSON) -> [String: JSON] {
        let keys = ["Hostname", "Domainname", "User", "ExposedPorts", "Tty", "OpenStdin", "StdinOnce", "Env", "Cmd",
                    "Healthcheck", "ArgsEscaped", "Volumes", "WorkingDir", "Entrypoint", "OnBuild", "Labels", "StopSignal",
                    "StopTimeout", "Shell"]
        var out: [String: JSON] = [:]
        for key in keys {
            let mine = overrides[key].flatMap { $0 == .null ? nil : $0 }
            if let value = mine ?? rec.config[key], value != .null { out[key] = value }
        }
        // The hostname is the container's own short ID, not something images carry.
        out["Hostname"] = nil
        return out
    }
}

/// A tar of entries read from a rootfs, streamed a MiB at a time: an uncompressed OCI
/// layer (changed and added entries, deletions as `.wh.` whiteouts) or a whole export.
/// The rootfs is the container's, so its file sizes are not trusted: a sparse file can
/// claim exabytes, and every byte written counts against `maxBytes` (free disk).
enum CommitLayer {
    static func write(_ changes: [RootfsTree.Change], from rootfs: URL, to file: URL, maxBytes: Int64) throws {
        guard changes.count <= 2 * RootfsTree.maxEntries else {
            throw APIError(500, "pratico: more than \(2 * RootfsTree.maxEntries) changes to write")
        }
        let reader = try EXT4.EXT4Reader(blockDevice: FilePath(rootfs.path))
        let writer = try ArchiveWriter(configuration: ArchiveWriterConfiguration(format: .pax, filter: .none))
        try writer.open(file: file)
        let w = try writer.makeTransactionWriter()
        var left = maxBytes
        for change in changes {
            if change.kind == 2 {
                let parent = (change.path as NSString).deletingLastPathComponent
                let name = (change.path as NSString).lastPathComponent
                let entry = WriteEntry()
                entry.path = String((parent == "/" ? "" : parent + "/").dropFirst()) + ".wh." + name
                entry.fileType = .regular
                entry.permissions = 0o644
                entry.size = 0
                try w.writeHeader(entry: entry)
                try w.finish()
            } else {
                try add(change.path, reader, w, budget: &left)
            }
        }
        try writer.finishEncoding()
    }

    private static func add(_ path: String, _ reader: EXT4.EXT4Reader, _ w: ArchiveWriterTransaction, budget left: inout Int64) throws {
        let (_, inode) = try reader.stat(FilePath(path), followSymlinks: false)
        let entry = WriteEntry()
        entry.path = String(path.dropFirst())
        entry.permissions = mode_t(inode.mode & 0o7777)
        entry.owner = uid_t(inode.uidHigh) << 16 | uid_t(inode.uid)
        entry.group = gid_t(inode.gidHigh) << 16 | gid_t(inode.gid)
        entry.modificationDate = Date(timeIntervalSince1970: TimeInterval(inode.mtime))
        entry.size = 0
        switch inode.mode & CopyUp.typeMask {
        case CopyUp.dirType:
            entry.fileType = .directory
            try w.writeHeader(entry: entry)
        case CopyUp.linkType:
            entry.fileType = .symbolicLink
            entry.symlinkTarget = CopyUp.linkTarget(reader, FilePath(path), inode) ?? ""
            try w.writeHeader(entry: entry)
        case CopyUp.fileType:
            let size = UInt64(inode.sizeLow) | (UInt64(inode.sizeHigh) << 32)
            guard size <= UInt64(max(left, 0)) else {
                throw APIError(507, "pratico: \(path) holds \(size) bytes, more than the \(max(left, 0)) left for this archive on the Mac's disk")
            }
            left -= Int64(size)
            entry.fileType = .regular
            entry.size = Int64(size)
            try w.writeHeader(entry: entry)
            var offset: UInt64 = 0
            while offset < size {
                let chunk = try reader.readFile(at: FilePath(path), offset: offset, count: Int(min(size - offset, 1 << 20)), followSymlinks: false)
                guard !chunk.isEmpty else { throw APIError(500, "pratico: \(path) ended before its size") }
                try chunk.withUnsafeBytes { try w.writeChunk(data: $0) }
                offset += UInt64(chunk.count)
            }
        default:
            throw APIError(500, "pratico: docker commit stores files, directories, and links; \(path) is a device, FIFO, or socket")
        }
        try w.finish()
    }
}

/// `docker commit --change`: the Dockerfile instructions Docker accepts there.
enum Dockerfile {
    static let instructions: Set<String> = ["CMD", "ENTRYPOINT", "ENV", "EXPOSE", "LABEL", "ONBUILD", "STOPSIGNAL", "USER", "VOLUME", "WORKDIR"]

    static func apply(_ lines: [String], to config: [String: JSON]) throws -> [String: JSON] {
        var c = config
        for line in lines.flatMap({ $0.split(separator: "\n").map(String.init) }) where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let (word, rest) = trimmed.splitOnce(" ")
            let op = word.uppercased(), arg = (rest ?? "").trimmingCharacters(in: .whitespaces)
            guard instructions.contains(op) else { throw APIError(400, "\(word) is not a valid change command") }
            switch op {
            case "CMD", "ENTRYPOINT": c[op == "CMD" ? "Cmd" : "Entrypoint"] = JSON(command(arg))
            case "ENV", "LABEL":
                let pairs = try keyValues(arg, op)
                if op == "ENV" {
                    let keys = Set(pairs.map(\.0))
                    c["Env"] = JSON((c["Env"]?.strings ?? []).filter { !keys.contains($0.splitOnce("=").0) } + pairs.map { "\($0.0)=\($0.1)" })
                } else {
                    var labels = c["Labels"]?.object ?? [:]
                    for (k, v) in pairs { labels[k] = .string(v) }
                    c["Labels"] = .object(labels)
                }
            case "EXPOSE", "VOLUME":
                let key = op == "EXPOSE" ? "ExposedPorts" : "Volumes"
                var set = c[key]?.object ?? [:]
                let items = arg.hasPrefix("[") ? (JSON.parse(Data(arg.utf8))?.strings ?? []) : arg.split(separator: " ").map(String.init)
                for item in items { set[op == "EXPOSE" && !item.contains("/") ? item + "/tcp" : item] = [:] }
                c[key] = .object(set)
            case "ONBUILD": c["OnBuild"] = JSON((c["OnBuild"]?.strings ?? []) + [arg])
            case "STOPSIGNAL": c["StopSignal"] = .string(arg)
            case "USER": c["User"] = .string(arg)
            default: c["WorkingDir"] = .string(arg)  // WORKDIR
            }
        }
        return c
    }

    /// Exec form (`["a", "b"]`) as is; shell form through `/bin/sh -c`, as Docker does.
    private static func command(_ arg: String) -> [String] {
        if arg.hasPrefix("["), let list = JSON.parse(Data(arg.utf8))?.strings { return list }
        return ["/bin/sh", "-c", arg]
    }

    /// `K=V K2="V 2"`, or the old `K V` form.
    private static func keyValues(_ arg: String, _ op: String) throws -> [(String, String)] {
        guard arg.contains("=") else {
            let (k, v) = arg.splitOnce(" ")
            guard !k.isEmpty else { throw APIError(400, "\(op) needs a name") }
            return [(k, v ?? "")]
        }
        var out: [(String, String)] = []
        var rest = Substring(arg)
        while !rest.isEmpty {
            rest = rest.drop { $0 == " " }
            guard let eq = rest.firstIndex(of: "=") else { break }
            let key = String(rest[..<eq])
            rest = rest[rest.index(after: eq)...]
            var value = ""
            if rest.first == "\"" {
                rest = rest.dropFirst()
                guard let close = rest.firstIndex(of: "\"") else { throw APIError(400, "\(op): unterminated quote") }
                value = String(rest[..<close])
                rest = rest[rest.index(after: close)...]
            } else {
                let end = rest.firstIndex(of: " ") ?? rest.endIndex
                value = String(rest[..<end])
                rest = rest[end...]
            }
            guard !key.isEmpty else { throw APIError(400, "\(op) needs a name") }
            out.append((key, value))
        }
        return out
    }
}
