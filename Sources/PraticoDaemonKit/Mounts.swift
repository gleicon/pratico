import Foundation

/// Bind mounts and volumes (SPEC FR-14, FR-25): parsed from the stored HostConfig, so
/// `docker inspect` and every start see the same mounts.
extension ContainerService {
    struct Mount: Equatable {
        /// The host path: the bind source, or a volume's `_data` directory.
        var source: String
        var destination: String
        var readOnly: Bool
        /// `-v` creates a missing host path, as Docker does; `--mount` does not.
        var createSource: Bool
        /// The volume's name, for a volume mount.
        var volume: String? = nil
    }

    /// Where Docker clients and tools expect the daemon. A container that mounts it gets
    /// pratico's API whether or not the Mac has the link (Docker Desktop does the same).
    static let dockerSocketPaths: Set<String> = ["/var/run/docker.sock", "/private/var/run/docker.sock", "/run/docker.sock"]

    /// The guest side of a mount: a host Unix socket is relayed over vsock, since virtiofs
    /// shares files but not the connections behind a socket.
    static func shimMount(_ m: Mount, dockerSocket: String) -> ShimMount {
        let source = dockerSocketPaths.contains(m.source) ? dockerSocket : m.source
        var st = stat()
        let socket = stat(source, &st) == 0 && st.st_mode & S_IFMT == S_IFSOCK
        return ShimMount(source: source, destination: m.destination, readOnly: m.readOnly, socket: socket)
    }

    /// A new container's HostConfig with every volume named, and those volumes made. A bare
    /// `-v /path` (in `Binds` or `imageVolumes`), a volume `Mounts` entry without `Source`,
    /// and each image `VOLUME` no other mount covers get an anonymous volume, as in Docker. Mounts are checked before
    /// any volume is made, so a refused create leaves none behind.
    func namingVolumes(_ host: JSON, imageVolumes: [String]) throws -> JSON {
        let (named, wanted) = Self.planVolumes(host, imageVolumes: imageVolumes)
        _ = try mounts(named)
        for (name, labels) in wanted { _ = try volumes.ensure(name, labels: labels) }
        return named
    }

    /// The HostConfig `create` stores, and the volumes it must make, without making them:
    /// what the snapshot review reads, so it sees exactly the mounts a create would.
    static func planVolumes(_ host: JSON, imageVolumes: [String]) -> (host: JSON, wanted: [(name: String, labels: [String: String])]) {
        var host = host
        var wanted: [(name: String, labels: [String: String])] = []
        let anonymous = { () -> String in
            let name = randomHexID()
            wanted.append((name, [VolumeRecord.anonymousLabel: ""]))
            return name
        }
        var covered: Set<String> = []
        if let binds = host["Binds"]?.strings {
            host["Binds"] = JSON(binds.map { bind -> String in
                let parts = bind.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
                if parts.count == 1 && bind.hasPrefix("/") {
                    covered.insert(bind)
                    return "\(anonymous()):\(bind)"
                }
                if parts.count >= 2 {
                    covered.insert(parts[1])
                    if !parts[0].isEmpty && !parts[0].hasPrefix("/") { wanted.append((parts[0], [:])) }
                }
                return bind
            })
        }
        if let mounts = host["Mounts"]?.array {
            host["Mounts"] = .array(mounts.map { m in
                var m = m
                if let target = m["Target"]?.string { covered.insert(target) }
                guard (m["Type"]?.string ?? "volume") == "volume" else { return m }
                let labels = m["VolumeOptions"]?["Labels"]?.object?.compactMapValues(\.string) ?? [:]
                if let name = m["Source"]?.string, !name.isEmpty {
                    wanted.append((name, labels))
                } else {
                    m["Source"] = .string(anonymous())
                }
                return m
            })
        }
        let extra = imageVolumes.filter { !covered.contains($0) }.sorted().map { "\(anonymous()):\($0)" }
        if !extra.isEmpty { host["Binds"] = JSON((host["Binds"]?.strings ?? []) + extra) }

        return (host, wanted)
    }

