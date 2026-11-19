import ContainerizationEXT4
import Foundation
import SystemPackage

/// `docker rename`, `top`, `export`, `diff`, and `update`.
extension ContainerService {
    /// `POST /containers/{id}/rename?name=`. DNS answers the new name at once; the
    /// container's hostname stays, as on Docker.
    func rename(_ ref: String, to requested: String) throws {
        let rec = try resolve(ref)
        let name = requested.hasPrefix("/") ? String(requested.dropFirst()) : requested
        guard !name.isEmpty else { throw APIError(400, "Neither old nor new names may be empty") }
        guard name != rec.name else { throw APIError(409, "Renaming a container with the same name as its current name") }
        let old = try renameRecord(rec.id, to: name)
        emit(try resolve(rec.id), "rename", ["oldName": "/\(old)"])
    }

    /// `GET /containers/{id}/top?ps_args=`: the image's `ps`, run in the container. A VM
    /// has no host `ps` to look in from outside, so an image without one cannot answer.
    func top(_ ref: String, psArgs: String?) throws -> JSON {
        let rec = try resolve(ref)
        guard rec.state.running else { throw APIError(409, "Container \(rec.id) is not running") }
        let args = (psArgs ?? "-ef").split(separator: " ").map(String.init)
        let body: JSON = ["args": JSON(["ps"] + args), "timeout": 10, "limit": .int(1 << 20)]
        let r = try embedded.shim.request(shimFiles(rec.id), "POST", "/exec", body: body.encoded())
        let j = JSON.parse(r.body) ?? [:]
        let output = j["output"]?.string ?? ""
        guard j["exitCode"]?.int == 0 else {
            throw APIError(500, output.contains("not found") ? "pratico: docker top runs the image's ps, and this image has none"
                : "ps \(args.joined(separator: " ")) failed: \(output)")
        }
        // Docker lists processes from the host; the `ps` that answered here is not one of them.
        return try Self.psTable(output, hiding: (["ps"] + args).joined(separator: " "))
    }

    /// `ps` output as Docker's `{"Titles", "Processes"}`: the last column keeps its spaces.
    /// The output comes from the image, so it is checked, never asserted.
    static func psTable(_ output: String, hiding command: String) throws -> JSON {
        var lines = output.split(separator: "\n").map(String.init)
        guard !lines.isEmpty else { throw APIError(500, "ps printed nothing") }
        let titles = lines.removeFirst().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !titles.isEmpty else { throw APIError(500, "ps printed no column titles") }
        // Filtered as strings: `JSON` takes a `nil` literal as `.null`, which would keep the row.
        let rows = lines.map { columns($0, count: titles.count) }.filter { $0.last != command }.map(JSON.init)
        return ["Titles": JSON(titles), "Processes": .array(rows)]
    }

    /// The first `count - 1` whitespace-separated fields, then the rest of the line as one.
    static func columns(_ line: String, count: Int) -> [String] {
        var fields: [String] = []
        var rest = Substring(line)
        while fields.count < count - 1 {
            rest = rest.drop { $0 == " " || $0 == "\t" }
            guard let end = rest.firstIndex(where: { $0 == " " || $0 == "\t" }) else { break }
            fields.append(String(rest[..<end]))
            rest = rest[end...]
        }
        let last = rest.trimmingCharacters(in: .whitespaces)
        if !last.isEmpty { fields.append(last) }
        return fields
    }

    /// `GET /containers/{id}/export`: the root filesystem as a tar.
    func export(_ ref: String, conn: Connection) throws {
        let tar = try withQuietRootfs(ref) { rec, rootfs -> URL in
            let out = shimFiles(rec.id).dir.appending(path: "export-\(UUID().uuidString).tar")
            // Streamed and bounded, as a commit layer is: the upstream exporter reads each file
            // whole into memory, and a container can make one that claims exabytes.
            let all = try RootfsTree.read(rootfs).keys.sorted().map { RootfsTree.Change(path: $0, kind: 1) }
            do { try CommitLayer.write(all, from: rootfs, to: out, maxBytes: Tar.unpackLimit(at: out.deletingLastPathComponent())) } catch {
                try? FileManager.default.removeItem(at: out)
                throw error
            }
            return out
        }
        defer { try? FileManager.default.removeItem(at: tar) }
        let h = try FileHandle(forReadingFrom: tar)
        defer { try? h.close() }
        conn.beginChunked(contentType: "application/x-tar")
        while case let data = h.readData(ofLength: 1 << 20), !data.isEmpty {
            if !conn.chunk(data) { break }
        }
        conn.endChunked()
    }

