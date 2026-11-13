import Containerization
import ContainerizationExtras
import ContainerizationOCI
import Foundation

/// Where images live. `ImageService` keeps the Docker semantics on top; a backend
/// stores, names, and moves image content. Records use the Apple `container` JSON shape
/// (`id`, `configuration.name/descriptor/creationDate`, `variants[].platform/size/config`)
/// that `ImageService` was written against.
protocol ImageBackend: Sendable {
    func images() -> [JSON]
    func image(_ ref: String) -> JSON?
    /// Image IDs (`sha256:<index digest>`) of containers this backend knows about.
    func inUse() -> Set<String>
    func tag(_ source: String, _ target: String) throws
    func delete(_ ref: String) throws
    /// Deletes stored blobs no image references (failed pulls, older layouts); bytes freed.
    func removeUnreferencedBlobs() -> Int64
    /// `progress` gets Docker JSON progress messages, without `id`.
    func pull(_ ref: String, platform: String?, auth: RegistryAuth?, progress: @escaping @Sendable (JSON) -> Void) throws
    func push(_ ref: String, auth: RegistryAuth?, progress: @escaping @Sendable (JSON) -> Void) throws
    /// Writes the image's OCI layout (`index.json`, `oci-layout`, `blobs/`) for one platform.
    func saveLayout(_ ref: String, os: String, arch: String, into dir: URL) throws
    /// `docker login`: checks the credentials with the registry and keeps them for later
    /// pulls and pushes that come without `X-Registry-Auth`. Throws `APIError(401)` when
    /// the registry refuses them.
    func login(_ auth: RegistryAuth) throws
}

struct BackendError: Error, CustomStringConvertible {
    var description: String
    init(_ description: String) { self.description = description }
}

// MARK: - Apple `container` CLI

/// The original backend: Apple's `container` CLI and its image store.
struct AppleImageBackend: ImageBackend {
    func removeUnreferencedBlobs() -> Int64 { 0 }  // Apple's store is its own

    let runtime: AppleContainer

    func images() -> [JSON] { runtime.images() }
    func image(_ ref: String) -> JSON? { runtime.image(ref) }

    func inUse() -> Set<String> {
        Set(runtime.containers().compactMap { $0["configuration"]?["image"]?["descriptor"]?["digest"]?.string })
    }

    func tag(_ source: String, _ target: String) throws {
        let r = runtime.run(["image", "tag", source, target])
        guard r.ok else { throw BackendError(r.errorText) }
    }

    func delete(_ ref: String) throws {
        let r = runtime.run(["image", "delete", ref])
        guard r.ok else { throw BackendError(r.errorText) }
    }

    func pull(_ ref: String, platform: String?, auth: RegistryAuth?, progress: @escaping @Sendable (JSON) -> Void) throws {
        try login(ref, auth)
        var args = ["image", "pull", "--progress", "plain"] + RegistryAuth.schemeArgs(RegistryAuth.host(ofImage: ref))
        if let platform, !platform.isEmpty { args += ["--platform", platform] }
        try stream(args + [ref], progress)
    }

    func push(_ ref: String, auth: RegistryAuth?, progress: @escaping @Sendable (JSON) -> Void) throws {
        try login(ref, auth)
        try stream(["image", "push", "--progress", "plain"] + RegistryAuth.schemeArgs(RegistryAuth.host(ofImage: ref)) + [ref], progress)
    }

    func saveLayout(_ ref: String, os: String, arch: String, into dir: URL) throws {
        let archive = dir.deletingLastPathComponent().appending(path: "oci.tar").path
        let r = runtime.run(["image", "save", "--platform", "\(os)/\(arch)", "-o", archive, ref])
        guard r.ok else { throw BackendError(r.errorText) }
        do { try Tar.extract(URL(filePath: archive), to: dir) } catch { throw BackendError("cannot unpack saved image: \(error)") }
    }

    /// Apple takes credentials only from its Keychain, so a forwarded login is stored there.
    /// Credentials named for another server are ignored, never sent elsewhere.
    func login(_ auth: RegistryAuth) throws {
        let r = runtime.login(auth)
        guard r.ok else { throw APIError(401, "login to \(auth.server) failed: \(r.errorText)") }
    }

