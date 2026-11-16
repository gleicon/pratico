import ContainerizationArchive
import ContainerizationEXT4
import Foundation
import SystemPackage

/// A Docker volume (SPEC FR-25, D-32, D-49): by default a journaled ext4 disk image
/// attached to the VM, so ownership, permissions, and fsync are Linux's (database images
/// chown their data); with `--opt type=share`, a Mac folder shared over virtiofs, which
/// several running containers can mount at once.
struct VolumeRecord: Codable, Sendable {
    var name: String
    var created: Date
    var labels: [String: String]
    /// nil in records from before D-49, which are folders.
    var kind: Kind?
    /// A disk's capacity; the image is sparse, so only what is written takes space.
    var sizeBytes: Int64?

    enum Kind: String, Codable, Sendable { case disk, share }
    var storage: Kind { kind ?? .share }

    /// Docker's mark for a volume a container made for a bare `-v /path` or an image
    /// `VOLUME`; `rm -v`, `--rm`, and a plain `volume prune` remove only these.
    static let anonymousLabel = "com.docker.volume.anonymous"
    var anonymous: Bool { labels[Self.anonymousLabel] != nil }
}

/// Named and anonymous volumes under `~/.pratico/volumes/<name>/`: `volume.json` and the
/// data in `_data`, as Docker lays them out.
final class VolumeService: @unchecked Sendable {
    let root: URL
    let events: EventBus
    /// A new disk volume's capacity unless `--opt size=` says otherwise (`volume_size`).
    let defaultSizeBytes: Int64
    /// Volume name → IDs of the containers that mount it (set by the daemon).
    var usedBy: @Sendable () -> [String: [String]] = { [:] }

    private let lock = NSLock()
    private var records: [String: VolumeRecord] = [:]

    init(root: URL, events: EventBus, defaultSizeBytes: Int64 = 64 << 30) {
        precondition(defaultSizeBytes >= 1 << 30, "a disk volume below 1 GiB")
        self.root = root
        self.events = events
        self.defaultSizeBytes = defaultSizeBytes
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        load()
    }

    // MARK: Persistence

    private func dir(_ name: String) -> URL { root.appending(path: name, directoryHint: .isDirectory) }

    /// The host directory containers see at the mount point (a share).
    func dataPath(_ name: String) -> String { dir(name).appending(path: "_data").path }

    /// The disk image a disk volume is (made at its first mount).
    func diskPath(_ name: String) -> String { dir(name).appending(path: "disk.ext4").path }

    /// What a mount of `name` attaches: a disk image, or a folder to share. A volume not
    /// made yet is a disk, as `ensure` will make it.
    func source(_ name: String) -> (path: String, disk: Bool) {
        let rec = lock.withLock { records[name] }
        return (rec?.storage ?? .disk) == .disk ? (diskPath(name), true) : (dataPath(name), false)
    }

    /// Makes the disk image, with the files of `content` (a tar whose entries are relative
    /// to the volume's root) or empty; a disk that exists is left as it is.
    func formatDisk(_ name: String, content: URL?) throws {
        let rec = try resolve(name)
        precondition(rec.storage == .disk, "formatting a folder volume")
        let dest = diskPath(name)
        guard !FileManager.default.fileExists(atPath: dest) else { return }
        let partial = dest + ".partial"
        defer { try? FileManager.default.removeItem(atPath: partial) }
        let size = UInt64(rec.sizeBytes ?? defaultSizeBytes)
        try blocking {
            let f = try EXT4.Formatter(FilePath(partial), minDiskSize: size, journal: EXT4.JournalConfig(defaultMode: .ordered))
            if let content { try await f.unpack(reader: try ArchiveReader(file: content)) }
            // A volume starts as Docker's do: empty. initdb, among others, refuses a data
            // directory holding the formatter's lost+found; the kernel does not need it.
            try f.unlink(path: FilePath("/lost+found"))
            try f.close()
        }
        try FileManager.default.moveItem(atPath: partial, toPath: dest)
    }