    func mounts(_ host: JSON) throws -> [Mount] { try Self.mounts(host, volumeData: volumes.dataPath) }

    /// Docker `Binds` (`src:dst[:opts]`, `src` a host path or a volume name) and bind and
    /// volume `Mounts`; `volumeData` maps a volume name to its host directory. Other mount
    /// types (tmpfs) are refused.
    static func mounts(_ host: JSON, volumeData: (String) -> String) throws -> [Mount] {
        var out: [Mount] = []
        for bind in host["Binds"]?.strings ?? [] {
            let parts = bind.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 2 || parts.count == 3, !parts[0].isEmpty, parts[1].hasPrefix("/") else {
                throw APIError(400, "invalid volume specification: '\(bind)'")
            }
            let readOnly = parts.count == 3 && parts[2].split(separator: ",").contains("ro")
            if parts[0].hasPrefix("/") {
                out.append(Mount(source: parts[0], destination: parts[1], readOnly: readOnly,
                                 createSource: !Self.dockerSocketPaths.contains(parts[0])))
            } else {
                try VolumeService.validate(parts[0])
                out.append(Mount(source: volumeData(parts[0]), destination: parts[1], readOnly: readOnly,
                                 createSource: false, volume: parts[0]))
            }
        }
        for m in host["Mounts"]?.array ?? [] {
            let type = m["Type"]?.string ?? "volume"
            guard let dst = m["Target"]?.string, dst.hasPrefix("/") else {
                throw APIError(400, "invalid mount config: the target must be an absolute path")
            }
            let readOnly = m["ReadOnly"]?.bool ?? false
            switch type {
            case "bind":
                guard let src = m["Source"]?.string, src.hasPrefix("/") else {
                    throw APIError(400, "invalid mount config: bind mounts need an absolute source and target")
                }
                guard Self.dockerSocketPaths.contains(src) || FileManager.default.fileExists(atPath: src) else {
                    throw APIError(400, "invalid mount config for type \"bind\": bind source path does not exist: \(src)")
                }
                out.append(Mount(source: src, destination: dst, readOnly: readOnly, createSource: false))
            case "volume":
                guard let name = m["Source"]?.string, !name.isEmpty else {
                    throw APIError(400, "invalid mount config for type \"volume\": a volume mount needs a source")
                }
                try VolumeService.validate(name)
                out.append(Mount(source: volumeData(name), destination: dst, readOnly: readOnly,
                                 createSource: false, volume: name))
            default:
                throw APIError(400, "pratico: mount type \(type) is not supported yet")
            }
        }
        return out
    }

    func mountsJSON(_ rec: ContainerRecord) -> JSON {
        .array(((try? mounts(rec.hostConfig)) ?? []).map { m in
            var j: JSON = [
                "Type": m.volume == nil ? "bind" : "volume", "Source": .string(m.source), "Destination": .string(m.destination),
                "Mode": .string(m.readOnly ? "ro" : ""), "RW": .bool(!m.readOnly), "Propagation": "rprivate",
            ]
            if let name = m.volume {
                j["Name"] = .string(name)
                j["Driver"] = "local"
                j["Propagation"] = ""
            }
            return j
        })
    }

    /// Volume name → IDs of the containers, running or not, that mount it.
    func volumeUsers() -> [String: [String]] {
        var out: [String: [String]] = [:]
        for rec in all() {
            for name in Set(((try? mounts(rec.hostConfig)) ?? []).compactMap(\.volume)) { out[name, default: []].append(rec.id) }
        }
        return out
    }

    /// Removes the anonymous volumes `rec` mounted (`docker rm -v`, `--rm`) that no other
    /// container mounts; named volumes stay, as in Docker.
    func removeAnonymousVolumes(_ rec: ContainerRecord) {
        for name in Set(((try? mounts(rec.hostConfig)) ?? []).compactMap(\.volume)) {
            guard let vol = try? volumes.resolve(name), vol.anonymous else { continue }
            try? volumes.remove(name)  // refused while another container uses it
        }
    }
}
