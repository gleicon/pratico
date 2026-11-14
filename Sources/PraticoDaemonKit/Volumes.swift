import Foundation

/// A Docker volume: a directory pratico owns, shared into each VM that mounts it like a
/// bind mount (SPEC FR-25, D-32).
struct VolumeRecord: Codable, Sendable {
    var name: String
    var created: Date
    var labels: [String: String]

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
    /// Volume name → IDs of the containers that mount it (set by the daemon).
    var usedBy: @Sendable () -> [String: [String]] = { [:] }

    private let lock = NSLock()
    private var records: [String: VolumeRecord] = [:]

    init(root: URL, events: EventBus) {
        self.root = root
        self.events = events
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        load()
    }

    // MARK: Persistence

    private func dir(_ name: String) -> URL { root.appending(path: name, directoryHint: .isDirectory) }

    /// The host directory containers see at the mount point.
    func dataPath(_ name: String) -> String { dir(name).appending(path: "_data").path }

    private func load() {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        for name in (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [] {
            guard let data = try? Data(contentsOf: dir(name).appending(path: "volume.json")),
                let rec = try? dec.decode(VolumeRecord.self, from: data), rec.name == name
            else { continue }
            records[name] = rec
        }
    }

    private func save(_ rec: VolumeRecord) throws {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(atPath: dataPath(rec.name), withIntermediateDirectories: true)
        try enc.encode(rec).write(to: dir(rec.name).appending(path: "volume.json"), options: .atomic)
    }

    // MARK: Create, inspect, list

    /// `POST /volumes/create`. Creating a name that exists returns it, as Docker does.
    /// Only the `local` driver, without options: pratico has no other storage to offer.
    func create(_ body: JSON) throws -> VolumeRecord {
        let driver = body["Driver"]?.string ?? ""
        guard driver.isEmpty || driver == "local" else {
            throw APIError(400, "pratico: volume driver \(driver) is not supported; only local")
        }
        guard (body["DriverOpts"]?.object ?? [:]).isEmpty else {
            throw APIError(400, "pratico: local volume options (type, device, o) are not supported")
        }
        let labels = body["Labels"]?.object?.compactMapValues(\.string) ?? [:]
        let name = body["Name"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? randomHexID()
        try Self.validate(name)
        return try ensure(name, labels: labels)
    }

    static func validate(_ name: String) throws {
        guard Names.valid(name) else {
            throw APIError(400, "create \(name): \"\(name)\" includes invalid characters for a local volume name, only \"[a-zA-Z0-9][a-zA-Z0-9_.-]\" are allowed")
        }
    }

    /// The volume a mount names, made if missing (`docker run -v data:/d` creates `data`).
    func ensure(_ name: String, labels: [String: String] = [:]) throws -> VolumeRecord {
        lock.lock()
        defer { lock.unlock() }
        if let rec = records[name] { return rec }
        let rec = VolumeRecord(name: name, created: Date(), labels: labels)
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
        var j: JSON = [
            "Name": .string(rec.name), "Driver": "local", "Mountpoint": .string(dataPath(rec.name)),
            "CreatedAt": .string(rec.created.ISO8601Format()), "Labels": JSON(rec.labels),
            "Scope": "local", "Options": [:],
        ]
        if let usage { j["UsageData"] = ["Size": .int(usage.size), "RefCount": .int(Int64(usage.refs))] }
        return j
    }

    /// `GET /volumes`: Docker's `name`, `label`, `dangling`, and `driver` filters.
    func list(filters: [String: [String]]) -> JSON {
        let users = usedBy()
        let items = all().filter { rec in
            for (key, values) in filters where !values.isEmpty {
                let ok = values.contains { v in
                    switch key {
                    case "name": return rec.name.contains(v)
                    case "driver": return v == "local"
                    case "dangling": return (users[rec.name] ?? []).isEmpty == ["1", "true"].contains(v)
                    case "label": return Self.matches(rec, v)
                    default: return true
                    }
                }
                if !ok { return false }
            }
            return true
        }
        return ["Volumes": .array(items.map { json($0) }), "Warnings": []]
    }

    private static func matches(_ rec: VolumeRecord, _ filter: String) -> Bool {
        let (k, val) = filter.splitOnce("=")
        guard let have = rec.labels[k] else { return false }
        return val == nil || have == val
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
        let everything = filters["all"]?.contains { ["1", "true"].contains($0) } ?? false
        return all().filter { rec in
            (users[rec.name] ?? []).isEmpty && (everything || rec.anonymous)
                && (filters["label"] ?? []).allSatisfy { Self.matches(rec, $0) }
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