    private func load() {
        for name in (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [] {
            guard let rec = Records.read(VolumeRecord.self, from: dir(name).appending(path: "volume.json")), rec.name == name else { continue }
            records[name] = rec
        }
    }

    private func save(_ rec: VolumeRecord) throws {
        let folder = rec.storage == .share ? dataPath(rec.name) : dir(rec.name).path
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try Records.write(rec, to: dir(rec.name).appending(path: "volume.json"))
    }

    // MARK: Create, inspect, list

    /// `POST /volumes/create`. Creating a name that exists returns it, as Docker does.
    /// The `local` driver with pratico's options: `type=disk` (the default) or `type=share`,
    /// and `size=` for a disk (`64g`); Docker's `device` and `o` name host devices and mount
    /// options a VM does not have, so they are refused.
    func create(_ body: JSON) throws -> VolumeRecord {
        let driver = body["Driver"]?.string ?? ""
        guard driver.isEmpty || driver == "local" else {
            throw APIError(400, "pratico: volume driver \(driver) is not supported; only local")
        }
        var opts = (body["DriverOpts"]?.object ?? [:]).compactMapValues(\.string)
        let type = opts.removeValue(forKey: "type") ?? "disk"
        guard let kind = VolumeRecord.Kind(rawValue: type) else {
            throw APIError(400, "pratico: volume type \(type) is not supported; disk (the default) or share")
        }
        let size = try opts.removeValue(forKey: "size").map(RunOptions.bytes)
        if let size, kind == .share { throw APIError(400, "pratico: size is for disk volumes; a share uses the Mac's disk") }
        if let size, size < 1 << 30 { throw APIError(400, "pratico: a disk volume holds at least 1 GiB") }
        if let bad = opts.keys.sorted().first { throw APIError(400, "pratico: volume option \(bad) is not supported; type and size are") }
        let labels = body["Labels"]?.object?.compactMapValues(\.string) ?? [:]
        let name = body["Name"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? randomHexID()
        try Self.validate(name)
        return try ensure(name, labels: labels, kind: kind, sizeBytes: size)
    }

    static func validate(_ name: String) throws {
        guard Names.valid(name) else {
            throw APIError(400, "create \(name): \"\(name)\" includes invalid characters for a local volume name, only \"[a-zA-Z0-9][a-zA-Z0-9_.-]\" are allowed")
        }
    }

    /// The volume a mount names, made if missing (`docker run -v data:/d` creates `data`).
    func ensure(_ name: String, labels: [String: String] = [:], kind: VolumeRecord.Kind = .disk, sizeBytes: Int64? = nil) throws -> VolumeRecord {
        lock.lock()
        defer { lock.unlock() }
        if let rec = records[name] { return rec }
        let rec = VolumeRecord(name: name, created: Date(), labels: labels, kind: kind, sizeBytes: sizeBytes)
        do { try save(rec) } catch {
            try? FileManager.default.removeItem(at: dir(name))
            throw APIError(500, "create \(name): \(error)")
        }
        records[name] = rec
        events.emit("volume", "create", id: name, attributes: ["driver": "local"])
        return rec
    }

    func resolve(_ name: String) throws -> VolumeRecord {
        lock.lock()
        defer { lock.unlock() }
        guard let rec = records[name] else { throw APIError(404, "get \(name): no such volume") }
        return rec
    }

    func all() -> [VolumeRecord] {
        lock.lock()
        defer { lock.unlock() }
        return records.values.sorted { $0.name < $1.name }
    }

    /// `GET /volumes/{name}`; with `usage`, the `UsageData` `docker system df -v` shows.
    func json(_ rec: VolumeRecord, usage: (size: Int64, refs: Int)? = nil) -> JSON {
        var options: [String: JSON] = ["type": .string(rec.storage.rawValue)]
        if rec.storage == .disk { options["size"] = .string("\(rec.sizeBytes ?? defaultSizeBytes)") }
        var j: JSON = [
            "Name": .string(rec.name), "Driver": "local",
            "Mountpoint": .string(rec.storage == .disk ? diskPath(rec.name) : dataPath(rec.name)),
            "CreatedAt": .string(rec.created.ISO8601Format()), "Labels": JSON(rec.labels),
            "Scope": "local", "Options": .object(options),
        ]
        if let usage { j["UsageData"] = ["Size": .int(usage.size), "RefCount": .int(Int64(usage.refs))] }
        return j
    }

    /// `GET /volumes`: Docker's `name`, `label`, `dangling`, and `driver` filters.
    func list(filters: [String: [String]]) -> JSON {
        let users = usedBy()
        let items = all().filter { rec in
            Filters.pass(filters, labels: rec.labels) { key, v in
                switch key {
                case "name": return rec.name.contains(v)
                case "driver": return v == "local"
                case "dangling": return (users[rec.name] ?? []).isEmpty == Filters.isTrue(v)
                default: return true
                }
            }
        }
        return ["Volumes": .array(items.map { json($0) }), "Warnings": []]
    }

    // MARK: Remove, prune

    /// `DELETE /volumes/{name}`. A volume in use stays, even with `force` (as Docker);
    /// `force` only makes a missing one not an error.
    func remove(_ name: String, force: Bool = false) throws {
        guard let rec = try? resolve(name) else {
            if force { return }
            throw APIError(404, "get \(name): no such volume")
        }
        if let users = usedBy()[name], !users.isEmpty {
            throw APIError(409, "remove \(name): volume is in use - [\(users.joined(separator: ", "))]")
        }
        lock.lock()
        records[name] = nil
        lock.unlock()
        try? FileManager.default.removeItem(at: dir(rec.name))
        events.emit("volume", "destroy", id: name, attributes: ["driver": "local"])
    }

    /// The volumes `POST /volumes/prune` removes: unused ones, only anonymous unless the
    /// `all` filter is set (Docker API 1.42 and later), matching any `label` filters.
    func prunable(filters: [String: [String]]) -> [VolumeRecord] {
        let users = usedBy()
        let everything = Filters.bool(filters, "all") ?? false
        return all().filter { rec in
            (users[rec.name] ?? []).isEmpty && (everything || rec.anonymous) && Filters.labels(filters["label"], in: rec.labels)
        }
    }

    func prune(filters: [String: [String]]) -> JSON {
        var deleted: [JSON] = []
        var reclaimed: Int64 = 0
        for rec in prunable(filters: filters) {
            let size = DiskService.allocated(dir(rec.name).path)
            guard (try? remove(rec.name)) != nil else { continue }
            deleted.append(.string(rec.name))
            reclaimed += size
        }
        events.emit("volume", "prune", id: "", attributes: ["reclaimed": String(reclaimed)])
        return ["VolumesDeleted": .array(deleted), "SpaceReclaimed": .int(reclaimed)]
    }

    func size(_ name: String) -> Int64 { DiskService.allocated(dir(name).path) }
}
