import Foundation
import PraticoCore

/// Snapshot and restore (SPEC FR-35, FR-36, D-6): what it takes to recreate every container,
/// custom network, and volume, as a `.tar.gz` of plain JSON under `~/.pratico/snapshots/`.
/// Definitions only: images come from their registries, and volume data is not copied.
struct SnapshotService {
    let dir: URL
    let containers: ContainerService
    let networks: NetworkService
    let volumes: VolumeService
    static let formatVersion = 1
    /// A snapshot is JSON: anything bigger is not one of ours.
    static let maxArchive = 64 << 20

    enum Kind: String, CaseIterable {
        case volume, network, container
        var folder: String { rawValue + "s" }
    }

    // MARK: Take

    /// `POST /pratico/snapshots`.
    func take() throws -> JSON {
        let fm = FileManager.default
        let stamp = Date().ISO8601Format(.iso8601.year().month().day().time(includingFractionalSeconds: false).timeSeparator(.omitted).dateSeparator(.omitted))
        let file = dir.appending(path: "pratico-snapshot-\(stamp).tar.gz")
        let work = fm.temporaryDirectory.appending(path: "pratico-snapshot-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: work) }

        let items: [Kind: [(name: String, json: JSON)]] = [
            .volume: volumes.all().map { ($0.name, ["Name": .string($0.name), "Labels": JSON($0.labels)]) },
            .network: networks.all().filter { !$0.builtin }.map { ($0.name, Self.network($0)) },
            .container: containers.all().map { ($0.name, container($0)) },
        ]
        for kind in Kind.allCases {
            let folder = work.appending(path: kind.folder)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            for item in items[kind] ?? [] { try item.json.encodedPretty().write(to: folder.appending(path: "\(item.name).json")) }
        }
        let manifest: JSON = [
            "format_version": .int(Int64(Self.formatVersion)), "created": .string(Timestamp.format(Date())),
            "pratico_version": .string(Pratico.version),
            "containers": JSON((items[.container] ?? []).map(\.name)), "networks": JSON((items[.network] ?? []).map(\.name)),
            "volumes": JSON((items[.volume] ?? []).map(\.name)),
        ]
        try manifest.encodedPretty().write(to: work.appending(path: "manifest.json"))
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        do {
            try Tar.create(file, base: work, names: ["manifest.json"] + Kind.allCases.map(\.folder), gzip: true)
        } catch {
            try? fm.removeItem(at: file)
            throw APIError(500, "cannot write \(file.path): \(error)")
        }
        return ["Path": .string(file.path), "Containers": .int(Int64(items[.container]?.count ?? 0)),
                "Networks": .int(Int64(items[.network]?.count ?? 0)), "Volumes": .int(Int64(items[.volume]?.count ?? 0))]
    }

    /// `GET /pratico/snapshots`: newest first.
    func list() -> JSON {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return .array(files.filter { $0.lastPathComponent.hasPrefix("pratico-snapshot-") && $0.path.hasSuffix(".tar.gz") }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .map { ["Path": .string($0.path), "Size": .int(Int64((try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0))] })
    }

    /// The create request that makes this container again: its config with the HostConfig
    /// (volumes already named) and each network it is on, by name, with its aliases.
    private func container(_ rec: ContainerRecord) -> JSON {
        var body = rec.config
        body["HostConfig"] = rec.hostConfig
        let byId = Dictionary(networks.all().map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        var endpoints: [String: JSON] = [:]
        for (id, ep) in rec.endpoints ?? [:] where !ep.detached {
            if let name = byId[id] { endpoints[name] = ["Aliases": JSON(ep.aliases)] }
        }
        body["NetworkingConfig"] = ["EndpointsConfig": .object(endpoints)]
        return ["Name": .string(rec.name), "Running": .bool(rec.state.running), "Create": body]
    }

    private static func network(_ rec: NetworkRecord) -> JSON {
        [
            "Name": .string(rec.name), "Driver": .string(rec.driver), "Internal": .bool(rec.isInternal),
            "Attachable": .bool(rec.attachable), "Labels": JSON(rec.labels), "Options": JSON(rec.options),
            "IPAM": ["Config": [["Subnet": .string(rec.subnet), "Gateway": .string(rec.gateway)]]],
        ]
    }

    // MARK: Restore

    /// `POST /pratico/snapshots/restore?path=…[&dry_run=1]`. Volumes, then networks, then
    /// containers, so each finds what it refers to. A name already taken is skipped and
    /// reported (FR-36); an unsupported `format_version` refuses the whole restore before
    /// anything changes (FR-36.a). Containers that ran when the snapshot was taken are
    /// started again. A dry run reports what would happen and changes nothing.
    func restore(path: String, dryRun: Bool) throws -> JSON {
        let fm = FileManager.default
        let file = URL(filePath: (path as NSString).expandingTildeInPath)
        guard let size = (try? fm.attributesOfItem(atPath: file.path))?[.size] as? Int, size <= Self.maxArchive else {
            throw APIError(400, "\(path) is not a pratico snapshot (missing, or larger than a snapshot can be)")
        }
        let work = fm.temporaryDirectory.appending(path: "pratico-restore-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        do { try Tar.extract(file, to: work) } catch {
            throw APIError(400, "\(path) is not a pratico snapshot: \(error)")
        }
        guard let manifest = (try? Data(contentsOf: work.appending(path: "manifest.json"))).flatMap(JSON.parse) else {
            throw APIError(400, "\(path) is not a pratico snapshot: it has no manifest.json")
        }
        guard let version = manifest["format_version"]?.int, version == Self.formatVersion else {
            let shown = manifest["format_version"].map { String(decoding: $0.encoded(), as: UTF8.self) } ?? "none"
            throw APIError(400, "snapshot format_version \(shown) is not supported; this pratico reads format_version \(Self.formatVersion)")
        }

        var created: [Kind: [String]] = [:]
        var skipped: [JSON] = []
        var failed: [JSON] = []
        var started: [String] = []
        for kind in Kind.allCases {
            for name in manifest[kind.folder]?.strings ?? [] {
                // Names come from the file: one that is not a plain file name never becomes a path.
                guard !name.isEmpty, !name.contains("/"), !name.hasPrefix("."),
                    let item = (try? Data(contentsOf: work.appending(path: "\(kind.folder)/\(name).json"))).flatMap(JSON.parse)
                else {
                    failed.append(["Kind": .string(kind.rawValue), "Name": .string(name), "Error": "missing or unreadable in the snapshot"])
                    continue
                }
                if exists(kind, name) {
                    skipped.append(["Kind": .string(kind.rawValue), "Name": .string(name), "Reason": .string("a \(kind.rawValue) with this name exists")])
                    continue
                }
                if dryRun {
                    created[kind, default: []].append(name)
                    continue
                }
                do {
                    try recreate(kind, name, item)
                    created[kind, default: []].append(name)
                    if kind == .container && item["Running"]?.bool == true {
                        do { _ = try containers.start(name); started.append(name) } catch let e as APIError {
                            failed.append(["Kind": "container", "Name": .string(name), "Error": .string("created, but not started: \(e.message)")])
                        }
                    }
                } catch let e as APIError {
                    failed.append(["Kind": .string(kind.rawValue), "Name": .string(name), "Error": .string(e.message)])
                }
            }
        }
        return [
            "DryRun": .bool(dryRun),
            "Created": .object(Dictionary(uniqueKeysWithValues: Kind.allCases.map { ($0.folder.capitalized, JSON(created[$0] ?? [])) })),
            "Started": JSON(started), "Skipped": .array(skipped), "Failed": .array(failed),
        ]
    }

    private func exists(_ kind: Kind, _ name: String) -> Bool {
        switch kind {
        case .volume: return (try? volumes.resolve(name)) != nil
        case .network: return networks.all().contains { $0.name == name }
        case .container: return containers.all().contains { $0.name == name }
        }
    }

    private func recreate(_ kind: Kind, _ name: String, _ item: JSON) throws {
        switch kind {
        case .volume:
            try VolumeService.validate(name)
            _ = try volumes.ensure(name, labels: item["Labels"]?.object?.compactMapValues(\.string) ?? [:])
        case .network:
            var body = item
            body["Name"] = .string(name)
            _ = try networks.create(body)
        case .container:
            guard let body = item["Create"] else { throw APIError(400, "the snapshot has no create request for \(name)") }
            _ = try containers.create(name: name, body: body)
        }
    }
}
