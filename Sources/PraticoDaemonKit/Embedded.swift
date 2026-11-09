import Containerization
import ContainerizationOCI
import Foundation

/// The embedded runtime (docs/design/runtime.md): one VM per container through
/// apple/containerization, with the kernel and `vminit` shipped inside pratico, so no
/// other software is needed. Images live in pratico's own store, `~/.pratico/store`.
public actor EmbeddedRuntime {
    /// The bundled init image, pinned in scripts/fetch-runtime-assets.sh.
    public static let initReference = "ghcr.io/apple/containerization/vminit:0.54.0"

    public let assets: URL
    public let store: ImageStore
    private var manager: ContainerManager

    private init(assets: URL, store: ImageStore, manager: ContainerManager) {
        self.assets = assets
        self.store = store
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
        let store = try ImageStore(path: home.appending(path: "store", directoryHint: .isDirectory))
        if try await store.getOrNil(reference: initReference) == nil {
            _ = try await store.load(from: assets.appending(path: "vminit", directoryHint: .isDirectory))
        }
        let kernel = Kernel(path: assets.appending(path: "vmlinux"), platform: .linuxArm)
        let manager = try await ContainerManager(kernel: kernel, initfsReference: initReference, imageStore: store)
        return EmbeddedRuntime(assets: assets, store: store, manager: manager)
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

    init(shim: ShimClient, kernel: String, initfs: String, store: ImageStore) {
        self.shim = shim
        self.kernel = kernel
        self.initfs = initfs
        self.store = store
    }

    /// Opens the runtime under `home`; nil with a reason when it cannot run here.
    static func open(home: URL) -> Result<(EmbeddedContainers, ImageStore), APIError> {
        guard let binary = ShimClient.locate() else { return .failure(APIError(500, "pratico-shim not found next to the daemon")) }
        do {
            let rt = try blocking { try await EmbeddedRuntime.open(home: home) }
            let initfs = rt.store.path.appending(path: "initfs.ext4").path
            let kernel = rt.assets.appending(path: "vmlinux").path
            return .success((EmbeddedContainers(shim: ShimClient(binary: binary), kernel: kernel, initfs: initfs, store: rt.store), rt.store))
        } catch let e as APIError {
            return .failure(e)
        } catch {
            return .failure(APIError(500, "embedded runtime: \(error)"))
        }
    }

    /// Unpacks the image into the container's own ext4 root filesystem (sparse, 8 GiB
    /// capacity). Done once at create; the file keeps the container's changes across
    /// restarts, as Docker does.
    func prepareRootfs(image ref: String, at url: URL) throws {
        try blocking { [store] in
            let image = try await store.get(reference: ref)
            _ = try await EXT4Unpacker(capacityInBytes: 8.gib()).unpack(image, for: .current, at: url)
        }
    }
}
