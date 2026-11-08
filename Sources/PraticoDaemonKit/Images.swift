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

    static func tags(_ img: JSON) -> [String] {
        [img["configuration"]?["name"]?.string].compactMap { $0 }.map(ImageRef.familiar)
    }

    static func digests(_ img: JSON) -> [String] {
        guard let name = img["configuration"]?["name"]?.string,
            let digest = img["configuration"]?["descriptor"]?["digest"]?.string
        else { return [] }
        let repo = name.lastIndex(of: ":").map { String(name[..<$0]) } ?? name
        return [ImageRef.familiar(repo) + "@" + digest]
    }

    /// `GET /images/json` entry.
    public static func summary(_ img: JSON) -> JSON {
        let size = variant(img)?["size"]?.int ?? 0
        return [
            "Id": .string(id(img)),
            "ParentId": "",
            "RepoTags": JSON(tags(img)),
            "RepoDigests": JSON(digests(img)),
            "Created": .int(Int64(Timestamp.parse(created(img))?.timeIntervalSince1970 ?? 0)),
            "Size": .int(size),
            "SharedSize": -1,
            "VirtualSize": .int(size),
            "Labels": config(img)["Labels"] ?? [:],
            "Containers": -1,
        ]
    }

    /// `GET /images/{name}/json` body.
    public static func inspect(_ img: JSON) -> JSON {
        let v = variant(img)
        let cfg = config(img)
        return [
            "Id": .string(id(img)),
            "RepoTags": JSON(tags(img)),
            "RepoDigests": JSON(digests(img)),
            "Parent": "",
            "Comment": "",
            "Created": .string(created(img)),
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
