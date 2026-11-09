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

/// Collects a process's output in memory.
final class CollectingWriter: Writer, @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return buffer
    }

    func write(_ data: Data) throws {
        lock.lock()
        buffer.append(data)
        lock.unlock()
    }

    func close() throws {}
}
