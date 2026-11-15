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

    /// How people see an image: its first tag, else its short ID, as `docker images` does.
    static func displayName(refs: [String], id: String) -> String {
        refs.first.map(familiar) ?? String(id.dropFirst(7).prefix(12))
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
    var displayName: String { ImageRef.displayName(refs: refs, id: id) }
    var shortId: String { String(id.dropFirst(7).prefix(12)) }
}

public final class ImageService: Sendable {
    let backend: any ImageBackend
    /// Image events as dockerd sends them: pull, tag, untag, delete, prune.
    let events: EventBus

    init(backend: any ImageBackend, events: EventBus) {
        self.backend = backend
        self.events = events
    }

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

    /// `GET /images/{name}/history`, newest first. A config history entry that made a
    /// layer gets that layer's size, compressed as stored; the newest entry carries the
    /// image's ID and tags, as Docker reports them.
    static func history(_ img: JSON, tags: [String]) -> [JSON] {
        let variant = variant(img)
        let entries = variant?["config"]?["history"]?.array ?? []
        let layers = variant?["layers"]?.array?.compactMap(\.int) ?? []
        precondition(entries.count < 100_000, "image history beyond any real image")
        var next = 0
        var out: [JSON] = []
        for entry in entries {
            let empty = entry["empty_layer"]?.bool ?? false
            let size = empty || next >= layers.count ? 0 : layers[next]
            if !empty { next += 1 }
            out.append([
                "Id": "<missing>",
                "Created": .int(Int64(Timestamp.parse(entry["created"]?.string ?? "")?.timeIntervalSince1970 ?? 0)),
                "CreatedBy": entry["created_by"] ?? "",
                "Tags": .null,
                "Size": .int(size),
                "Comment": entry["comment"] ?? "",
            ])
        }
        out.reverse()
        if !out.isEmpty {
            out[0] = .object((out[0].object ?? [:]).merging(["Id": .string(id(img)), "Tags": JSON(tags)]) { _, b in b })
        }
        return out
    }

    static func created(_ img: JSON) -> String { img["configuration"]?["creationDate"]?.string ?? "" }

    static func digests(_ img: LocalImage) -> [String] {
        guard let digest = img.record["configuration"]?["descriptor"]?["digest"]?.string else { return [] }
        let repos = img.refs.map { ref in ref.lastIndex(of: ":").map { String(ref[..<$0]) } ?? ref }
        return Array(Set(repos)).sorted().map { ImageRef.familiar($0) + "@" + digest }
    }

    /// `GET /images/json`: newest first, with Docker's `reference` (a glob on `name:tag` or
    /// the repository; only matching tags are reported), `dangling`, `label`, `before`, and
    /// `since` filters.
    func list(filters: [String: [String]]) -> [JSON] {
        let all = localImages()
        let created = { (img: LocalImage) in Timestamp.parse(Self.created(img.record))?.timeIntervalSince1970 ?? 0 }
        let bound = { (refs: [String]?) in refs?.compactMap { self.resolve($0).map { created($0.image) } } ?? [] }
        let before = bound(filters["before"]).min(), since = bound(filters["since"]).max()
        var out: [(Double, JSON)] = []
        for img in all {
            var tags = img.tags
            if let patterns = filters["reference"], !patterns.isEmpty {
                tags = tags.filter { tag in
                    let repo = String(tag.split(separator: ":").first ?? "")
                    return patterns.contains { fnmatch($0, tag, 0) == 0 || fnmatch($0, repo, 0) == 0 }
                }
                if tags.isEmpty { continue }
            }
            // Every image here has a reference, so none is dangling.
            if Filters.bool(filters, "dangling") == true { continue }
            let labels = Self.config(img.record)["Labels"]?.object?.compactMapValues(\.string) ?? [:]
            if !Filters.labels(filters["label"], in: labels) { continue }
            let t = created(img)
            if let before, t >= before { continue }
            if let since, t <= since { continue }
            var summary = Self.summary(img)
            summary["RepoTags"] = JSON(tags)
            // Digests too, or the CLI shows a `<none>` row for every other repository.
            let repos = Set(tags.map { String($0.split(separator: ":").first ?? "") })
            summary["RepoDigests"] = JSON(Self.digests(img).filter { repos.contains(String($0.split(separator: "@").first ?? "")) })
            out.append((t, summary))
        }
        return out.sorted { $0.0 > $1.0 }.map(\.1)
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

    /// What `prune -a` removes when the containers using `used` stay: every other image.
    /// The Disk menu's cleanup plans use the same rule, so they list what prune deletes.
    func unused(keeping used: Set<String>) -> [LocalImage] { localImages().filter { !used.contains($0.id) } }

    func tag(_ source: String, repo: String, tag: String?) throws {
        guard let (img, matched) = resolve(source) else { throw APIError(404, "No such image: \(source)") }
        guard !repo.isEmpty else { throw APIError(400, "repository name must be given") }
        let target = ImageRef.normalize(ImageRef.join(repo, tag: tag.flatMap { $0.isEmpty ? nil : $0 } ?? "latest"))
        do { try backend.tag(matched ?? img.refs[0], target) } catch {
            throw APIError(500, "cannot tag image: \(error)")
        }
        events.emit("image", "tag", id: img.id, attributes: ["name": ImageRef.familiar(target)])
    }

    /// `DELETE /images/{name}`: by reference untags it (deleting the image with its last
    /// tag); by ID removes every reference. Images in use need `force`, as in Docker.
    func remove(_ nameOrId: String, force: Bool) throws -> [JSON] {
        guard let (img, matched) = resolve(nameOrId) else { throw APIError(404, "No such image: \(nameOrId)") }
        let short = img.shortId
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
            events.emit("image", "untag", id: img.id, attributes: ["name": ImageRef.familiar(ref)])
        }
        if removesImage {
            out.append(["Deleted": .string(img.id)])
            events.emit("image", "delete", id: img.id, attributes: ["name": img.id])
        }
        return out
    }

