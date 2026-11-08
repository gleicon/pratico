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
        let r = runtime.run(["exec", rec.appleId, "sh", "-c",
                             #"stat -c '%s %f %Y' -- "$1" && readlink -- "$1"; true"#, "_", path])
        let lines = String(decoding: r.stdout, as: UTF8.self).split(separator: "\n").map(String.init)
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

    /// `GET`: a tar whose single top entry is the path's base name.
    func get(_ ref: String, path: String, conn: Connection) throws {
        let header = try stat(ref, path: path)
        let rec = try running(ref)
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
