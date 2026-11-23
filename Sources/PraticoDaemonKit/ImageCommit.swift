import ContainerizationOCI
import Crypto
import Foundation

/// The image side of `docker commit` (D-47): the base image as an OCI layout, one more
/// layer and a new config and manifest on top, loaded into the store.
extension ImageService {
    /// The new image's ID.
    func commit(onto base: LocalImage, layer: URL, config: JSON, comment: String, author: String, createdBy: String,
                as target: String?, work: URL) throws -> String {
        let layout = work.appending(path: "layout")
        try FileManager.default.createDirectory(at: layout, withIntermediateDirectories: true)
        guard let from = base.refs.first else { throw APIError(500, "pratico: image \(base.shortId) has no reference to save") }
        try backend.saveLayout(from, os: "linux", arch: Platform.current.architecture, into: layout)
        let (manifest, imageConfig) = try Self.baseManifest(layout)
        let layerBlob = try Self.addBlob(file: layer, to: layout)
        let now = Timestamp.format(Date())
        var full = imageConfig.object ?? [:]
        full["config"] = config
        full["created"] = .string(now)
        if !author.isEmpty { full["author"] = .string(author) }
        var rootfs = full["rootfs"]?.object ?? ["type": "layers"]
        rootfs["diff_ids"] = JSON((rootfs["diff_ids"]?.strings ?? []) + [layerBlob.digest])
        full["rootfs"] = .object(rootfs)
        var history = full["history"]?.array ?? []
        history.append(["created": .string(now), "created_by": .string(createdBy), "comment": .string(comment),
                        "author": author.isEmpty ? .null : .string(author)])
        full["history"] = .array(history)
        let configBlob = try Self.addBlob(data: JSON.object(full).encoded(), to: layout)
        let layers = (manifest["layers"]?.array ?? []).map(Self.ociLayer) + [[
            "mediaType": "application/vnd.oci.image.layer.v1.tar", "digest": .string(layerBlob.digest), "size": .int(layerBlob.size),
        ]]
        let newManifest: JSON = [
            "schemaVersion": 2, "mediaType": "application/vnd.oci.image.manifest.v1+json",
            "config": ["mediaType": "application/vnd.oci.image.config.v1+json", "digest": .string(configBlob.digest), "size": .int(configBlob.size)],
            "layers": .array(layers),
        ]
        let manifestBlob = try Self.addBlob(data: newManifest.encoded(), to: layout)
        var descriptor: [String: JSON] = [
            "mediaType": "application/vnd.oci.image.manifest.v1+json", "digest": .string(manifestBlob.digest), "size": .int(manifestBlob.size),
            "platform": ["architecture": .string(Platform.current.architecture), "os": "linux"],
        ]
        if let target { descriptor["annotations"] = ["io.containerd.image.name": .string(target)] }
        let index: JSON = ["schemaVersion": 2, "mediaType": "application/vnd.oci.image.index.v1+json", "manifests": [.object(descriptor)]]
        try index.encoded().write(to: layout.appending(path: "index.json"), options: .atomic)
        let stored: [String]
        do { stored = try backend.loadLayout(from: layout) } catch { throw APIError(500, "pratico: cannot store the committed image: \(error)") }
        // The store wraps the manifest in an index of its own: the image's ID is that.
        guard stored.count == 1, let id = localImages().first(where: { $0.refs.contains(stored[0]) })?.id else {
            throw APIError(500, "pratico: the committed image was stored as \(stored), not one image")
        }
        events.emit("image", "create", id: id, attributes: target.map { ["name": ImageRef.familiar($0)] } ?? [:])
        if let target { events.emit("image", "tag", id: id, attributes: ["name": ImageRef.familiar(target)]) }
        return id
    }

    /// The arm64 manifest and its config in a saved layout, through an index if there is one.
    private static func baseManifest(_ layout: URL) throws -> (manifest: JSON, config: JSON) {
        func blob(_ digest: String?) throws -> JSON {
            guard let digest, digest.hasPrefix("sha256:"), digest.count == 71, digest.dropFirst(7).allSatisfy(\.isHexDigit),
                let j = (try? Data(contentsOf: layout.appending(path: "blobs/sha256/\(digest.dropFirst(7))"))).flatMap(JSON.parse)
            else { throw APIError(500, "pratico: the saved image is missing \(digest ?? "a blob")") }
            return j
        }
        guard let index = (try? Data(contentsOf: layout.appending(path: "index.json"))).flatMap(JSON.parse),
            let top = index["manifests"]?.array?.first
        else { throw APIError(500, "pratico: the saved image has no index.json") }
        var manifest = try blob(top["digest"]?.string)
        // An image index, at most two levels deep: pick the arm64 manifest.
        for _ in 0..<2 where manifest["manifests"] != nil {
            let arm = manifest["manifests"]?.array?.first { $0["platform"]?["architecture"]?.string == Platform.current.architecture }
            manifest = try blob(arm?["digest"]?.string)
        }
        guard manifest["layers"] != nil else { throw APIError(500, "pratico: no arm64 manifest in the saved image") }
        return (manifest, try blob(manifest["config"]?["digest"]?.string))
    }

    /// Docker's layer media types as OCI's, which an OCI manifest must name.
    private static func ociLayer(_ layer: JSON) -> JSON {
        var l = layer.object ?? [:]
        let types = [
            "application/vnd.docker.image.rootfs.diff.tar.gzip": "application/vnd.oci.image.layer.v1.tar+gzip",
            "application/vnd.docker.image.rootfs.diff.tar": "application/vnd.oci.image.layer.v1.tar",
        ]
        if let t = l["mediaType"]?.string, let oci = types[t] { l["mediaType"] = .string(oci) }
        return .object(l)
    }

    static func addBlob(data: Data, to layout: URL) throws -> (digest: String, size: Int64) {
        let hex = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        try data.write(to: layout.appending(path: "blobs/sha256/\(hex)"), options: .atomic)
        return ("sha256:\(hex)", Int64(data.count))
    }

    /// Streams `file` through SHA-256 and moves it into the layout's blobs.
    static func addBlob(file: URL, to layout: URL) throws -> (digest: String, size: Int64) {
        var hash = SHA256()
        var size: Int64 = 0
        let h = try FileHandle(forReadingFrom: file)
        defer { try? h.close() }
        while let chunk = try h.read(upToCount: 1 << 20), !chunk.isEmpty {
            hash.update(data: chunk)
            size += Int64(chunk.count)
        }
        let hex = hash.finalize().map { String(format: "%02x", $0) }.joined()
        let dest = layout.appending(path: "blobs/sha256/\(hex)")
        if !FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.moveItem(at: file, to: dest) }
        return ("sha256:\(hex)", size)
    }
}
