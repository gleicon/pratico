import Containerization
import ContainerizationOCI
import ContainerizationExtras
import ContainerizationOS
import Foundation

/// `docker exec` and healthchecks in the shim: one-shot runs, streamed sessions, their table.
extension ShimControl {
    /// One-shot exec with captured output, for healthchecks and `docker top`:
    /// `{"args": [...], "timeout": seconds, "limit": bytes}` → `{"exitCode", "output"}`;
    /// -1 on timeout.
    func run(_ body: JSON) throws -> JSON {
        let args = body["args"]?.strings ?? []
        guard !args.isEmpty else { throw APIError(400, "shim: exec needs args") }
        let timeout = Int64(body["timeout"]?.int ?? 30)
        let c = container
        let spec = spec
        // Docker keeps 4 KiB of probe output; `docker top` asks for more, up to 1 MiB.
        let limit = Int(body["limit"]?.int ?? 4096)
        guard (1...(1 << 20)).contains(limit) else { throw APIError(400, "shim: exec output limit \(limit) out of range") }
        let output = CollectingWriter(limit: limit)
        let id = "exec-\(randomHexID().prefix(12))"
        let code: Int32 = try blocking {
            let p = try await c.exec(id) { cfg in
                cfg.arguments = args
                cfg.environmentVariables = spec.environment
                cfg.workingDirectory = spec.workingDirectory.isEmpty ? "/" : spec.workingDirectory
                cfg.user = ShimHost.user(spec.user)
                try ShimHost.secure(&cfg, spec.options, privileged: false)
                cfg.stdout = output
                cfg.stderr = output
            }
            try await p.start()
            defer { Task { try? await p.delete() } }
            do {
                return try await p.wait(timeoutInSeconds: timeout).exitCode
            } catch {
                try? await p.kill(Signal(rawValue: 9))
                return -1
            }
        }
        let text = code == -1 ? "Health check exceeded timeout (\(timeout)s)" : String(decoding: output.data, as: UTF8.self)
        return ["exitCode": .int(Int64(code)), "output": .string(text)]
    }
}

/// Running and finished execs, by Docker exec ID.
final class ExecTable: @unchecked Sendable {
    struct Entry {
        var process: LinuxProcess?
        var exitCode: Int32?
    }
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    func get(_ id: String) -> Entry? {
        lock.lock()
        defer { lock.unlock() }
        return entries[id]
    }

    func set(_ id: String, _ change: (inout Entry) -> Void) {
        lock.lock()
        var e = entries[id] ?? Entry()
        change(&e)
        entries[id] = e
        lock.unlock()
    }
}

/// Exec output straight onto a hijacked connection, framed as Docker frames it.
struct ConnWriter: Writer {
    let conn: Connection
    let stream: UInt8
    let raw: Bool
    func write(_ data: Data) throws { _ = conn.write(raw ? data : StdCopy.frame(stream: stream, data)) }
    func close() throws {}
}

/// Discards output a client did not attach to.
struct NullWriter: Writer {
    func write(_ data: Data) throws {}
    func close() throws {}
}

extension ShimControl {
    /// `docker exec` streamed: `{"id", "args", "env", "workdir", "user", "tty", "stdin",
    /// "stdout", "stderr", "height", "width"}`. The connection carries Docker's raw (TTY)
    /// or multiplexed stream, takes stdin until the client half-closes, and closes when the
    /// process exits; its code is then at `/exec-status`.
    func stream(_ body: JSON, _ conn: Connection) throws {
        guard let id = body["id"]?.string, let args = body["args"]?.strings, !args.isEmpty else {
            throw APIError(400, "shim: exec needs id and args")
        }
        let tty = body["tty"]?.bool ?? false
        let wantStdout = body["stdout"]?.bool ?? true
        let wantStderr = body["stderr"]?.bool ?? true
        let input = (body["stdin"]?.bool ?? false) ? StdinStream() : nil
        let env = spec.environment + (body["env"]?.strings ?? [])
        let workdir = body["workdir"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? (spec.workingDirectory.isEmpty ? "/" : spec.workingDirectory)
        let user = body["user"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? spec.user
        let privileged = body["privileged"]?.bool ?? false
        let options = spec.options
        let c = container
        let process = try blocking {
            try await c.exec(id) { cfg in
                cfg.arguments = args
                cfg.environmentVariables = env
                cfg.workingDirectory = workdir
                cfg.user = ShimHost.user(user)
                try ShimHost.secure(&cfg, options, privileged: privileged)
                cfg.terminal = tty
                cfg.stdin = input
                let out: any Writer = wantStdout ? ConnWriter(conn: conn, stream: 1, raw: tty) : NullWriter()
                let err: any Writer = wantStderr ? ConnWriter(conn: conn, stream: 2, raw: false) : NullWriter()
                cfg.stdout = out
                cfg.stderr = tty ? nil : err
            }
        }
        conn.hijack(contentType: tty ? "application/vnd.docker.raw-stream" : "application/vnd.docker.multiplexed-stream")
        execs.set(id) { $0.process = process }
        do {
            try blocking { try await process.start() }
        } catch {
            // The stream is already switched: report in it, with Docker's code for a
            // command that cannot run.
            let missing = "\(error)".contains("failed to find target executable")
            let detail = missing ? "exec: \"\(args[0])\": executable file not found in $PATH" : "\(error)"
            let msg = Data("OCI runtime exec failed: exec failed: unable to start container process: \(detail): unknown\n".utf8)
            _ = conn.write(tty ? msg : StdCopy.frame(stream: 2, msg))
            execs.set(id) {
                $0.exitCode = 127
                $0.process = nil
            }
            try? blocking { try await process.delete() }
            conn.close()
            return
        }
        if tty, let h = body["height"]?.int, let w = body["width"]?.int, h > 0, w > 0 {
            try? blocking { try await process.resize(to: Terminal.Size(width: UInt16(clamping: w), height: UInt16(clamping: h))) }
        }
        if let input {
            Thread.detachNewThread {
                while let data = conn.readRaw() { input.feed(data) }
                input.finish()
            }
        }
        let execs = execs
        Thread.detachNewThread {
            let code = (try? blocking { try await process.wait().exitCode }) ?? 137
            try? blocking { try await process.delete() }
            execs.set(id) {
                $0.exitCode = code
                $0.process = nil
            }
            conn.close()
        }
    }
}

