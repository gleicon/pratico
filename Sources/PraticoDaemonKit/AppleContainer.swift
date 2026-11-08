import Foundation

public struct ProcessResult: Sendable {
    public var status: Int32
    public var stdout: Data
    public var stderr: Data

    public var ok: Bool { status == 0 }
    public var errorText: String {
        let text = String(decoding: stderr.isEmpty ? stdout : stderr, as: UTF8.self)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Adapter over Apple's `container` CLI, the runtime every Docker container maps onto.
/// The Apple-signed `container` services own virtualization and networking, so pratico
/// needs no restricted entitlements (SPEC D-11).
public final class AppleContainer: Sendable {
    public let binary: String

    public init(binary: String? = nil) {
        let candidates = [binary, ProcessInfo.processInfo.environment["PRATICO_CONTAINER_BIN"],
                          "/usr/local/bin/container", "/opt/homebrew/bin/container"]
        self.binary = candidates.compactMap { $0 }.first { FileManager.default.isExecutableFile(atPath: $0) }
            ?? "/usr/local/bin/container"
    }

    public var isInstalled: Bool { FileManager.default.isExecutableFile(atPath: binary) }

    public func process(_ args: [String]) -> Process {
        let p = Process()
        p.executableURL = URL(filePath: binary)
        p.arguments = args
        p.standardInput = FileHandle.nullDevice
        return p
    }

    /// Runs `container <args>` to completion, collecting both streams; `input` feeds stdin.
    public func run(_ args: [String], input: Data? = nil) -> ProcessResult {
        let p = process(args)
        let out = Pipe()
        let err = Pipe()
        let inPipe = input.map { _ in Pipe() }
        if let inPipe { p.standardInput = inPipe }
        p.standardOutput = out
        p.standardError = err
        do { try p.run() } catch {
            return ProcessResult(status: 127, stdout: Data(), stderr: Data("\(error)".utf8))
        }
        if let inPipe, let input {
            DispatchQueue.global().async {
                try? inPipe.fileHandleForWriting.write(contentsOf: input)
                try? inPipe.fileHandleForWriting.close()
            }
        }
        let errData = Box<Data>(Data())
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            errData.value = err.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        p.waitUntilExit()
        return ProcessResult(status: p.terminationStatus, stdout: outData, stderr: errData.value)
    }

    public func runJSON(_ args: [String]) -> JSON? {
        let r = run(args)
        return r.ok ? JSON.parse(r.stdout) : nil
    }

    public var serviceRunning: Bool {
        let r = run(["system", "status"])
        return r.ok && String(decoding: r.stdout, as: UTF8.self).contains("running")
    }

    // MARK: Images

    public func images() -> [JSON] { runJSON(["image", "list", "--format", "json"])?.array ?? [] }

    public func image(_ ref: String) -> JSON? { runJSON(["image", "inspect", ref])?.array?.first }

    // MARK: Containers

    public func containers() -> [JSON] { runJSON(["list", "--all", "--format", "json"])?.array ?? [] }

    public func container(_ id: String) -> JSON? { runJSON(["inspect", id])?.array?.first }

    public func state(_ id: String) -> String? { container(id)?["status"]?["state"]?.string }
}

/// Mutable cell for handing values back from a background closure.
final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}
