import Foundation

/// Docker image references, normalized the way Docker does (`alpine` is
/// `docker.io/library/alpine:latest`), which is also how Apple `container` names images.
public enum ImageRef {
    public static func normalize(_ ref: String) -> String {
        var name = ref
        var digest: String?
        if let at = name.firstIndex(of: "@") {
            digest = String(name[at...])
            name = String(name[..<at])
        }
        var tag: String?
        if let colon = name.lastIndex(of: ":"), !name[colon...].contains("/") {
            tag = String(name[name.index(after: colon)...])
            name = String(name[..<colon])
        }
        let parts = name.split(separator: "/", maxSplits: 1).map(String.init)
        let first = parts[0]
        let hasRegistry = parts.count > 1 && (first.contains(".") || first.contains(":") || first == "localhost")
        if !hasRegistry {
            name = parts.count == 1 ? "docker.io/library/\(name)" : "docker.io/\(name)"
        }
        if let digest { return name + (tag.map { ":\($0)" } ?? "") + digest }
        return "\(name):\(tag ?? "latest")"
    }

    /// Short form Docker shows users: `docker.io/library/alpine:latest` is `alpine:latest`.
    public static func familiar(_ ref: String) -> String {
        for prefix in ["docker.io/library/", "docker.io/"] where ref.hasPrefix(prefix) {
            return String(ref.dropFirst(prefix.count))
        }
        return ref
    }

    /// Reference Docker passes to `POST /images/create` as `fromImage` + `tag`.
    public static func join(_ image: String, tag: String?) -> String {
        guard let tag, !tag.isEmpty else { return image }
        return tag.hasPrefix("sha256:") ? "\(image)@\(tag)" : "\(image):\(tag)"
    }
}

struct LocalImage {
    var id: String  // sha256:<index digest>
    var record: JSON  // first Apple record; all share the same content
    var refs: [String]  // full references

    var tags: [String] { refs.map(ImageRef.familiar) }
}

public final class ImageService: Sendable {
    let backend: any ImageBackend

    init(backend: any ImageBackend) { self.backend = backend }

    /// Finds an image by reference or by (possibly short, possibly `sha256:`-prefixed) ID.
    public func find(_ nameOrId: String) -> JSON? {
        if let img = backend.image(ImageRef.normalize(nameOrId)) { return img }
        let id = nameOrId.hasPrefix("sha256:") ? String(nameOrId.dropFirst(7)) : nameOrId
        guard id.count >= 4, id.allSatisfy(\.isHexDigit) else { return nil }
        return backend.images().first { $0["id"]?.string?.hasPrefix(id) == true }
    }

    static func variant(_ img: JSON) -> JSON? {
        let variants = img["variants"]?.array ?? []
        return variants.first { $0["platform"]?["architecture"]?.string == "arm64" } ?? variants.first
    }

    /// Image runtime config (`Cmd`, `Entrypoint`, `Env`, `WorkingDir`, ...).
    public static func config(_ img: JSON) -> JSON { variant(img)?["config"]?["config"] ?? [:] }

    static func id(_ img: JSON) -> String { "sha256:" + (img["id"]?.string ?? "") }

    static func created(_ img: JSON) -> String { img["configuration"]?["creationDate"]?.string ?? "" }

    static func digests(_ img: LocalImage) -> [String] {
        guard let digest = img.record["configuration"]?["descriptor"]?["digest"]?.string else { return [] }
        let repos = img.refs.map { ref in ref.lastIndex(of: ":").map { String(ref[..<$0]) } ?? ref }
        return Array(Set(repos)).sorted().map { ImageRef.familiar($0) + "@" + digest }
    }

    /// `GET /images/json` entry.
    static func summary(_ img: LocalImage) -> JSON {
        let size = variant(img.record)?["size"]?.int ?? 0
        return [
            "Id": .string(img.id),
            "ParentId": "",
            "RepoTags": JSON(img.tags),
            "RepoDigests": JSON(digests(img)),
            "Created": .int(Int64(Timestamp.parse(created(img.record))?.timeIntervalSince1970 ?? 0)),
            "Size": .int(size),
            "SharedSize": -1,
            "VirtualSize": .int(size),
            "Labels": config(img.record)["Labels"] ?? [:],
            "Containers": -1,
        ]
    }

