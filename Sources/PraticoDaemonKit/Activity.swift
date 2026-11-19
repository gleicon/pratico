import Containerization
import Foundation

/// The flight recorder (D-56): every exec and exit inside a container and the process
/// behind each TCP connection it opens, seen by BPF probes in its VM (`vm/bpf`) and sent
/// by vminitd's Recorder over vsock. The shim keeps them in the container's directory, so
/// they outlive the VM; the daemon serves them.
enum Activity {
    /// vminitd's Recorder.port.
    static let port: UInt32 = 1028
    /// `struct pratico_event` (vm/bpf/recorder.h).
    static let recordSize = 384
    /// The log's size before it rolls over to `activity.1.jsonl`: at most twice this kept.
    static let maxLogBytes = 8 << 20
    /// Events `GET …/activity` returns at most, the newest.
    static let maxListed = 10_000

    /// One record as the API shows it; nil for a kind this pratico does not know.
    static func decode(_ r: [UInt8]) -> JSON? {
        precondition(r.count == recordSize, "a record of \(r.count) bytes, not \(recordSize)")
        let kind = u32(r, 0)
        let time = Date(timeIntervalSince1970: Double(u64(r, 16)) / 1e9)
        var out: [String: JSON] = ["Time": .string(Timestamp.format(time))]
        let value = u64(r, 24)
        switch kind {
        case 1, 2, 3:
            out["Pid"] = .int(Int64(u32(r, 4)))
            out["ParentPid"] = .int(Int64(u32(r, 8)))
            out["Uid"] = .int(Int64(u32(r, 12)))
            out["Command"] = .string(string(r[48..<64]))
        default:
            break
        }
        switch kind {
        case 1:
            out["Kind"] = "exec"
            let (path, args) = text(r)
            out["Path"] = .string(path)
            out["Args"] = .array(args.map(JSON.string))
        case 2:
            out["Kind"] = "exit"
            let status = Int(value & 0xffff)
            // A wait status: the low 7 bits are the signal that killed it, else the code.
            if status & 0x7f == 0 { out["ExitCode"] = .int(Int64(status >> 8)) } else { out["Signal"] = .int(Int64(status & 0x7f)) }
        case 3:
            out["Kind"] = "connect"
            out["Proto"] = "tcp"
            out["Address"] = .string(IPv4.format(UInt32(bigEndian: u32(r, 32))))
            out["Port"] = .int(Int64(u16(r, 38)))
            out["SourcePort"] = .int(Int64(u16(r, 36)))
            out["Connected"] = .bool(value == 1)  // TCP_ESTABLISHED; 7 is TCP_CLOSE
        case 4:
            out["Kind"] = "dropped"
            out["Count"] = .int(Int64(clamping: value))
        case 5:
            out["Kind"] = "unavailable"
            out["Message"] = .string(text(r).path)
        default:
            return nil
        }
        return .object(out)
    }

    /// `text`: the file (with its NUL) for `file_len` bytes, then argv for `args_len`.
    private static func text(_ r: [UInt8]) -> (path: String, args: [String]) {
        let fileLength = min(Int(u16(r, 40)), 320), argsLength = min(Int(u16(r, 42)), 320 - fileLength)
        let file = r[64..<(64 + fileLength)]
        let args = r[(64 + fileLength)..<(64 + fileLength + argsLength)]
        return (string(file), args.split(separator: 0, omittingEmptySubsequences: false).dropLast(args.last == 0 ? 1 : 0).map { String(decoding: $0, as: UTF8.self) })
    }

    private static func string(_ b: ArraySlice<UInt8>) -> String { String(decoding: b.prefix { $0 != 0 }, as: UTF8.self) }
    private static func u16(_ b: [UInt8], _ at: Int) -> UInt16 { UInt16(b[at]) | UInt16(b[at + 1]) << 8 }
    private static func u32(_ b: [UInt8], _ at: Int) -> UInt32 { (0..<4).reduce(0) { $0 | UInt32(b[at + $1]) << (8 * $1) } }
    private static func u64(_ b: [UInt8], _ at: Int) -> UInt64 { (0..<8).reduce(0) { $0 | UInt64(b[at + $1]) << (8 * $1) } }

    /// The container's events, oldest first: the rolled-over log, then the current one.
    static func read(_ files: ShimFiles, limit: Int = maxListed) -> [JSON] {
        precondition(limit > 0 && limit <= maxListed, "limit \(limit) outside 1...\(maxListed)")
        var out: [JSON] = []
        for url in [files.activityPrevious, files.activity] {
            guard let data = try? Data(contentsOf: url) else { continue }
            for line in data.split(separator: UInt8(ascii: "\n")) { if let j = JSON.parse(Data(line)) { out.append(j) } }
        }
        return Array(out.suffix(limit))
    }
}

/// Appends the recorder's events to `activity.jsonl`, rolling it over to
/// `activity.1.jsonl` past `Activity.maxLogBytes`. One writer: the shim's reader thread.
final class ActivityLog {
    private let files: ShimFiles
    private var handle: FileHandle?
    private var size = 0

    init(_ files: ShimFiles) {
        self.files = files
        size = (try? FileManager.default.attributesOfItem(atPath: files.activity.path)[.size] as? Int) ?? 0
    }

    deinit { try? handle?.close() }

    func append(_ event: JSON) {
        var line = event.encoded()
        line.append(UInt8(ascii: "\n"))
        if size + line.count > Activity.maxLogBytes { rollOver() }
        if handle == nil {
            if !FileManager.default.fileExists(atPath: files.activity.path) { FileManager.default.createFile(atPath: files.activity.path, contents: nil) }
            handle = try? FileHandle(forWritingTo: files.activity)
            _ = try? handle?.seekToEnd()
        }
        guard let handle, (try? handle.write(contentsOf: line)) != nil else { return }
        size += line.count
        assert(size <= Activity.maxLogBytes, "the log grew past its bound")
    }

    private func rollOver() {
        try? handle?.close()
        handle = nil
        _ = try? FileManager.default.replaceItemAt(files.activityPrevious, withItemAt: files.activity)
        size = 0
    }
}

extension ShimHost {
    /// Reads the guest's recorder until the VM stops, into the container's activity log.
    /// Started after the VM boots and before the process runs, so its first exec is seen.
    static func recordActivity(_ container: LinuxContainer, _ files: ShimFiles) {
        Thread {
            let log = ActivityLog(files)
            guard let handle = try? blocking({ try await container.withVirtualMachineInstance { try await $0.dial(Activity.port) } }) else {
                log.append(["Time": .string(Timestamp.format(Date())), "Kind": "unavailable", "Message": "the VM's recorder did not answer"])
                return
            }
            defer { try? handle.close() }
            var pending: [UInt8] = []
            var buffer = [UInt8](repeating: 0, count: 64 * Activity.recordSize)
            // read(2), not FileHandle.read(upToCount:), which waits for the whole count.
            while case let n = read(handle.fileDescriptor, &buffer, buffer.count), n > 0 || (n < 0 && errno == EINTR) {
                guard n > 0 else { continue }
                pending.append(contentsOf: buffer[0..<n])
                let whole = pending.count / Activity.recordSize * Activity.recordSize
                for at in stride(from: 0, to: whole, by: Activity.recordSize) {
                    if let event = Activity.decode(Array(pending[at..<(at + Activity.recordSize)])) { log.append(event) }
                }
                pending.removeFirst(whole)
            }
        }.start()
    }
}