    /// `GET /containers/{id}/changes`: what the container changed against its image's
    /// unpacked copy (Kind 0 changed, 1 added, 2 deleted).
    func changes(_ ref: String) throws -> [JSON] {
        let rec = try resolve(ref)
        let base = embedded.rootfsCache.appending(path: "\(rec.imageId.dropFirst(7)).ext4")
        guard FileManager.default.fileExists(atPath: base.path) else {
            throw APIError(409, "pratico: the image of \(rec.name) is no longer stored, so there is nothing to compare with")
        }
        let image = try RootfsTree.read(base)
        let mine = try withQuietRootfs(rec.id) { _, rootfs in try RootfsTree.read(rootfs) }
        return RootfsTree.changes(from: image, to: mine).map { ["Path": .string($0.path), "Kind": .int(Int64($0.kind))] }
    }

    /// `POST /containers/{id}/update`. The restart policy changes at once, and so do the
    /// limits of a running container, inside its VM: up to the vCPUs and memory it booted
    /// with, as Virtualization cannot add either to a running VM. A stopped container takes
    /// them at its next start. The container cannot start while it is updated.
    func update(_ ref: String, _ body: JSON) throws -> JSON {
        let changed = try holding(ref, "docker update is in progress") { rec, running -> ContainerRecord in
            var host = rec.hostConfig.object ?? [:]
            var limits = false
            for (key, value) in body.object ?? [:] where Self.updatable.contains(key) && Self.isSet(value) {
                host[key] = value
                limits = limits || key != "RestartPolicy"
            }
            let options = try RunOptions.parse(host: .object(host), config: rec.config, defaultCPUs: config.defaultCPUs, defaultMemoryMiB: config.defaultMemoryMiB)
            if running && limits { try setLiveLimits(rec, options) }
            update(rec.id) { $0.hostConfig = .object(host) }
            return try resolve(rec.id)
        }
        emit(changed, "update")
        return ["Warnings": []]
    }

    /// Writes the limits into the running VM's cgroup, through its shim.
    private func setLiveLimits(_ rec: ContainerRecord, _ options: RunOptions) throws {
        let files = shimFiles(rec.id)
        guard let data = try? Data(contentsOf: files.spec), let booted = try? JSONDecoder().decode(ShimSpec.self, from: data) else {
            throw APIError(500, "pratico: cannot read the spec \(rec.name) was started with")
        }
        guard options.cpus <= booted.cpus, options.memoryMiB <= booted.memoryMiB else {
            throw APIError(409, "pratico: \(rec.name)'s VM started with \(booted.cpus) vCPUs and \(booted.memoryMiB) MiB, and a running VM cannot grow; limits up to that change at once. For more, stop it, update it, and start it")
        }
        do {
            _ = try embedded.shim.request(files, "POST", "/limits", body: JSONEncoder().encode(CgroupLimits(options)))
        } catch let e as APIError where e.status == 404 {
            throw APIError(409, "pratico: \(rec.name) was started by an older pratico, which cannot change its limits while it runs; restart it, then update it")
        }
    }

    /// What `docker update` may set (Docker's `UpdateConfig`); others are refused by
    /// RunOptions as at create when set.
    static let updatable: Set<String> = [
        "CpuShares", "Memory", "NanoCpus", "CpuPeriod", "CpuQuota", "CpusetCpus", "CpusetMems", "MemoryReservation",
        "MemorySwap", "PidsLimit", "RestartPolicy", "BlkioWeight", "KernelMemory", "OomKillDisable", "CpuRealtimePeriod",
        "CpuRealtimeRuntime", "MemorySwappiness",
    ]