    /// `GET /images/{name}/json` body.
    static func inspect(_ img: LocalImage) -> JSON {
        let v = variant(img.record)
        let cfg = config(img.record)
        return [
            "Id": .string(img.id),
            "RepoTags": JSON(img.tags),
            "RepoDigests": JSON(digests(img)),
            "Parent": "",
            "Comment": "",
            "Created": .string(created(img.record)),
            "DockerVersion": "",
            "Author": "",
            "Config": cfg,
            "Architecture": v?["platform"]?["architecture"] ?? "arm64",
            "Variant": v?["platform"]?["variant"] ?? .null,
            "Os": v?["platform"]?["os"] ?? "linux",
            "Size": v?["size"] ?? 0,
            "GraphDriver": ["Name": "pratico", "Data": .null],
            "RootFS": ["Type": "layers", "Layers": v?["config"]?["rootfs"]?["diff_ids"] ?? []],
            "Metadata": ["LastTagTime": "0001-01-01T00:00:00Z"],
        ]
    }

    // MARK: Local images, tag, remove, prune (SPEC FR-21)

    /// Apple keeps one record per reference; Docker shows one image per ID with all its tags.
    func localImages() -> [LocalImage] {
        var byId: [String: LocalImage] = [:]
        var order: [String] = []
        for r in backend.images() {
            let id = Self.id(r)
            let ref = r["configuration"]?["name"]?.string
            if byId[id] == nil {
                byId[id] = LocalImage(id: id, record: r, refs: [])
                order.append(id)
            }
            if let ref { byId[id]?.refs.append(ref) }
        }
        return order.compactMap { byId[$0] }
    }

    /// By reference (`matched` is that reference) or by ID prefix (`matched` is nil).
    func resolve(_ nameOrId: String) -> (image: LocalImage, matched: String?)? {
        let all = localImages()
        let full = ImageRef.normalize(nameOrId)
        if let img = all.first(where: { $0.refs.contains(full) }) { return (img, full) }
        let hex = nameOrId.hasPrefix("sha256:") ? String(nameOrId.dropFirst(7)) : nameOrId
        guard hex.count >= 4, hex.allSatisfy(\.isHexDigit) else { return nil }
        let matches = all.filter { $0.id.dropFirst(7).hasPrefix(hex) }
        return matches.count == 1 ? (matches[0], nil) : nil
    }

    /// Image IDs used by containers (for the Apple backend, Docker-created or not).
    func inUse() -> Set<String> { backend.inUse() }

    func tag(_ source: String, repo: String, tag: String?) throws {
        guard let (img, matched) = resolve(source) else { throw APIError(404, "No such image: \(source)") }
        guard !repo.isEmpty else { throw APIError(400, "repository name must be given") }
        let target = ImageRef.normalize(ImageRef.join(repo, tag: tag.flatMap { $0.isEmpty ? nil : $0 } ?? "latest"))
        do { try backend.tag(matched ?? img.refs[0], target) } catch {
            throw APIError(500, "cannot tag image: \(error)")
        }
    }

    /// `DELETE /images/{name}`: by reference untags it (deleting the image with its last
    /// tag); by ID removes every reference. Images in use need `force`, as in Docker.
    func remove(_ nameOrId: String, force: Bool) throws -> [JSON] {
        guard let (img, matched) = resolve(nameOrId) else { throw APIError(404, "No such image: \(nameOrId)") }
        let short = String(img.id.dropFirst(7).prefix(12))
        let refs = matched.map { [$0] } ?? img.refs
        let removesImage = refs.count == img.refs.count
        if matched == nil && img.refs.count > 1 && !force {
            throw APIError(409, "conflict: unable to delete \(short) (must be forced) - image is referenced in multiple repositories")
        }
        if removesImage && !force && inUse().contains(img.id) {
            throw APIError(409, "conflict: unable to remove repository reference \"\(nameOrId)\" (must force) - image \(short) is being used by a container")
        }
        var out: [JSON] = []
        for ref in refs {
            do { try backend.delete(ref) } catch {
                throw APIError(500, "cannot remove \(ImageRef.familiar(ref)): \(error)")
            }
            out.append(["Untagged": .string(ImageRef.familiar(ref))])
        }
        if removesImage { out.append(["Deleted": .string(img.id)]) }
        return out
    }

