import Foundation

/// `docker cp` via `/containers/{id}/archive` (SPEC FR-18): the guest agent copies files
/// to and from the host, where they are tarred in process.
final class ArchiveService: @unchecked Sendable {
    let containers: ContainerService
    private var embedded: EmbeddedContainers { containers.embedded }

    init(containers: ContainerService) {
        self.containers = containers
    }

    /// The container when it runs (the guest agent copies); nil when it is stopped (its
    /// rootfs is read or rewritten on the Mac, no VM needed).
    private func running(_ ref: String) throws -> ContainerRecord? {
        let rec = try containers.resolve(ref)
        guard rec.state.running else { return nil }
        guard !containers.isPaused(rec.id) else { throw APIError(409, "Container \(rec.id) is paused") }
        return rec
    }

    /// The `X-Docker-Container-Path-Stat` header value: base64 JSON of the path's lstat.
    func stat(_ ref: String, path: String) throws -> String {
        guard let rec = try running(ref) else {
            let s = try containers.whileStopped(ref) { rec, rootfs in
                do { return try CopyUp.stat(rootfs: rootfs, path: Self.trimmed(path)) } catch {
                    throw APIError(404, "Could not find the file \(path) in container \(rec.name)")
                }
            }
            let stat: JSON = [
                "name": .string(Self.baseName(path)), "size": .int(s.size), "mode": .int(Int64(Self.goFileMode(s.mode))),
                "mtime": .string(Timestamp.format(Date(timeIntervalSince1970: Double(s.mtime)))), "linkTarget": .string(s.link),
            ]
            return stat.encoded().base64EncodedString()
        }
        let script = #"stat -c '%s %f %Y' -- "$1" && readlink -- "$1"; true"#
        let r = try guestStat(rec, path: path, script: script)
        let lines = String(decoding: r.out, as: UTF8.self).split(separator: "\n").map(String.init)
        let fields = lines.first?.split(separator: " ").map(String.init) ?? []
        guard r.ok, fields.count == 3, let size = Int64(fields[0]), let raw = UInt32(fields[1], radix: 16),
            let mtime = Double(fields[2])
        else {
            throw APIError(404, "Could not find the file \(path) in container \(rec.name)")
        }
        let stat: JSON = [
            "name": .string(Self.baseName(path)), "size": .int(size), "mode": .int(Int64(Self.goFileMode(raw))),
            "mtime": .string(Timestamp.format(Date(timeIntervalSince1970: mtime))),
            "linkTarget": .string(lines.count > 1 ? lines[1] : ""),
        ]
        return stat.encoded().base64EncodedString()
    }

