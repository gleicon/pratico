import Containerization
import ContainerizationEXT4
import ContainerizationOCI
import Foundation

/// pratico's runtime (docs/design/runtime.md): one VM per container through
/// apple/containerization, with the kernel and `vminit` shipped inside pratico, so no
/// other software is needed. Images live in pratico's own store, `~/.pratico/store`.
public actor EmbeddedRuntime {
    /// pratico's init images, the bundled one and earlier ones: runtime, never the user's.
    static func isInitImage(_ reference: String) -> Bool {
        reference.hasPrefix("dev.pratico/vminit:") || reference.hasPrefix("ghcr.io/apple/containerization/vminit:")
    }

    private struct LayoutIndex: Decodable {
        struct Manifest: Decodable { var annotations: [String: String]? }
        var manifests: [Manifest]
    }

    /// The bundled init image's reference, from its layout (scripts/build-init.sh tags it
    /// by content, so a new init is a new reference).
    static func initReference(assets: URL) throws -> String {
        let index = try JSONDecoder().decode(LayoutIndex.self, from: Data(contentsOf: assets.appending(path: "vminit/index.json")))
        guard let name = index.manifests.first?.annotations?["io.containerd.image.name"], isInitImage(name) else {
            throw APIError(500, "pratico: the bundled vminit image has no pratico reference")
        }
        return name
    }

    /// Builds `initfs.ext4` from `reference` when it was built from another one (or never):
    /// into a new file, then renamed over the old, so running VMs keep the one they booted.
    static func refreshInitfs(store: ImageStore, root: URL, reference: String) async throws {
        let fm = FileManager.default
        let disk = root.appending(path: "initfs.ext4"), marker = root.appending(path: "initfs.ref")
        if fm.fileExists(atPath: disk.path), (try? String(contentsOf: marker, encoding: .utf8)) == reference { return }
        let fresh = root.appending(path: "initfs.ext4.new")
        try? fm.removeItem(at: fresh)
        _ = try await store.getInitImage(reference: reference).initBlock(at: fresh, for: .linuxArm)
        if fm.fileExists(atPath: disk.path) { _ = try fm.replaceItemAt(disk, withItemAt: fresh) } else { try fm.moveItem(at: fresh, to: disk) }
        try reference.write(to: marker, atomically: true, encoding: .utf8)
    }

    public let assets: URL
    public let store: ImageStore
    /// The store's content, shared with pratico's registry client (`RegistrySession`).
    public let content: LocalContentStore
    private var manager: ContainerManager

    private init(assets: URL, store: ImageStore, content: LocalContentStore, manager: ContainerManager) {
        self.assets = assets
        self.store = store
        self.content = content
        self.manager = manager
    }

    /// Where the kernel and `vminit` are: `PRATICO_RUNTIME_ASSETS`, the app bundle's
    /// `Contents/Resources/runtime`, or a development build's `.build/runtime-assets`.
    public static func locateAssets() -> URL? {
        let fm = FileManager.default
        var candidates: [URL] = []
        if let env = ProcessInfo.processInfo.environment["PRATICO_RUNTIME_ASSETS"] {
            candidates.append(URL(filePath: env, directoryHint: .isDirectory))
        }
        if let exe = Bundle.main.executableURL?.resolvingSymlinksInPath() {
            let contents = exe.deletingLastPathComponent().deletingLastPathComponent()
            candidates.append(contents.appending(path: "Resources/runtime", directoryHint: .isDirectory))
        }
        candidates.append(URL(filePath: fm.currentDirectoryPath).appending(path: ".build/runtime-assets", directoryHint: .isDirectory))
        return candidates.first { fm.fileExists(atPath: $0.appending(path: "vmlinux").path) }
    }

    /// Opens the store under `home`, loading the bundled `vminit` on first use; no network.
    public static func open(home: URL) async throws -> EmbeddedRuntime {
        guard let assets = locateAssets() else {
            throw APIError(500, "pratico: runtime assets (kernel, vminit) not found; run `make assets`")
        }
        let root = home.appending(path: "store", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let content = try LocalContentStore(path: root.appending(path: "content", directoryHint: .isDirectory))
        let store = try ImageStore(path: root, contentStore: content)
        let reference = try initReference(assets: assets)
        if try await store.getOrNil(reference: reference) == nil {
            _ = try await store.load(from: assets.appending(path: "vminit", directoryHint: .isDirectory))
        }
        try await refreshInitfs(store: store, root: root, reference: reference)
        for img in try await store.list() where isInitImage(img.reference) && img.reference != reference {
            try? await store.delete(reference: img.reference)  // an earlier pratico's init; its blobs go with prune
        }
        let kernel = Kernel(path: assets.appending(path: "vmlinux"), platform: .linuxArm)
        let manager = try await ContainerManager(kernel: kernel, initfsReference: reference, imageStore: store)
        return EmbeddedRuntime(assets: assets, store: store, content: content, manager: manager)
    }

    /// Runs `arguments` in a fresh container from `image` (pulled if missing) and returns
    /// its exit code and combined output. A first end-to-end path; the per-container
    /// shim replaces it.
    public func run(image: String, arguments: [String]) async throws -> (status: Int32, output: Data) {
        let id = "pratico-\(randomHexID().prefix(12))"
        let output = CollectingWriter()
        // ContainerManager is a value type with mutating async methods: work on a copy.
        var m = manager
        let container = try await m.create(id, reference: image, rootfsSizeInBytes: 2.gib(), networking: false) { config in
            config.process.arguments = arguments
            config.process.stdout = output
            config.process.stderr = output
        }
        manager = m
        defer { try? manager.delete(id) }
        try await container.create()
        try await container.start()
        let status = try await container.wait()
        try await container.stop()
        return (status.exitCode, output.data)
    }
}

/// Collects a process's output in memory, keeping at most `limit` bytes (the first ones):
/// the output is the container's, so it must not grow the collector without bound.
final class CollectingWriter: Writer, @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    let limit: Int

    init(limit: Int = Int.max) { self.limit = limit }

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return buffer
    }

    func write(_ data: Data) throws {
        lock.lock()
        let room = limit - buffer.count
        if room > 0 { buffer.append(data.prefix(room)) }
        lock.unlock()
    }

    func close() throws {}
}

