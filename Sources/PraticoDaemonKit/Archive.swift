import Foundation

/// `docker cp` via `/containers/{id}/archive` (SPEC FR-18, D-17). The Apple runtime has
/// no file API, so this runs `stat` and `tar` inside the running container.
final class ArchiveService: @unchecked Sendable {
    let runtime: AppleContainer
    let containers: ContainerService

    init(runtime: AppleContainer, containers: ContainerService) {
        self.runtime = runtime
        self.containers = containers
    }

    private func running(_ ref: String) throws -> ContainerRecord {
        let rec = try containers.resolve(ref)
        guard rec.state.running else {
            throw APIError(409, "copying files with a stopped container is not supported yet: \(rec.id)")
        }
        guard !containers.isPaused(rec.id) else { throw APIError(409, "Container \(rec.id) is paused") }
        return rec
    }

    /// The `X-Docker-Container-Path-Stat` header value: base64 JSON of the path's lstat.
    func stat(_ ref: String, path: String) throws -> String {
        let rec = try running(ref)
        let script = #"stat -c '%s %f %Y' -- "$1" && readlink -- "$1"; true"#
        let r: (ok: Bool, out: Data)
        if let embedded = containers.embedded {
            r = try embeddedStat(rec, path: path, script: script, embedded)
        } else {
            let p = runtime.run(["exec", rec.appleId, "sh", "-c", script, "_", path])
            r = (p.ok, p.stdout)
        }
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

    /// Embedded stat: `stat` in the guest when the image has a shell; otherwise the path is
    /// copied out and stat'ed on the host (correct for any image, slower for big trees).
    private func embeddedStat(_ rec: ContainerRecord, path: String, script: String, _ embedded: EmbeddedContainers) throws
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
        let copy = work.appending(path: Self.baseName(path))
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        guard (try? copyOut(rec, path, to: copy, embedded)) != nil, let a = try? FileManager.default.attributesOfItem(atPath: copy.path) else {
            return (false, Data())
        }
        let mode = UInt32((a[.posixPermissions] as? Int) ?? 0o644) | ((a[.type] as? FileAttributeType) == .typeDirectory ? 0o040000 : 0o100000)
        let mtime = Int((a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)
        let size = (a[.size] as? Int) ?? 0
        return (true, Data("\(size) \(String(mode, radix: 16)) \(mtime)\n".utf8))
    }

    private func copyOut(_ rec: ContainerRecord, _ path: String, to host: URL, _ embedded: EmbeddedContainers) throws {
        let q = { (s: String) in s.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "/._-"))) ?? s }
        try embedded.shim.call(containers.shimFiles(rec.id), "POST", "/copy-out?src=\(q(path))&dst=\(q(host.path))")
    }

    /// `GET` on the embedded runtime: the agent copies the path out to the host, which tars it.
    private func getEmbedded(_ rec: ContainerRecord, path: String, header: String, _ embedded: EmbeddedContainers, _ conn: Connection) throws {
        let trimmed = path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
        let work = containers.shimFiles(rec.id).dir.appending(path: "cp-\(randomHexID().prefix(8))")
        defer { try? FileManager.default.removeItem(at: work) }
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let name = Self.baseName(trimmed) == "/" ? "rootfs" : Self.baseName(trimmed)
        do { try copyOut(rec, trimmed, to: work.appending(path: name), embedded) } catch {
            throw APIError(404, "Could not find the file \(path) in container \(rec.name)")
        }
        let tar = Process()
        tar.executableURL = URL(filePath: "/usr/bin/tar")
        tar.arguments = ["-cf", "-", "-C", work.path, name]
        let out = Pipe()
        tar.standardOutput = out
        tar.standardError = FileHandle.nullDevice
        try tar.run()
        conn.beginChunked(contentType: "application/x-tar", extra: [("X-Docker-Container-Path-Stat", header)])
        while case let data = out.fileHandleForReading.availableData, !data.isEmpty {
            if !conn.chunk(data) { break }
        }
        tar.waitUntilExit()
        conn.endChunked()
    }

    /// `PUT` on the embedded runtime: the tar is unpacked on the host (bsdtar refuses
    /// `..` and writing through symlinks), then each top entry is copied in by the agent.
    /// Files end up owned by root, as with Docker's default `cp`, where the image has `chown`.
    private func putEmbedded(_ rec: ContainerRecord, path: String, tar data: Data, _ embedded: EmbeddedContainers) throws {
        let files = containers.shimFiles(rec.id)
        let work = files.dir.appending(path: "cp-\(randomHexID().prefix(8))")
        defer { try? FileManager.default.removeItem(at: work) }
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let tar = Process()
        tar.executableURL = URL(filePath: "/usr/bin/tar")
        tar.arguments = ["-xf", "-", "-C", work.path, "--no-same-owner"]
        let input = Pipe()
        tar.standardInput = input
        tar.standardError = FileHandle.nullDevice
        try tar.run()
        try? input.fileHandleForWriting.write(contentsOf: data)
        try? input.fileHandleForWriting.close()
        tar.waitUntilExit()
        guard tar.terminationStatus == 0 else { throw APIError(400, "invalid tar archive") }
        let q = { (s: String) in s.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "/._-"))) ?? s }
        var targets: [String] = []
        for entry in try FileManager.default.contentsOfDirectory(atPath: work.path) {
            let src = work.appending(path: entry)
            let dst = (path.hasSuffix("/") ? path : path + "/") + entry
            let mode = (try? FileManager.default.attributesOfItem(atPath: src.path)[.posixPermissions] as? Int) ?? 0o644
            try embedded.shim.call(files, "POST", "/copy-in?src=\(q(src.path))&dst=\(q(dst))&mode=\(String(mode, radix: 8))")
            targets.append(dst)
        }
        if !targets.isEmpty {
            let body: JSON = ["args": JSON(["chown", "-R", "0:0"] + targets), "timeout": 30]
            _ = try? embedded.shim.request(files, "POST", "/exec", body: body.encoded())
        }
    }

    /// `GET`: a tar whose single top entry is the path's base name.
    func get(_ ref: String, path: String, conn: Connection) throws {
        let header = try stat(ref, path: path)
        let rec = try running(ref)
        if let embedded = containers.embedded { return try getEmbedded(rec, path: path, header: header, embedded, conn) }
        let trimmed = path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
        let dir = (trimmed as NSString).deletingLastPathComponent
        let r = runtime.run(["exec", rec.appleId, "tar", "-cf", "-", "-C", dir.isEmpty ? "/" : dir, Self.baseName(trimmed)])
        guard r.ok else { throw APIError(500, "cannot archive \(path): \(r.errorText)") }
        conn.respond(200, body: r.stdout, contentType: "application/x-tar",
                     extra: [("X-Docker-Container-Path-Stat", header)])
    }

    /// `PUT`: extracts the tar body into the existing directory `path`.
    func put(_ ref: String, path: String, tar: Data) throws {
        let rec = try running(ref)
        if let embedded = containers.embedded {
            // Docker refuses a destination directory that does not exist.
            guard (try? stat(ref, path: path)) != nil else {
                throw APIError(404, "Could not find the file \(path) in container \(rec.name)")
            }
            return try putEmbedded(rec, path: path, tar: tar, embedded)
        }
        let r = runtime.run(["exec", "-i", rec.appleId, "sh", "-c",
                             #"[ -d "$1" ] || { echo "missing: $1" >&2; exit 2; }; tar -xf - -C "$1""#, "_", path],
                            input: tar)
        if r.status == 2 && r.errorText.contains("missing:") {
            throw APIError(404, "Could not find the file \(path) in container \(rec.name)")
        }
        guard r.ok else { throw APIError(500, "cannot extract into \(path): \(r.errorText)") }
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
