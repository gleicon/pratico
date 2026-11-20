import Foundation

/// The archive `docker save` wrote before Docker 25, and what go-containerregistry writes
/// (buildpacks' lifecycle among others): a `manifest.json` listing each image's config and
/// layer files, and no OCI `index.json`. Docker loads it; here it becomes an OCI layout
/// in place, so `docker load` reads one shape. A layer file may be empty when the daemon
/// holds that layer already (imgutil, which the lifecycle uses, writes base layers so):
/// it is matched by the config's `diff_id`, as Docker does.
enum DockerArchive {
    static let maxImages = 256
    static let maxLayers = 1024

    /// Writes `index.json` and `oci-layout` for the images `manifest.json` lists, their
    /// files moved into `blobs/sha256`. `dir` is the unpacked archive, links refused.
    static func convert(_ dir: URL, stored: () -> [String: StoredLayer]) throws {
        guard let list = (try? Data(contentsOf: dir.appending(path: "manifest.json"))).flatMap(JSON.parse)?.array, !list.isEmpty else {
            throw APIError(400, "pratico: this archive has neither an OCI index.json nor a Docker manifest.json")
        }
        guard list.count <= maxImages else { throw APIError(400, "pratico: the archive lists more than \(maxImages) images") }
        try FileManager.default.createDirectory(at: dir.appending(path: "blobs/sha256"), withIntermediateDirectories: true)
        // Member path → its blob: images in one archive share layers, moved in once.
        var blobs: [String: (digest: String, size: Int64, gzip: Bool)] = [:]
        func blob(_ member: String) throws -> (digest: String, size: Int64, gzip: Bool) {
            if let known = blobs[member] { return known }
            let file = try Self.member(dir, member)
            let gzip = try Self.isGzip(file)
            let b = try ImageService.addBlob(file: file, to: dir)
            blobs[member] = (b.digest, b.size, gzip)
            return (b.digest, b.size, gzip)
        }
        var known: [String: StoredLayer]?  // read once, only if a layer is left out
        var entries: [JSON] = []
        for image in list {
            guard let configPath = image["Config"]?.string, let layerPaths = image["Layers"]?.strings, layerPaths.count <= maxLayers else {
                throw APIError(400, "pratico: the archive's manifest.json has an entry without Config or Layers")
            }
            let configBlob = try blob(configPath)
            let configFile = dir.appending(path: "blobs/sha256/" + configBlob.digest.dropFirst("sha256:".count))
            let config = (try? Data(contentsOf: configFile)).flatMap(JSON.parse) ?? [:]
            let diffs = config["rootfs"]?["diff_ids"]?.strings ?? []
            let layers: [JSON] = try layerPaths.enumerated().map { i, path in
                let b = try blob(path)
                guard b.size == 0 else {
                    return ["mediaType": .string(b.gzip ? "application/vnd.oci.image.layer.v1.tar+gzip" : "application/vnd.oci.image.layer.v1.tar"),
                            "digest": .string(b.digest), "size": .int(b.size)]
                }
                if known == nil { known = stored() }
                guard i < diffs.count, let have = known?[diffs[i]] else {
                    throw APIError(400, "pratico: the archive leaves out layer \(i < diffs.count ? diffs[i] : path), which is not stored here")
                }
                let dest = dir.appending(path: "blobs/sha256/" + have.digest.dropFirst("sha256:".count))
                if !FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.copyItem(at: have.file, to: dest) }
                return ["mediaType": .string(have.mediaType), "digest": .string(have.digest), "size": .int(have.size)]
            }
            let manifest: JSON = [
                "schemaVersion": 2, "mediaType": "application/vnd.oci.image.manifest.v1+json",
                "config": ["mediaType": "application/vnd.oci.image.config.v1+json", "digest": .string(configBlob.digest), "size": .int(configBlob.size)],
                "layers": .array(layers),
            ]
            let manifestBlob = try ImageService.addBlob(data: manifest.encoded(), to: dir)
            let platform: JSON = ["architecture": .string(config["architecture"]?.string ?? "arm64"), "os": .string(config["os"]?.string ?? "linux")]
            // One index entry per tag, as Docker gives the image every name it lists; an
            // image without one loads untagged.
            let tags = image["RepoTags"]?.strings ?? []
            for tag in tags.isEmpty ? [nil] : tags.map(Optional.some) {
                var d: [String: JSON] = [
                    "mediaType": "application/vnd.oci.image.manifest.v1+json", "digest": .string(manifestBlob.digest),
                    "size": .int(manifestBlob.size), "platform": platform,
                ]
                if let tag { d["annotations"] = ["io.containerd.image.name": .string(ImageRef.normalize(tag))] }
                entries.append(.object(d))
            }
        }
        let index: JSON = ["schemaVersion": 2, "mediaType": "application/vnd.oci.image.index.v1+json", "manifests": .array(entries)]
        try index.encoded().write(to: dir.appending(path: "index.json"), options: .atomic)
        try Data(#"{"imageLayoutVersion":"1.0.0"}"#.utf8).write(to: dir.appending(path: "oci-layout"), options: .atomic)
    }

    /// An archive member the manifest names: a regular file inside `dir`. The names are
    /// the archive's, so untrusted: no `..`; a leading `/` is the archive's root, as Docker
    /// reads it (go-containerregistry writes `/sha256:….tar`).
    static func member(_ dir: URL, _ name: String) throws -> URL {
        let parts = name.split(separator: "/").map(String.init).filter { $0 != "." }
        guard !parts.isEmpty, !parts.contains("..") else {
            throw APIError(400, "pratico: the archive's manifest.json names a file outside it: \(name)")
        }
        let url = parts.reduce(dir) { $0.appending(path: $1) }
        var st = stat()
        guard lstat(url.path, &st) == 0, st.st_mode & S_IFMT == S_IFREG else {
            throw APIError(400, "pratico: the archive's manifest.json names \(name), which the archive does not hold")
        }
        return url
    }

    static func isGzip(_ file: URL) throws -> Bool {
        let h = try FileHandle(forReadingFrom: file)
        defer { try? h.close() }
        return try h.read(upToCount: 2) == Data([0x1f, 0x8b])
    }
}
