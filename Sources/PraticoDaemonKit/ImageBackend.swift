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
        guard ImageService.tar(["-xf", archive, "-C", dir.path]) else { throw BackendError("cannot unpack saved image") }
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
    /// Image IDs used by Docker containers; set by the daemon.
    var usedBy: @Sendable () -> Set<String> = { [] }

    init(store: ImageStore) { self.store = store }

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

    func pull(_ ref: String, platform: String?, auth: RegistryAuth?, progress: @escaping @Sendable (JSON) -> Void) throws {
        let meter = ProgressMeter(progress)
        let wanted = platform.flatMap { try? Platform(from: $0) } ?? .current
        let host = RegistryAuth.host(ofImage: ref)
        let credentials = Self.credentials(auth, for: host)
        _ = try blocking { [store] in
            try await store.pull(reference: ref, platform: wanted, insecure: Self.insecure(host), auth: credentials,
                                 progress: { events in meter.record(events) })
        }
        meter.flush()
    }

    func push(_ ref: String, auth: RegistryAuth?, progress: @escaping @Sendable (JSON) -> Void) throws {
        let meter = ProgressMeter(progress)
        let host = RegistryAuth.host(ofImage: ref)
        let credentials = Self.credentials(auth, for: host)
        try blocking { [store] in
            try await store.push(reference: ref, platform: .current, insecure: Self.insecure(host), auth: credentials,
                                 progress: { events in meter.record(events) })
        }
        meter.flush()
    }

    func saveLayout(_ ref: String, os: String, arch: String, into dir: URL) throws {
        try blocking { [store] in
            try await store.save(references: [ref], out: dir, platform: Platform(arch: arch, os: os))
        }
    }

    /// pratico's own Keychain items (not Docker's, not Apple `container`'s), one per registry.
    static let keychain = KeychainHelper(securityDomain: "dev.pratico.registry")

    func login(_ auth: RegistryAuth) throws {
        let basic = BasicAuthentication(username: auth.username, password: auth.password)
        let insecure = Self.insecure(auth.server)
        let client = try RegistryClient(reference: "\(auth.server)/pratico/login", insecure: insecure, auth: basic,
                                        tlsConfiguration: TLSUtils.makeEnvironmentAwareTLSConfiguration())
        do {
            try blocking { try await client.ping() }
        } catch {
            let text = String(describing: error)
            if text.contains("wrong credentials") || text.contains("401") || text.contains("403") {
                // Docker's wording; the CLI prints it after "Error response from daemon:".
                throw APIError(401, "Get \"\(insecure ? "http" : "https")://\(auth.server)/v2/\": unauthorized: incorrect username or password")
            }
            throw APIError(500, "login to \(auth.server) failed: \(text)")
        }
        do { try Self.keychain.save(hostname: auth.server, username: auth.username, password: auth.password) } catch {
            throw APIError(500, "pratico: cannot keep the login in the Keychain: \(error)")
        }
    }

    /// The request's credentials for the image's own registry, else the ones `docker login`
    /// kept (clients other than the Docker CLI rarely send any).
    private static func credentials(_ auth: RegistryAuth?, for host: String) -> (any Authentication)? {
        if let auth, auth.server == host { return BasicAuthentication(username: auth.username, password: auth.password) }
        return try? keychain.lookup(hostname: host)
    }

    /// Docker speaks plain HTTP to loopback registries unless they answer TLS. Only a
    /// definite answer is kept: a registry that is not up yet is asked again next time.
    private static func insecure(_ host: String) -> Bool {
        guard !RegistryAuth.schemeArgs(host).isEmpty else { return false }
        return schemes.answer(host) {
            let parts = host.split(separator: ":")
            let client = RegistryClient(host: String(parts[0]), scheme: "https", port: parts.dropFirst().first.flatMap { Int($0) },
                                        tlsConfiguration: TLSUtils.makeEnvironmentAwareTLSConfiguration())
            do {
                try blocking { try await client.ping() }
                return false
            } catch {
                let text = String(describing: error)
                if text.contains("failed with response") { return false }  // an HTTP status over TLS
                if text.contains("Connection refused") || text.contains("rawValue: 61") { return nil }
                return true  // a plain-HTTP server cannot complete a TLS handshake
            }
        } ?? false
    }

    private static let schemes = Memo<String, Bool>()

    /// The Apple-shaped record `ImageService` reads, built from the store.
    static func record(_ img: Containerization.Image) async throws -> JSON {
        let platform = Platform.current
        let manifest = try await img.manifest(for: platform)
        let configData = try await img.getContent(digest: manifest.config.digest).data()
        let config = JSON.parse(configData) ?? [:]
        let size = manifest.layers.reduce(Int64(0)) { $0 + $1.size }
        let digest = img.digest
        return [
            "id": .string(String(digest.dropFirst("sha256:".count))),
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
/// A per-key answer computed once it is known.
final class Memo<Key: Hashable, Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Key: Value] = [:]

    /// `compute` returning nil means "no answer yet": nothing is kept.
    func answer(_ key: Key, _ compute: () -> Value?) -> Value? {
        lock.lock()
        if let v = values[key] { lock.unlock(); return v }
        lock.unlock()
        guard let v = compute() else { return nil }
        lock.lock()
        values[key] = v
        lock.unlock()
        return v
    }
}

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