    private func login(_ ref: String, _ auth: RegistryAuth?) throws {
        guard let auth, auth.server == RegistryAuth.host(ofImage: ref) else { return }
        let r = runtime.login(auth)
        guard r.ok else { throw BackendError("login to \(auth.server) failed: \(r.errorText)") }
    }

    /// Runs `container <args>`, relaying each distinct progress line as a status message.
    private func stream(_ args: [String], _ progress: @Sendable (JSON) -> Void) throws {
        let p = runtime.process(args)
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        try p.run()
        var last = ""
        var pending = Data()
        while case let data = out.fileHandleForReading.availableData, !data.isEmpty {
            pending.append(data)
            while let nl = pending.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
                let line = String(decoding: pending[..<nl], as: UTF8.self).trimmingCharacters(in: .whitespaces)
                pending.removeSubrange(...nl)
                if line.isEmpty || line == last { continue }
                last = line
                progress(["status": .string(line)])
            }
        }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw BackendError(last) }
    }
}

// MARK: - Embedded store

/// pratico's own image store (`~/.pratico/store`, apple/containerization). No other
/// software involved; registry credentials go straight to the registry client.
final class EmbeddedImageBackend: ImageBackend, @unchecked Sendable {
    let store: ImageStore
    let content: LocalContentStore
    let registries: Registries
    /// Image IDs used by Docker containers; set by the daemon.
    var usedBy: @Sendable () -> Set<String> = { [] }

    init(store: ImageStore, content: LocalContentStore, registries: Registries) {
        self.store = store
        self.content = content
        self.registries = registries
    }

    func images() -> [JSON] {
        (try? blocking { [store] in
            var out: [JSON] = []
            for img in try await store.list() where img.reference != EmbeddedRuntime.initReference {
                if let r = try? await Self.record(img) { out.append(r) }
            }
            return out
        }) ?? []
    }

    func image(_ ref: String) -> JSON? {
        try? blocking { [store] in
            guard let img = try await store.getOrNil(reference: ref) else { return nil }
            return try await Self.record(img)
        }
    }

    func inUse() -> Set<String> { usedBy() }

    func tag(_ source: String, _ target: String) throws {
        _ = try blocking { [store] in try await store.tag(existing: source, new: target) }
    }

    func delete(_ ref: String) throws {
        try blocking { [store] in try await store.delete(reference: ref, performCleanup: true) }
    }

    func removeUnreferencedBlobs() -> Int64 {
        (try? blocking { [store] in Int64(try await store.cleanUpOrphanedBlobs().freed) }) ?? 0
    }

    /// pratico's registry client for the image's registry, with the request's credentials
    /// for that registry or the login `docker login` kept, and where the image is on it.
    /// The client's notes (plain HTTP, an extra CA) go to the progress output.
    private func target(_ ref: String, _ auth: RegistryAuth?, _ progress: @escaping @Sendable (JSON) -> Void) throws
        -> (client: RegistrySession, name: String, tag: String, reference: String)
    {
        let reference = ImageRef.normalize(ref)
        let parsed = try Reference.parse(reference)
        guard let tag = parsed.tag ?? parsed.digest else { throw BackendError("invalid tag or digest in \(ref)") }
        let host = RegistryAuth.host(ofImage: ref)
        let client = try RegistrySession(host: host, credentials: registries.credentials(auth, for: host), policy: registries.policy) {
            progress(["status": .string($0)])
        }
        return (client, parsed.path, tag, reference)
    }

    func pull(_ ref: String, platform: String?, auth: RegistryAuth?, progress: @escaping @Sendable (JSON) -> Void) throws {
        let meter = ProgressMeter(progress)
        let wanted = platform.flatMap { try? Platform(from: $0) } ?? .current
        let (client, name, tag, reference) = try target(ref, auth, progress)
        _ = try blocking { [store, content] in
            let root = try await client.resolve(name: name, tag: tag)
            let (id, dir) = try await content.newIngestSession()
            let operation = ImageStore.ImportOperation(name: name, contentStore: content, client: client, ingestDir: dir,
                                                       progress: { events in meter.record(events) })
            do {
                let index = try await operation.import(root: root, matcher: { wanted.os == $0.os && wanted.architecture == $0.architecture && (wanted.variant == nil || wanted.variant == $0.variant) })
                _ = try await content.completeIngestSession(id)
                return try await store.create(description: Image.Description(reference: reference, descriptor: index))
            } catch {
                try? await content.cancelIngestSession(id)
                throw error
            }
        }
        meter.flush()
    }