    /// The CLI sends every field of `UpdateConfig`; zero and empty mean "unchanged".
    private static func isSet(_ v: JSON) -> Bool {
        switch v {
        case .null: false
        case .bool(let b): b
        case .string(let s): !s.isEmpty
        case .object(let o): !(o["Name"]?.string ?? "").isEmpty || !o.isEmpty && o["Name"] == nil
        case .array(let a): !a.isEmpty
        default: (v.int ?? 0) != 0
        }
    }
}

/// A rootfs as paths and what `docker diff` compares: type and mode, owner, size, mtime,
/// and a link's target.
enum RootfsTree {
    struct Entry: Equatable {
        var mode: UInt16
        var uid: UInt32
        var gid: UInt32
        var size: Int64
        var mtime: UInt32
        var link: String
    }

    struct Change: Equatable {
        var path: String
        var kind: Int  // 0 changed, 1 added, 2 deleted
    }

    /// Entries in one rootfs a walk reads before giving up: far beyond any image.
    static let maxEntries = 2_000_000
    static let maxDepth = 128

    static func read(_ rootfs: URL) throws -> [String: Entry] {
        let reader = try EXT4.EXT4Reader(blockDevice: FilePath(rootfs.path))
        var out: [String: Entry] = [:]
        var pending: [(path: String, depth: Int)] = [("/", 0)]
        while let (dir, depth) = pending.popLast() {
            precondition(depth <= maxDepth, "walk deeper than its bound")
            for name in try reader.listDirectory(FilePath(dir)) where !name.isEmpty && name != "." && name != ".." && !name.contains("/") {
                let path = dir == "/" ? "/" + name : dir + "/" + name
                guard out.count < maxEntries else { throw APIError(500, "pratico: more than \(maxEntries) files to compare") }
                let (_, inode) = try reader.stat(FilePath(path), followSymlinks: false)
                let isLink = inode.mode & CopyUp.typeMask == CopyUp.linkType
                let size = Int64(inode.sizeLow) | (Int64(inode.sizeHigh) << 32)
                out[path] = Entry(mode: inode.mode, uid: UInt32(inode.uidHigh) << 16 | UInt32(inode.uid), gid: UInt32(inode.gidHigh) << 16 | UInt32(inode.gid), size: size, mtime: inode.mtime,
                                  link: isLink ? (CopyUp.linkTarget(reader, FilePath(path), inode) ?? "") : "")
                if inode.mode & CopyUp.typeMask == CopyUp.dirType && depth < maxDepth && path != "/lost+found" {
                    pending.append((path, depth + 1))
                }
            }
        }
        return out
    }

    /// Files pratico writes into every container, which Docker bind-mounts and never lists.
    static let managed: Set<String> = ["/etc/hosts", "/etc/hostname", "/etc/resolv.conf"]

    /// Docker's view, by path: added, deleted (a deleted directory lists only itself), and
    /// changed, where a directory counts as changed when something under it did or its
    /// mode or owner did, not for its timestamps.
    static func changes(from image: [String: Entry], to mine: [String: Entry]) -> [Change] {
        var found: [String: Int] = [:]
        for (path, entry) in mine where !managed.contains(path) {
            guard let old = image[path] else { found[path] = 1; continue }
            let isDir = entry.mode & CopyUp.typeMask == CopyUp.dirType
            let same = isDir ? (old.mode, old.uid, old.gid) == (entry.mode, entry.uid, entry.gid) : old == entry
            if !same { found[path] = 0 }
        }
        for path in image.keys where mine[path] == nil && !managed.contains(path) {
            let parent = (path as NSString).deletingLastPathComponent
            if parent == "/" || mine[parent] != nil { found[path] = 2 }
        }
        for path in Array(found.keys) {
            var dir = (path as NSString).deletingLastPathComponent
            var hops = 0
            while dir != "/" && !dir.isEmpty {
                precondition(hops <= maxDepth, "path deeper than any walk")
                if found[dir] == nil && image[dir] != nil && mine[dir] != nil { found[dir] = 0 }
                dir = (dir as NSString).deletingLastPathComponent
                hops += 1
            }
        }
        return found.map { Change(path: $0.key, kind: $0.value) }.sorted { $0.path < $1.path }
    }
}