    /// `POST /images/prune`. Every Apple image has a reference, so nothing is dangling and
    /// the default prune removes nothing; `dangling=false` (`prune -a`) removes unused images.
    /// Either way, blobs no image references are collected too.
    func prune(filters: [String: [String]]) -> JSON {
        guard filters["dangling"]?.contains(where: { $0 == "false" || $0 == "0" }) == true else {
            return ["ImagesDeleted": .null, "SpaceReclaimed": .int(backend.removeUnreferencedBlobs())]
        }
        let used = inUse()
        var deleted: [JSON] = []
        var reclaimed: Int64 = 0
        for img in localImages() where !used.contains(img.id) {
            guard let items = try? remove(img.id, force: true) else { continue }
            deleted += items
            reclaimed += Self.variant(img.record)?["size"]?.int ?? 0
        }
        reclaimed += backend.removeUnreferencedBlobs()
        return ["ImagesDeleted": deleted.isEmpty ? .null : .array(deleted), "SpaceReclaimed": .int(reclaimed)]
    }

    /// `POST /images/create`: pulls through the backend, streaming Docker-style JSON
    /// progress lines (SPEC FR-8).
    func pull(_ ref: String, platform: String?, auth: RegistryAuth?, conn: Connection) {
        let full = ImageRef.normalize(ref)
        let familiar = ImageRef.familiar(full)
        let tag = full.split(separator: ":").last.map(String.init) ?? "latest"
        conn.beginChunked()
        defer { conn.endChunked() }
        let emit = Self.emitter(conn)
        let existed = backend.image(full) != nil
        emit(["status": .string("Pulling from \(familiar.split(separator: ":").first ?? "")"), "id": .string(tag)])
        do {
            try backend.pull(full, platform: platform, auth: auth, progress: Self.tagged(emit, tag))
        } catch {
            return Self.fail("pull access denied or manifest unknown for \(familiar): \(error)", emit)
        }
        if let d = backend.image(full)?["configuration"]?["descriptor"]?["digest"]?.string {
            emit(["status": .string("Digest: \(d)")])
        }
        let status = existed ? "Image is up to date for \(familiar)" : "Downloaded newer image for \(familiar)"
        emit(["status": .string("Status: \(status)")])
    }

    /// `POST /images/{name}/push` (SPEC FR-22), ending with the `aux` digest record the
    /// Docker CLI prints.
    func push(_ ref: String, auth: RegistryAuth?, conn: Connection) throws {
        let full = ImageRef.normalize(ref)
        guard let img = backend.image(full) else {
            throw APIError(404, "An image does not exist locally with the tag: \(ImageRef.familiar(full))")
        }
        let tag = full.split(separator: ":").last.map(String.init) ?? "latest"
        let repo = ImageRef.familiar(String(full.dropLast(tag.count + 1)))
        conn.beginChunked()
        defer { conn.endChunked() }
        let emit = Self.emitter(conn)
        emit(["status": .string("The push refers to repository [\(repo)]")])
        do {
            try backend.push(full, auth: auth, progress: Self.tagged(emit, tag))
        } catch {
            return Self.fail("push to \(repo) failed: \(error)", emit)
        }
        let digest = img["configuration"]?["descriptor"]?["digest"]?.string ?? ""
        let size = img["configuration"]?["descriptor"]?["size"]?.int ?? 0
        emit(["status": .string("\(tag): digest: \(digest) size: \(size)")])
        emit(["progressDetail": [:], "aux": ["Tag": .string(tag), "Digest": .string(digest), "Size": .int(size)]])
    }

