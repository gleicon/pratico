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
    let runtime: AppleContainer

    public init(runtime: AppleContainer) { self.runtime = runtime }

    /// Finds an image by reference or by (possibly short, possibly `sha256:`-prefixed) ID.
    public func find(_ nameOrId: String) -> JSON? {
        if let img = runtime.image(ImageRef.normalize(nameOrId)) { return img }
        let id = nameOrId.hasPrefix("sha256:") ? String(nameOrId.dropFirst(7)) : nameOrId
        guard id.count >= 4, id.allSatisfy(\.isHexDigit) else { return nil }
        return runtime.images().first { $0["id"]?.string?.hasPrefix(id) == true }
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
        for r in runtime.images() {
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

    /// Image IDs used by any Apple container, Docker-created or not.
    func inUse() -> Set<String> {
        Set(runtime.containers().compactMap { $0["configuration"]?["image"]?["descriptor"]?["digest"]?.string })
    }

    func tag(_ source: String, repo: String, tag: String?) throws {
        guard let (img, matched) = resolve(source) else { throw APIError(404, "No such image: \(source)") }
        guard !repo.isEmpty else { throw APIError(400, "repository name must be given") }
        let target = ImageRef.normalize(ImageRef.join(repo, tag: tag.flatMap { $0.isEmpty ? nil : $0 } ?? "latest"))
        let r = runtime.run(["image", "tag", matched ?? img.refs[0], target])
        guard r.ok else { throw APIError(500, "cannot tag image: \(r.errorText)") }
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
            let r = runtime.run(["image", "delete", ref])
            guard r.ok else { throw APIError(500, "cannot remove \(ImageRef.familiar(ref)): \(r.errorText)") }
            out.append(["Untagged": .string(ImageRef.familiar(ref))])
        }
        if removesImage { out.append(["Deleted": .string(img.id)]) }
        return out
    }

    /// `POST /images/prune`. Every Apple image has a reference, so nothing is dangling and
    /// the default prune removes nothing; `dangling=false` (`prune -a`) removes unused images.
    func prune(filters: [String: [String]]) -> JSON {
        guard filters["dangling"]?.contains(where: { $0 == "false" || $0 == "0" }) == true else {
            return ["ImagesDeleted": .null, "SpaceReclaimed": 0]
        }
        let used = inUse()
        var deleted: [JSON] = []
        var reclaimed: Int64 = 0
        for img in localImages() where !used.contains(img.id) {
            guard let items = try? remove(img.id, force: true) else { continue }
            deleted += items
            reclaimed += Self.variant(img.record)?["size"]?.int ?? 0
        }
        return ["ImagesDeleted": deleted.isEmpty ? .null : .array(deleted), "SpaceReclaimed": .int(reclaimed)]
    }

    /// `POST /images/create`: pulls through `container image pull`, streaming
    /// Docker-style JSON progress lines (SPEC FR-8).
    public func pull(_ ref: String, platform: String?, conn: Connection) {
        let full = ImageRef.normalize(ref)
        let familiar = ImageRef.familiar(full)
        let tag = full.split(separator: ":").last.map(String.init) ?? "latest"
        conn.beginChunked()
        func emit(_ v: JSON) { conn.chunk(v.encoded() + Data("\n".utf8)) }

        let existed = runtime.image(full) != nil
        emit(["status": .string("Pulling from \(familiar.split(separator: ":").first ?? "")"), "id": .string(tag)])

        var args = ["image", "pull", "--progress", "plain"]
        if let platform, !platform.isEmpty { args += ["--platform", platform] }
        let p = runtime.process(args + [full])
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        do { try p.run() } catch {
            emit(["errorDetail": ["message": .string("\(error)")], "error": .string("\(error)")])
            conn.endChunked()
            return
        }
        var last = ""
        var pending = Data()
        while case let data = out.fileHandleForReading.availableData, !data.isEmpty {
            pending.append(data)
            while let nl = pending.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
                let line = String(decoding: pending[..<nl], as: UTF8.self).trimmingCharacters(in: .whitespaces)
                pending.removeSubrange(...nl)
                if line.isEmpty || line == last { continue }
                last = line
                emit(["status": .string(line), "id": .string(tag)])
            }
        }
        p.waitUntilExit()

        if p.terminationStatus != 0 {
            let msg = "pull access denied or manifest unknown for \(familiar): \(last)"
            emit(["errorDetail": ["message": .string(msg)], "error": .string(msg)])
        } else {
            if let img = runtime.image(full), let d = img["configuration"]?["descriptor"]?["digest"]?.string {
                emit(["status": .string("Digest: \(d)")])
            }
            let status = existed ? "Image is up to date for \(familiar)" : "Downloaded newer image for \(familiar)"
            emit(["status": .string("Status: \(status)")])
        }
        conn.endChunked()
    }
}