/// The daemon's side of embedded containers: root filesystems and shim specs.
final class EmbeddedContainers: Sendable {
    let shim: ShimClient
    let kernel: String
    let initfs: String
    let store: ImageStore
    /// One image unpacked into the cache at a time (the first create of each image).
    private let cacheLock = NSLock()

    init(shim: ShimClient, kernel: String, initfs: String, store: ImageStore) {
        self.shim = shim
        self.kernel = kernel
        self.initfs = initfs
        self.store = store
    }

    /// Opens the runtime under `home`; nil with a reason when it cannot run here.
    static func open(home: URL) -> Result<(EmbeddedContainers, ImageStore, LocalContentStore), APIError> {
        guard let binary = ShimClient.locate() else { return .failure(APIError(500, "pratico-shim not found next to the daemon")) }
        do {
            let rt = try blocking { try await EmbeddedRuntime.open(home: home) }
            let initfs = rt.store.path.appending(path: "initfs.ext4").path
            let kernel = rt.assets.appending(path: "vmlinux").path
            return .success((EmbeddedContainers(shim: ShimClient(binary: binary), kernel: kernel, initfs: initfs, store: rt.store), rt.store, rt.content))
        } catch let e as APIError {
            return .failure(e)
        } catch {
            return .failure(APIError(500, "embedded runtime: \(error)"))
        }
    }

    /// The container's own ext4 root filesystem (sparse, 8 GiB capacity), which keeps its
    /// changes across restarts, as Docker does. Each image is unpacked once into
    /// `rootfsCache`; a container gets an APFS clone of it, which costs no time or space
    /// until the container writes (a copy where cloning is not possible).
    func prepareRootfs(image ref: String, at url: URL) throws {
        let digest = try blocking { [store] in try await store.get(reference: ref).digest }
        let cached = rootfsCache.appending(path: "\(digest.dropFirst(7)).ext4")
        try cacheLock.withLock {
            guard !FileManager.default.fileExists(atPath: cached.path) else { return }
            try FileManager.default.createDirectory(at: rootfsCache, withIntermediateDirectories: true)
            let partial = rootfsCache.appending(path: "\(UUID().uuidString).partial")
            defer { try? FileManager.default.removeItem(at: partial) }
            try blocking { [store] in
                let image = try await store.get(reference: ref)
                // Journaled, as disk volumes are (D-49): a VM killed mid-write leaves a
                // filesystem the guest kernel recovers by replay, not one it fails writes on.
                _ = try await EXT4Unpacker(capacityInBytes: 8.gib(), journal: EXT4.JournalConfig(defaultMode: .ordered))
                    .unpack(image, for: .current, at: partial)
            }
            try FileManager.default.moveItem(at: partial, to: cached)
        }
        if clonefile(cached.path, url.path, 0) != 0 { try FileManager.default.copyItem(at: cached, to: url) }
    }

    /// Unpacked images, one ext4 per image digest (`prepareRootfs`).
    var rootfsCache: URL { store.path.appending(path: "rootfs-cache", directoryHint: .isDirectory) }

    /// Drops the unpacked copy of an image that is gone; with `keeping`, every copy whose
    /// image is not in it (at start, for images removed while the daemon was down).
    func dropRootfsCache(imageId: String) {
        try? FileManager.default.removeItem(at: rootfsCache.appending(path: "\(imageId.dropFirst(7)).ext4"))
    }

    func sweepRootfsCache(keeping imageIds: Set<String>) {
        let keep = Set(imageIds.map { "\($0.dropFirst(7)).ext4" })
        for name in (try? FileManager.default.contentsOfDirectory(atPath: rootfsCache.path)) ?? [] where !keep.contains(name) {
            try? FileManager.default.removeItem(at: rootfsCache.appending(path: name))
        }
    }
}