    func push(_ ref: String, auth: RegistryAuth?, progress: @escaping @Sendable (JSON) -> Void) throws {
        let meter = ProgressMeter(progress)
        let (client, name, tag, reference) = try target(ref, auth, progress)
        let current = Platform.current
        try blocking { [store, content] in
            let img = try await store.get(reference: reference)
            let operation = ImageStore.ExportOperation(name: name, tag: tag, contentStore: content, client: client,
                                                       progress: { events in meter.record(events) })
            _ = try await operation.export(index: img.descriptor, platforms: { $0.os == current.os && $0.architecture == current.architecture })
        }
        meter.flush()
    }

    func saveLayout(_ ref: String, os: String, arch: String, into dir: URL) throws {
        try blocking { [store] in
            try await store.save(references: [ref], out: dir, platform: Platform(arch: arch, os: os))
        }
    }

    func login(_ auth: RegistryAuth) throws { try registries.login(auth) }

    /// The Apple-shaped record `ImageService` reads, built from the store.
    static func record(_ img: Containerization.Image) async throws -> JSON {
        let platform = Platform.current
        let manifest = try await img.manifest(for: platform)
        let configData = try await img.getContent(digest: manifest.config.digest).data()
        let config = JSON.parse(configData) ?? [:]
        let size = manifest.layers.reduce(Int64(0)) { $0 + $1.size }
        let digest = img.digest
        // The content store blobs (hex digests) the image holds, so a shared layer counts once (Disk.swift).
        let blobs = (try? await img.referencedDigests()) ?? []
        return [
            "id": .string(String(digest.dropFirst("sha256:".count))),
            "blobs": JSON(blobs),
            "configuration": [
                "name": .string(img.reference),
                "descriptor": ["digest": .string(digest), "size": .int(img.descriptor.size), "mediaType": .string(img.mediaType)],
                "creationDate": config["created"] ?? "",
            ],
            "variants": [[
                "platform": ["architecture": .string(platform.architecture), "os": .string(platform.os),
                             "variant": platform.variant.map(JSON.string) ?? .null],
                "size": .int(size),
                "config": config,
            ]],
        ]
    }
}

/// Turns the store's byte counters into Docker's `Downloading` progress, at most twice a
/// second.
final class ProgressMeter: @unchecked Sendable {
    private let lock = NSLock()
    private let emit: @Sendable (JSON) -> Void
    private var current: Int64 = 0
    private var total: Int64 = 0
    private var last = Date.distantPast

    init(_ emit: @escaping @Sendable (JSON) -> Void) { self.emit = emit }

    func record(_ events: [ProgressEvent]) {
        lock.lock()
        for e in events {
            switch e {
            case .addSize(let n): current += n
            case .addTotalSize(let n): total += n
            default: break
            }
        }
        let due = Date().timeIntervalSince(last) >= 0.5
        if due { last = Date() }
        let snapshot = (current, total)
        lock.unlock()
        if due { send(snapshot) }
    }

    func flush() {
        lock.lock()
        let snapshot = (current, total)
        lock.unlock()
        if snapshot.1 > 0 { send(snapshot) }
    }

    private func send(_ s: (Int64, Int64)) {
        emit(["status": "Downloading", "progressDetail": ["current": .int(s.0), "total": .int(s.1)]])
    }
}

/// Runs async work from one of the daemon's connection threads (never from a Swift
/// concurrency thread, which this would block).
func blocking<T: Sendable>(_ op: @escaping @Sendable () async throws -> T) throws -> T {
    let result = Box<Result<T, any Error>?>(nil)
    let done = DispatchSemaphore(value: 0)
    Task {
        do { result.value = .success(try await op()) } catch { result.value = .failure(error) }
        done.signal()
    }
    done.wait()
    return try result.value!.get()
}