    /// `stat` in the guest when the image has a shell; otherwise the path is copied out and
    /// stat'ed on the host (correct for any image, slower for big trees).
    private func guestStat(_ rec: ContainerRecord, path: String, script: String) throws
        -> (ok: Bool, out: Data)
    {
        let files = containers.shimFiles(rec.id)
        let body: JSON = ["args": JSON(["sh", "-c", script, "_", path]), "timeout": 10]
        if let r = try? embedded.shim.request(files, "POST", "/exec", body: body.encoded()), let j = JSON.parse(r.body),
            let code = j["exitCode"]?.int, code != 127
        {
            return (code == 0, Data((j["output"]?.string ?? "").utf8))
        }
        let work = files.dir.appending(path: "cp-\(randomHexID().prefix(8))")
        defer { try? FileManager.default.removeItem(at: work) }
        guard let name = try? Self.hostName(path) else { return (false, Data()) }
        let copy = work.appending(path: name)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        guard (try? copyOut(rec, path, to: copy)) != nil, let a = try? FileManager.default.attributesOfItem(atPath: copy.path) else {
            return (false, Data())
        }
        let mode = UInt32((a[.posixPermissions] as? Int) ?? 0o644) | ((a[.type] as? FileAttributeType) == .typeDirectory ? 0o040000 : 0o100000)
        let mtime = Int((a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)
        let size = (a[.size] as? Int) ?? 0
        return (true, Data("\(size) \(String(mode, radix: 16)) \(mtime)\n".utf8))
    }

    private func copyOut(_ rec: ContainerRecord, _ path: String, to host: URL) throws {
        try embedded.shim.call(containers.shimFiles(rec.id), "POST", "/copy-out?src=\(Self.query(path))&dst=\(Self.query(host.path))")
    }

    /// `GET`: a tar whose single top entry is the path's base name. The agent copies the
    /// path out to the host, where it is tarred.
    func get(_ ref: String, path: String, conn: Connection) throws {
        let header = try stat(ref, path: path)
        let rec = try containers.resolve(ref)
        let trimmed = Self.trimmed(path)
        let work = containers.shimFiles(rec.id).dir.appending(path: "cp-\(randomHexID().prefix(8))")
        defer { try? FileManager.default.removeItem(at: work) }
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let name = try Self.hostName(trimmed)
        do {
            if let live = try running(ref) {
                try copyOut(live, trimmed, to: work.appending(path: name))
            } else {
                try containers.whileStopped(ref) { _, rootfs in try CopyUp.copyOut(rootfs: rootfs, path: trimmed, into: work, as: name) }
            }
        } catch let e as APIError where e.status == 409 { throw e } catch {
            throw APIError(404, "Could not find the file \(path) in container \(rec.name)")
        }
        let archive = work.appending(path: "out.tar")
        try Tar.create(archive, base: work, names: [name])
        let handle = try FileHandle(forReadingFrom: archive)
        defer { try? handle.close() }
        conn.beginChunked(contentType: "application/x-tar", extra: [("X-Docker-Container-Path-Stat", header)])
        while let data = try handle.read(upToCount: 1 << 20), !data.isEmpty {
            if !conn.chunk(data) { break }
        }
        conn.endChunked()
    }

    /// `PUT`: extracts the tar body into the existing directory `path`. The tar is unpacked
    /// on the host (`Tar.extract` refuses `..` and writing through symlinks), then copied in.
    /// Ownership is as on Docker: each member's uid and gid from its header, or, with
    /// `copyUIDGID`, the container's user (`docker cp -a`).
    /// `archive` is the request body, spooled to a file: it may be far larger than memory.
    func put(_ ref: String, path: String, tar archive: URL, copyUIDGID: Bool = false) throws {
        let found = try containers.resolve(ref)
        // Docker refuses a destination directory that does not exist.
        guard (try? stat(ref, path: path)) != nil else {
            throw APIError(404, "Could not find the file \(path) in container \(found.name)")
        }
        let files = containers.shimFiles(found.id)
        let scratch = files.dir.appending(path: "cp-\(randomHexID().prefix(8))")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let work = scratch.appending(path: "tree")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        var owners: [String: Tar.Owner]
        do { owners = try Tar.extract(archive, to: work, links: true, maxBytes: Tar.unpackLimit(at: work)) } catch let e as APIError { throw e } catch {
            throw APIError(400, "invalid tar archive")
        }
        if copyUIDGID {
            let user = try containerUser(found)
            owners = owners.mapValues { _ in user }
        }
        guard let rec = try running(ref) else {
            try putStopped(ref, path: Self.trimmed(path), work: work, owners: owners, scratch: scratch)
            return
        }
        // The tree goes to the guest as one tar+gzip with the archive's links and owners,
        // extracted there relative to directory descriptors: a process in the container
        // swapping a directory for a link mid-copy cannot redirect a write or an owner.
        let names = try FileManager.default.contentsOfDirectory(atPath: work.path)
        guard !names.isEmpty else { return }
        let tar = scratch.appending(path: "in.tar.gz")
        try Tar.create(tar, base: work, names: names, gzip: true, owner: { owners[$0] ?? .root })
        do {
            try embedded.shim.call(files, "POST", "/copy-in-archive?src=\(Self.query(tar.path))&dst=\(Self.query(Self.trimmed(path)))")
        } catch let e as APIError where e.status == 404 {
            throw APIError(409, "pratico: the VM of \(rec.name) was started by an older pratico, which copies without the archive's owners; restart it to copy into it")
        }
    }

    /// A stopped container: the files are written on the Mac, each to the filesystem it
    /// lands on, as Docker writes through a container's mounts. Under a disk volume's mount
    /// point they go into that volume's disk, the rest into the rootfs; a share or bind
    /// mount is a Mac folder pratico does not write for a stopped container.
    private func putStopped(_ ref: String, path: String, work: URL, owners: [String: Tar.Owner], scratch: URL) throws {
        let rec = try containers.resolve(ref)
        let mounts = try containers.mounts(rec.hostConfig).filter { $0.tmpfs == nil }
        func under(_ p: String, _ dir: String) -> String? {
            if p == dir { return "" }
            let base = dir == "/" ? "/" : dir + "/"
            return p.hasPrefix(base) ? String(p.dropFirst(base.count)) : nil
        }
        // Where `path` itself lies: the deepest mount holding it, else the rootfs.
        let holder = mounts.filter { under(path, $0.destination) != nil }.max { $0.destination.count < $1.destination.count }
        // Mounts below `path` take their part of the tree, deepest first.
        var pieces: [(ContainerService.Mount?, URL)] = []
        for m in mounts.sorted(by: { $0.destination.count > $1.destination.count }) {
            guard let rel = under(m.destination, path), !rel.isEmpty else { continue }
            // The tree is the archive's: each step to the mount point is lstat()ed, so a
            // member that is a link (`workspace -> ~/Documents`) never moves a Mac folder.
            guard let src = try Self.realDirectory(work, rel) else { continue }
            let piece = scratch.appending(path: "mount-\(pieces.count)")
            try FileManager.default.moveItem(at: src, to: piece)
            let rebased = owners.reduce(into: [String: Tar.Owner]()) { out, kv in
                if kv.key.hasPrefix(rel + "/") { out[String(kv.key.dropFirst(rel.count + 1))] = kv.value }
            }
            pieces.append((m, try layer(piece, prefix: "", owners: rebased, scratch: scratch)))
        }
        let rest = holder.flatMap { under(path, $0.destination) } ?? String(path.drop(while: { $0 == "/" }))
        if !(try FileManager.default.contentsOfDirectory(atPath: work.path)).isEmpty {
            pieces.append((holder, try layer(work, prefix: rest.isEmpty ? "" : rest + "/", owners: owners, scratch: scratch)))
        }
        for (mount, file) in pieces {
            guard let mount else {
                let written = try ExecOrigin.members(file)
                try containers.whileStopped(ref) { rec, rootfs in try containers.rewritingRootfs(rec, written: written) { try RootfsEdit.add(file, to: rootfs) } }
                continue
            }
            guard !mount.readOnly else { throw APIError(400, "mounted volume is marked read-only") }
            guard mount.disk, let name = mount.volume else {
                throw APIError(409, "pratico: \(mount.destination) is a folder from the Mac (\(mount.volume.map { "share \($0)" } ?? mount.source)); copy into it on the Mac, or start the container and copy then")
            }
            try containers.whileStopped(ref) { _, _ in
                try containers.editingDisk(name) { disk in
                    if FileManager.default.fileExists(atPath: disk.path) { try RootfsEdit.add(file, to: disk) } else { try containers.volumes.formatDisk(name, content: file) }
                }
            }
        }
    }

    /// `base/rel` when the archive made it a directory all the way down; nil when it holds
    /// nothing there. A link or a file on the way is refused, as Docker cannot put one over
    /// a mount point either.
    static func realDirectory(_ base: URL, _ rel: String) throws -> URL? {
        var cur = base
        for part in rel.split(separator: "/") {
            cur = cur.appending(path: String(part))
            var st = Darwin.stat()
            guard lstat(cur.path, &st) == 0 else { return nil }
            guard st.st_mode & S_IFMT == S_IFDIR else {
                throw APIError(400, "cannot copy over a mount point: \(rel) in the archive is not a directory")
            }
        }
        return cur
    }

    /// A layer tar of what `base` holds, each member owned as the archive said.
    private func layer(_ base: URL, prefix: String, owners: [String: Tar.Owner], scratch: URL) throws -> URL {
        let file = scratch.appending(path: "layer-\(randomHexID().prefix(8)).tar")
        let names = try FileManager.default.contentsOfDirectory(atPath: base.path)
        try Tar.create(file, base: base, names: names, prefix: prefix, owner: { owners[$0] ?? .root })
        return file
    }

    /// The uid and gid of the container's `User`, as `docker cp -a` uses them: names
    /// looked up in the container's `/etc/passwd` and `/etc/group`, read from its rootfs on
    /// the Mac (after the guest's writes are flushed, when it runs).
    private func containerUser(_ rec: ContainerRecord) throws -> Tar.Owner {
        let user = rec.config["User"]?.string ?? ""
        guard !user.isEmpty else { return .root }
        // Read on the Mac, capped, as a regular file only: the container writes these.
        if rec.state.running { _ = try? embedded.shim.call(containers.shimFiles(rec.id), "POST", "/sync") }
        let rootfs = containers.shimFiles(rec.id).dir.appending(path: "rootfs.ext4")
        func read(_ file: String) -> String { CopyUp.read(rootfs: rootfs, path: file).map { String(decoding: $0, as: UTF8.self) } ?? "" }
        guard let owner = Self.owner(of: user, passwd: read("/etc/passwd"), group: read("/etc/group")) else {
            throw APIError(400, "unable to find user \(user): no matching entries in passwd file")
        }
        return owner
    }

    /// `user[:group]`, each a name or a number, against passwd and group files; a user's
    /// group defaults to its primary one (0 for a number not in passwd).
    static func owner(of spec: String, passwd: String, group: String) -> Tar.Owner? {
        let (u, g) = spec.splitOnce(":")
        func table(_ text: String) -> [[Substring]] {
            text.split(separator: "\n").map { $0.split(separator: ":", omittingEmptySubsequences: false) }.filter { $0.count >= 3 }
        }
        let users = table(passwd), groups = table(group)
        let entry = users.first { $0[0] == u || (UInt32(u) != nil && $0[2] == u) }
        guard let uid = UInt32(u) ?? entry.flatMap({ UInt32($0[2]) }) else { return nil }
        var gid = entry.flatMap { $0.count > 3 ? UInt32($0[3]) : nil } ?? 0
        if let g, !g.isEmpty {
            guard let found = UInt32(g) ?? groups.first(where: { $0[0] == g }).flatMap({ UInt32($0[2]) }) else { return nil }
            gid = found
        }
        return Tar.Owner(uid: uid, gid: gid)
    }

    /// A path as a query value for the shim's control socket.
    static func query(_ path: String) -> String {
        path.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "/._-"))) ?? path
    }

    /// `/a/b/` is `/a/b`; `/` stays.
    static func trimmed(_ path: String) -> String { path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path }

    /// A base name that is safe as one host path component: never empty, `.`, or `..`
    /// (`work/..` would land outside the temporary directory).
    static func hostName(_ path: String) throws -> String {
        let name = baseName(path)
        if name == "/" { return "rootfs" }
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else {
            throw APIError(400, "invalid path: \(path)")
        }
        return name
    }

    static func baseName(_ path: String) -> String {
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? "/" : name
    }

    /// Unix `st_mode` → Go `os.FileMode`, the encoding Docker clients expect.
    static func goFileMode(_ m: UInt32) -> UInt32 {
        var out = m & 0o777
        switch m & 0o170000 {
        case 0o040000: out |= 1 << 31  // dir
        case 0o120000: out |= 1 << 27  // symlink
        case 0o010000: out |= 1 << 25  // named pipe
        case 0o140000: out |= 1 << 24  // socket
        case 0o020000: out |= 1 << 26 | 1 << 21  // char device
        case 0o060000: out |= 1 << 26  // block device
        default: break
        }
        if m & 0o4000 != 0 { out |= 1 << 23 }
        if m & 0o2000 != 0 { out |= 1 << 22 }
        if m & 0o1000 != 0 { out |= 1 << 20 }
        return out
    }
}