    /// `GET /images/{name}/get` (`docker save`), D-23.
    func save(_ nameOrId: String, conn: Connection) throws {
        let fm = FileManager.default
        let file = fm.temporaryDirectory.appending(path: "pratico-save-\(UUID().uuidString).tar")
        defer { try? fm.removeItem(at: file) }
        _ = try exportArchive(nameOrId, to: file)
        let h = try FileHandle(forReadingFrom: file)
        defer { try? h.close() }
        conn.beginChunked(contentType: "application/x-tar")
        while case let data = h.readData(ofLength: 1 << 20), !data.isEmpty {
            if !conn.chunk(data) { break }
        }
        conn.endChunked()
    }

    /// Writes a Docker archive of the image to `file`. Backends save an OCI layout; Docker's
    /// archive is that layout plus a `manifest.json`, which scanners (osv-scanner, grype,
    /// trivy, snyk) need. Entries are written without a `./` prefix, which some reject.
    @discardableResult
    func exportArchive(_ nameOrId: String, to file: URL) throws -> LocalImage {
        guard let (img, matched) = resolve(nameOrId) else { throw APIError(404, "No such image: \(nameOrId)") }
        let ref = matched ?? img.refs[0]
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appending(path: "pratico-export-\(UUID().uuidString)")
        let dir = work.appending(path: "image")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        let platform = Self.variant(img.record)?["platform"]
        let arch = platform?["architecture"]?.string ?? "arm64"
        let os = platform?["os"]?.string ?? "linux"
        do { try backend.saveLayout(ref, os: os, arch: arch, into: dir) } catch {
            throw APIError(500, "cannot save \(ImageRef.familiar(ref)): \(error)")
        }

        // Digests come from the archive's JSON: only well-formed ones become paths.
        func blob(_ digest: String?) -> JSON? {
            guard let digest, Self.isDigest(digest) else { return nil }
            return (try? Data(contentsOf: dir.appending(path: "blobs/sha256/\(digest.dropFirst(7))"))).flatMap(JSON.parse)
        }
        // index.json → (nested indexes, bounded) → the platform's image manifest.
        var node = (try? Data(contentsOf: dir.appending(path: "index.json"))).flatMap(JSON.parse)
        var depth = 0
        while let manifests = node?["manifests"]?.array {
            depth += 1
            guard depth <= 8 else { throw APIError(500, "saved image index nests too deeply") }
            let pick = manifests.first { $0["platform"]?["architecture"]?.string == arch } ?? manifests.first
            node = blob(pick?["digest"]?.string)
        }
        let layers = (node?["layers"]?.array ?? []).compactMap { $0["digest"]?.string }
        guard let config = node?["config"]?["digest"]?.string, Self.isDigest(config), layers.allSatisfy(Self.isDigest) else {
            throw APIError(500, "saved image has no valid manifest for \(os)/\(arch)")
        }
        let path: (String) -> JSON = { .string("blobs/sha256/\($0.dropFirst(7))") }
        let docker: JSON = [[
            "Config": path(config),
            "RepoTags": [.string(ImageRef.familiar(ref))],
            "Layers": .array(layers.map(path)),
        ]]
        try docker.encoded().write(to: dir.appending(path: "manifest.json"))

        do { try Tar.create(file, base: dir, names: ["manifest.json", "index.json", "oci-layout", "blobs"]) } catch {
            throw APIError(500, "cannot write image archive: \(error)")
        }
        return img
    }

    static func isDigest(_ s: String) -> Bool {
        s.count == 71 && s.hasPrefix("sha256:") && s.dropFirst(7).allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    private static func emitter(_ conn: Connection) -> @Sendable (JSON) -> Void {
        { v in conn.chunk(v.encoded() + Data("\n".utf8)) }
    }

    /// Backend progress messages carry no `id`; Docker groups lines by it.
    private static func tagged(_ emit: @escaping @Sendable (JSON) -> Void, _ id: String) -> @Sendable (JSON) -> Void {
        { v in
            var o = v.object ?? [:]
            o["id"] = .string(id)
            emit(.object(o))
        }
    }

    private static func fail(_ msg: String, _ emit: (JSON) -> Void) {
        emit(["errorDetail": ["message": .string(msg)], "error": .string(msg)])
    }
}