    /// `POST /images/prune`. Every Apple image has a reference, so nothing is dangling and
    /// the default prune removes nothing; `dangling=false` (`prune -a`) removes unused images.
    /// Either way, blobs no image references are collected too.
    func prune(filters: [String: [String]]) throws -> JSON {
        let filter = try PruneFilter(filters, allowed: ["dangling", "until", "label", "label!"])
        guard filters["dangling"]?.contains(where: { $0 == "false" || $0 == "0" }) == true else {
            let reclaimed = backend.removeUnreferencedBlobs()
            events.emit("image", "prune", id: "", attributes: ["reclaimed": String(reclaimed)])
            return ["ImagesDeleted": .null, "SpaceReclaimed": .int(reclaimed)]
        }
        var deleted: [JSON] = []
        var reclaimed: Int64 = 0
        for img in unused(keeping: inUse()) {
            let created = Timestamp.parse(Self.created(img.record)) ?? .distantPast
            let labels = Self.config(img.record)["Labels"]?.object?.compactMapValues(\.string) ?? [:]
            guard filter.matches(created: created, labels: labels), let items = try? remove(img.id, force: true) else { continue }
            deleted += items
            reclaimed += Self.variant(img.record)?["size"]?.int ?? 0
        }
        reclaimed += backend.removeUnreferencedBlobs()
        events.emit("image", "prune", id: "", attributes: ["reclaimed": String(reclaimed)])
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
        events.emit("image", "pull", id: familiar, attributes: ["name": String(familiar.split(separator: ":").first ?? "")])
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

    /// `POST /images/load` (`docker load`): an archive with an OCI `index.json`, as Docker 25
    /// and later and `docker save` here write. Index entries without a name take, in order,
    /// the `RepoTags` of `manifest.json`. Replies with Docker's JSON lines.
    func load(_ archive: URL, quiet: Bool, conn: Connection) throws -> [String] {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appending(path: "pratico-load-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        // No symlinks in an image archive: index.json and blobs are read and written here.
        try Tar.extract(archive, to: dir, links: false, maxBytes: Tar.unpackLimit(at: dir))
        let indexFile = dir.appending(path: "index.json")
        guard var index = (try? Data(contentsOf: indexFile)).flatMap(JSON.parse), var entries = index["manifests"]?.array else {
            throw APIError(400, "pratico: this archive has no OCI index.json (Docker before 25 wrote archives without one); save it again with Docker 25 or later, or pull the image")
        }
        let tags = ((try? Data(contentsOf: dir.appending(path: "manifest.json"))).flatMap(JSON.parse)?.array ?? [])
            .compactMap { $0["RepoTags"]?.strings?.first }
        let nameKeys = ["com.apple.containerization.image.name", "io.containerd.image.name"]
        for i in entries.indices where nameKeys.allSatisfy({ entries[i]["annotations"]?[$0] == nil }) && i < tags.count {
            var notes = entries[i]["annotations"]?.object ?? [:]
            notes["io.containerd.image.name"] = .string(ImageRef.normalize(tags[i]))
            entries[i]["annotations"] = .object(notes)
        }
        index["manifests"] = .array(entries)
        try index.encoded().write(to: indexFile, options: .atomic)
        let refs: [String]
        do { refs = try backend.loadLayout(from: dir) } catch {
            throw APIError(400, "cannot load the archive: \(error)")
        }
        conn.beginChunked()
        for ref in refs {
            let name = ImageRef.familiar(ref)
            if let img = resolve(ref)?.image { events.emit("image", "load", id: img.id, attributes: ["name": name]) }
            conn.chunk((["stream": .string("Loaded image: \(name)\n")] as JSON).encoded() + Data("\n".utf8))
        }
        conn.endChunked()
        return refs
    }

    /// `GET /images/{name}/get` and `GET /images/get?names=…` (`docker save`, D-23).
    func save(_ names: [String], conn: Connection) throws {
        let fm = FileManager.default
        let file = fm.temporaryDirectory.appending(path: "pratico-save-\(UUID().uuidString).tar")
        defer { try? fm.removeItem(at: file) }
        _ = try exportArchive(names, to: file)
        let h = try FileHandle(forReadingFrom: file)
        defer { try? h.close() }
        conn.beginChunked(contentType: "application/x-tar")
        while case let data = h.readData(ofLength: 1 << 20), !data.isEmpty {
            if !conn.chunk(data) { break }
        }
        conn.endChunked()
    }

    @discardableResult
    func exportArchive(_ nameOrId: String, to file: URL) throws -> LocalImage {
        try exportArchive([nameOrId], to: file)[0]
    }

    /// Writes a Docker archive of the images to `file`. Backends save an OCI layout; Docker's
    /// archive is that layout plus a `manifest.json`, which scanners (osv-scanner, grype,
    /// trivy, snyk) need. Several images share one `blobs/` (a layer two hold is stored
    /// once), one `index.json`, and one `manifest.json` entry each, as `docker save a b`
    /// writes them. Entries are written without a `./` prefix, which some tools reject.
    @discardableResult
    func exportArchive(_ names: [String], to file: URL) throws -> [LocalImage] {
        guard !names.isEmpty else { throw APIError(400, "names is required") }
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appending(path: "pratico-export-\(UUID().uuidString)")
        let dir = work.appending(path: "image")
        let blobs = dir.appending(path: "blobs/sha256")
        try fm.createDirectory(at: blobs, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        var saved: [LocalImage] = []
        var docker: [JSON] = []
        var index: [JSON] = []
        for (n, nameOrId) in names.enumerated() {
            guard let (img, matched) = resolve(nameOrId) else { throw APIError(404, "No such image: \(nameOrId)") }
            let ref = matched ?? img.refs[0]
            let one = work.appending(path: "one-\(n)")
            try fm.createDirectory(at: one, withIntermediateDirectories: true)
            let platform = Self.variant(img.record)?["platform"]
            let arch = platform?["architecture"]?.string ?? "arm64"
            let os = platform?["os"]?.string ?? "linux"
            do { try backend.saveLayout(ref, os: os, arch: arch, into: one) } catch {
                throw APIError(500, "cannot save \(ImageRef.familiar(ref)): \(error)")
            }

            // Digests come from the archive's JSON: only well-formed ones become paths.
            func blob(_ digest: String?) -> JSON? {
                guard let digest, Self.isDigest(digest) else { return nil }
                return (try? Data(contentsOf: one.appending(path: "blobs/sha256/\(digest.dropFirst(7))"))).flatMap(JSON.parse)
            }
            // index.json → (nested indexes, bounded) → the platform's image manifest.
            let top = (try? Data(contentsOf: one.appending(path: "index.json"))).flatMap(JSON.parse)
            var node = top
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
            docker.append(["Config": path(config), "RepoTags": [.string(ImageRef.familiar(ref))], "Layers": .array(layers.map(path))])
            index += top?["manifests"]?.array ?? []
            for name in (try? fm.contentsOfDirectory(atPath: one.appending(path: "blobs/sha256").path)) ?? [] {
                let target = blobs.appending(path: name)
                if !fm.fileExists(atPath: target.path) { try fm.moveItem(at: one.appending(path: "blobs/sha256/\(name)"), to: target) }
            }
            if n == 0 { try fm.copyItem(at: one.appending(path: "oci-layout"), to: dir.appending(path: "oci-layout")) }
            try? fm.removeItem(at: one)
            saved.append(img)
        }
        try JSON.array(docker).encoded().write(to: dir.appending(path: "manifest.json"))
        try (["schemaVersion": 2, "mediaType": "application/vnd.oci.image.index.v1+json", "manifests": .array(index)] as JSON)
            .encoded().write(to: dir.appending(path: "index.json"))

        do { try Tar.create(file, base: dir, names: ["manifest.json", "index.json", "oci-layout", "blobs"]) } catch {
            throw APIError(500, "cannot write image archive: \(error)")
        }
        return saved
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
