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

    /// `POST /pratico/snapshots/restore?path=…[&dry_run=1][&start=1]`. Volumes, then
    /// networks, then containers, so each finds what it refers to. A name already taken is
    /// skipped and reported (FR-36); an unsupported `format_version` refuses the whole
    /// restore before anything changes (FR-36.a). With `start`, containers that ran when
    /// the snapshot was taken are started again. A dry run reports what would happen,
    /// with each container's `Review` (image, command, Mac folders, ports, privileges),
    /// and changes nothing.
    func restore(path: String, dryRun: Bool, start: Bool) throws -> JSON {
        let file = URL(filePath: (path as NSString).expandingTildeInPath)
        guard let size = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? Int, size <= Self.maxArchive else {
            throw APIError(400, "\(path) is not a pratico snapshot (missing, or larger than a snapshot can be)")
        }
        // Only the members a snapshot has, read into memory with caps: a hostile archive
        // can neither fill the disk nor plant files.
        let members: [String: Data]
        do {
            members = try Tar.readFiles(file, accept: Self.isMember, maxFile: Self.maxMember,
                                        maxTotal: Self.maxArchive, maxEntries: Self.maxEntries)
        } catch let e as APIError {
            throw APIError(400, "\(path) is not a pratico snapshot: \(e.message)")
        } catch {
            throw APIError(400, "\(path) is not a pratico snapshot: \(error)")
        }
        guard let manifest = members["manifest.json"].flatMap(JSON.parse) else {
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
        var reviews: [JSON] = []
        for kind in Kind.allCases {
            for name in manifest[kind.folder]?.strings ?? [] {
                guard Self.isPlainName(name), let item = members["\(kind.folder)/\(name).json"].flatMap(JSON.parse) else {
                    failed.append(["Kind": .string(kind.rawValue), "Name": .string(name), "Error": "missing or unreadable in the snapshot"])
                    continue
                }
                if exists(kind, name) {
                    skipped.append(["Kind": .string(kind.rawValue), "Name": .string(name), "Reason": .string("a \(kind.rawValue) with this name exists")])
                    continue
                }
                if kind == .container { reviews.append(review(name, item)) }
                if dryRun {
                    created[kind, default: []].append(name)
                    continue
                }
                do {
                    try recreate(kind, name, item)
                    created[kind, default: []].append(name)
                    if start && kind == .container && item["Running"]?.bool == true {
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
            "Review": .array(reviews),
        ]
    }

    /// A host path as it resolves (`..` and symlinks gone), so the review names the folder
    /// that would really be shared.
    static func shown(_ path: String) -> String {
        path.hasPrefix("/") ? URL(filePath: path).standardizedFileURL.resolvingSymlinksInPath().path : path
    }

    static let maxMember = 1 << 20
    static let maxEntries = 10_000

    /// `manifest.json` and `<kind>s/<plain name>.json`, nothing else.
    static func isMember(_ path: String) -> Bool {
        if path == "manifest.json" { return true }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, Kind.allCases.contains(where: { $0.folder == parts[0] }), parts[1].hasSuffix(".json") else { return false }
        return isPlainName(String(parts[1].dropLast(5)))
    }

    /// Names come from the file: one that is not a plain file name never becomes a path.
    static func isPlainName(_ name: String) -> Bool { !name.isEmpty && !name.contains("/") && !name.hasPrefix(".") }

    /// What a restored container could do to this Mac, for the confirmation: a snapshot can
    /// come from anywhere, and a container from it can reach whatever these give it. Mounts
    /// come from the parser `create` uses, so the review lists exactly what gets mounted.
    func review(_ name: String, _ item: JSON) -> JSON {
        let body = item["Create"] ?? [:]
        let host = body["HostConfig"] ?? [:]
        var risks: [String] = []
        // The HostConfig as create would store it (bare `-v /path` named), parsed by the
        // parser create uses; if that refuses it, every raw source is listed anyway.
        let planned = ContainerService.planVolumes(host, imageVolumes: []).host
        do {
            for m in try ContainerService.mounts(planned, volumeData: volumes.dataPath) {
                let mode = m.readOnly ? "read-only" : "read and write"
                if let vol = m.volume {
                    let state = (try? volumes.resolve(vol)) != nil ? "an existing volume on this Mac" : "a new, empty volume"
                    risks.append("mounts volume \(vol) at \(m.destination) (\(state), \(mode))")
                } else if ContainerService.dockerSocketPaths.contains(m.source) || m.source.hasSuffix(".sock") {
                    risks.append("controls Docker on this Mac: mounts the socket \(m.source) at \(m.destination)")
                } else {
                    risks.append("mounts the Mac folder \(Self.shown(m.source)) at \(m.destination) (\(mode))")
                }
            }
        } catch {
            let message = (error as? APIError)?.message ?? "\(error)"
            let raw = (planned["Binds"]?.strings ?? []).map { String($0.split(separator: ":").first ?? "") }
                + (planned["Mounts"]?.array ?? []).compactMap { $0["Source"]?.string }
            risks.append("has mounts pratico would refuse (\(message)); its mount sources: " + raw.map(Self.shown).joined(separator: ", "))
        }
        let ports = (host["PortBindings"]?.object ?? [:]).flatMap { port, list in
            (list.array ?? []).map { b in "\(b["HostIp"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? "0.0.0.0"):\(b["HostPort"]?.string ?? "")→\(port)" }
        }
        if !ports.isEmpty { risks.append("publishes " + ports.sorted().joined(separator: ", ")) }
        if host["Privileged"]?.bool == true { risks.append("privileged") }
        if let caps = host["CapAdd"]?.strings, !caps.isEmpty { risks.append("adds capabilities " + caps.joined(separator: ", ")) }
        if let devices = host["Devices"]?.array, !devices.isEmpty { risks.append("uses host devices") }
        if host["NetworkMode"]?.string == "host" { risks.append("host networking") }
        let command = ((body["Entrypoint"]?.strings ?? []) + (body["Cmd"]?.strings ?? [])).joined(separator: " ")
        return ["Name": .string(name), "Image": body["Image"] ?? "", "Command": .string(command),
                "Running": .bool(item["Running"]?.bool ?? false), "Risks": JSON(risks)]
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
