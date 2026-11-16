import Foundation
import PraticoCore

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
        /// Mount options of a tmpfs (memory in the guest, nothing on the Mac).
        var tmpfs: [String]? = nil
        /// `nocopy`: a new volume starts empty, without the image's files (copy-up).
        var noCopy = false
        /// A disk volume: attached to the VM as a block device, not shared (D-49).
        var disk = false
    }

    /// Docker's tmpfs defaults; options the client gives replace a default of the same key.
    static func tmpfsOptions(_ given: [String], readOnly: Bool = false) -> [String] {
        var opts = ["rw", "noexec", "nosuid", "nodev"]
        for o in given where !o.isEmpty {
            let key = o.splitOnce("=").0
            let flips = ["rw": "ro", "ro": "rw", "exec": "noexec", "noexec": "exec", "suid": "nosuid", "nosuid": "suid", "dev": "nodev", "nodev": "dev"]
            opts.removeAll { $0 == key || $0 == flips[key] || $0.splitOnce("=").0 == key }
            opts.append(o)
        }
        if readOnly { opts = opts.filter { $0 != "rw" } + ["ro"] }
        return opts
    }

    /// Where Docker clients and tools expect the daemon. A container that mounts it gets
    /// pratico's API whether or not the Mac has the link (Docker Desktop does the same).
    static let dockerSocketPaths: Set<String> = ["/var/run/docker.sock", "/private/var/run/docker.sock", "/run/docker.sock"]

    /// The guest side of a mount: a host Unix socket is relayed over vsock, since virtiofs
    /// shares files but not the connections behind a socket.
    static func shimMount(_ m: Mount, dockerSocket: String) -> ShimMount {
        if let options = m.tmpfs { return ShimMount(source: "tmpfs", destination: m.destination, readOnly: m.readOnly, tmpfs: options) }
        if m.disk { return ShimMount(source: m.source, destination: m.destination, readOnly: m.readOnly, block: true) }
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
        var covered = Set((host["Tmpfs"]?.object ?? [:]).keys)
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

    func mounts(_ host: JSON) throws -> [Mount] {
        try Self.mounts(host, volumeData: { [volumes] in volumes.source($0).path }, diskVolume: { [volumes] in volumes.source($0).disk })
    }

    /// Docker `Binds` (`src:dst[:opts]`, `src` a host path or a volume name) and bind and
    /// volume `Mounts`; `volumeData` maps a volume name to its host directory. Other mount
    /// types (tmpfs) are refused.
    static func mounts(_ host: JSON, volumeData: (String) -> String, diskVolume: (String) -> Bool = { _ in false }) throws -> [Mount] {
        var out: [Mount] = []
        for bind in host["Binds"]?.strings ?? [] {
            let parts = bind.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 2 || parts.count == 3, !parts[0].isEmpty, parts[1].hasPrefix("/") else {
                throw APIError(400, "invalid volume specification: '\(bind)'")
            }
            let opts = parts.count == 3 ? parts[2].split(separator: ",").map(String.init) : []
            let readOnly = opts.contains("ro")
            if parts[0].hasPrefix("/") {
                out.append(Mount(source: parts[0], destination: parts[1], readOnly: readOnly,
                                 createSource: !Self.dockerSocketPaths.contains(parts[0])))
            } else {
                try VolumeService.validate(parts[0])
                out.append(Mount(source: volumeData(parts[0]), destination: parts[1], readOnly: readOnly,
                                 createSource: false, volume: parts[0], noCopy: opts.contains("nocopy"), disk: diskVolume(parts[0])))
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
                                 createSource: false, volume: name, noCopy: m["VolumeOptions"]?["NoCopy"]?.bool ?? false, disk: diskVolume(name)))
            case "tmpfs":
                // `--mount type=tmpfs,tmpfs-size=…,tmpfs-mode=…`
                var given: [String] = []
                if let size = m["TmpfsOptions"]?["SizeBytes"]?.int, size > 0 { given.append("size=\(size)") }
                if let mode = m["TmpfsOptions"]?["Mode"]?.int, mode > 0 { given.append("mode=" + String(mode, radix: 8)) }
                out.append(Mount(source: "", destination: dst, readOnly: readOnly, createSource: false,
                                 tmpfs: tmpfsOptions(given, readOnly: readOnly)))
            default:
                throw APIError(400, "pratico: mount type \(type) is not supported")
            }
        }
        // `--tmpfs /path[:options]`
        for (dst, opts) in (host["Tmpfs"]?.object ?? [:]).sorted(by: { $0.key < $1.key }) {
            guard dst.hasPrefix("/") else { throw APIError(400, "invalid tmpfs mount: \(dst) is not an absolute path") }
            let given = (opts.string ?? "").split(separator: ",").map(String.init)
            let options = tmpfsOptions(given)
            out.append(Mount(source: "", destination: dst, readOnly: options.contains("ro"), createSource: false, tmpfs: options))
        }
        return out
    }

    func mountsJSON(_ rec: ContainerRecord) -> JSON {
        .array(((try? mounts(rec.hostConfig)) ?? []).map { m in
            var j: JSON = [
                "Type": .string(m.tmpfs != nil ? "tmpfs" : m.volume == nil ? "bind" : "volume"), "Source": .string(m.source), "Destination": .string(m.destination),
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

    /// Docker's copy-up, for a new container: each volume it mounts that is still empty gets
    /// the image's files at the mount path, unless the mount says `nocopy`. A failed copy is
    /// logged; the container still gets its (empty) volume, as a volume without files would.
    func copyUp(_ host: JSON, rootfs: URL) {
        for m in (try? mounts(host)) ?? [] where m.disk {
            do { try copyUpDisk(m, rootfs: rootfs) } catch {
                Pratico.log("pratico-daemon: making disk volume \(m.volume!) failed: \(error)")
            }
        }
        for m in (try? mounts(host)) ?? [] where m.volume != nil && !m.noCopy && !m.disk {
            let data = URL(filePath: m.source, directoryHint: .isDirectory)
            guard ((try? FileManager.default.contentsOfDirectory(atPath: data.path)) ?? ["?"]).isEmpty else { continue }
            do { try CopyUp.copy(rootfs: rootfs, path: m.destination, into: data) } catch {
                Pratico.log("pratico-daemon: copy-up of \(m.destination) into volume \(m.volume!) failed: \(error)")
            }
        }
    }

    /// A disk volume's first mount makes its disk, with the image's files at the mount path
    /// (owners, modes, and links kept, as on Docker) unless `nocopy`.
    func copyUpDisk(_ m: Mount, rootfs: URL) throws {
        guard let name = m.volume, !FileManager.default.fileExists(atPath: m.source) else { return }
        guard !m.noCopy, let tree = try? RootfsTree.read(rootfs), tree[m.destination].map({ $0.mode & CopyUp.typeMask == CopyUp.dirType }) == true else {
            return try volumes.formatDisk(name, content: nil)
        }
        let tar = FileManager.default.temporaryDirectory.appending(path: "pratico-copyup-\(UUID().uuidString).tar")
        defer { try? FileManager.default.removeItem(at: tar) }
        let under = tree.keys.filter { $0.hasPrefix(m.destination + "/") }.sorted()
        let entries = [RootfsTree.Change(path: m.destination, kind: 1)] + under.map { RootfsTree.Change(path: $0, kind: 1) }
        try CommitLayer.write(entries, from: rootfs, to: tar, maxBytes: Tar.unpackLimit(at: tar.deletingLastPathComponent()), root: m.destination)
        try volumes.formatDisk(name, content: tar)
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
