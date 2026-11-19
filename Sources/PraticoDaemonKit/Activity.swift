import Containerization
import Foundation

/// The flight recorder (D-56): every exec and exit inside a container and the process
/// behind each TCP connection it opens, seen by BPF probes in its VM (`vm/bpf`) and sent
/// by vminitd's Recorder over vsock. The shim keeps them in the container's directory, so
/// they outlive the VM; the daemon serves them.
enum Activity {
    /// vminitd's Recorder.port.
    static let port: UInt32 = 1028
    /// The log's size before it rolls over to `activity.1.jsonl`: at most twice this kept.
    static let maxLogBytes = 8 << 20
    /// Events `GET …/activity` returns at most, the newest.
    static let maxListed = 10_000

    /// `struct pratico_event` (vm/bpf/recorder.h), little-endian: its fields' offsets.
    /// vminitd's Recorder writes `time`, `value`, `fileLength` and `text` at the same ones.
    enum Layout {
        static let kind = 0, pid = 4, ppid = 8, uid = 12, time = 16, value = 24
        static let daddr = 32, sport = 36, dport = 38, fileLength = 40, argsLength = 42
        static let comm = 48, text = 64, size = 384
        static let textCapacity = size - text
    }

    /// `PRATICO_EVENT_*`.
    enum Kind: UInt32 {
        case exec = 1, exit, connect, dropped, unavailable
    }

    /// One record as the API shows it; nil for a kind this pratico does not know.
    static func decode(_ r: [UInt8]) -> JSON? {
        precondition(r.count == Layout.size, "a record of \(r.count) bytes, not \(Layout.size)")
        guard let kind = Kind(rawValue: load(r, Layout.kind, UInt32.self)) else { return nil }
        let value = load(r, Layout.value, UInt64.self)
        var out: [String: JSON] = [
            "Kind": .string("\(kind)"),
            "Time": .string(Timestamp.format(Date(timeIntervalSince1970: Double(load(r, Layout.time, UInt64.self)) / 1e9))),
        ]
        if [.exec, .exit, .connect].contains(kind) {
            out["Pid"] = .int(Int64(load(r, Layout.pid, UInt32.self)))
            out["ParentPid"] = .int(Int64(load(r, Layout.ppid, UInt32.self)))
            out["Uid"] = .int(Int64(load(r, Layout.uid, UInt32.self)))
            out["Command"] = .string(string(r[Layout.comm..<Layout.text]))
        }
        switch kind {
        case .exec:
            let (path, args) = text(r)
            out["Path"] = .string(path)
            out["Args"] = .array(args.map(JSON.string))
        case .exit:
            // A wait status: the low 7 bits are the signal that killed it, else the code.
            let status = Int(value & 0xffff)
            if status & 0x7f == 0 { out["ExitCode"] = .int(Int64(status >> 8)) } else { out["Signal"] = .int(Int64(status & 0x7f)) }
        case .connect:
            out["Proto"] = "tcp"
            out["Address"] = .string(IPv4.format(UInt32(bigEndian: load(r, Layout.daddr, UInt32.self))))
            out["Port"] = .int(Int64(load(r, Layout.dport, UInt16.self)))
            out["SourcePort"] = .int(Int64(load(r, Layout.sport, UInt16.self)))
            out["Connected"] = .bool(value == 1)  // TCP_ESTABLISHED; 7 is TCP_CLOSE
        case .dropped:
            out["Count"] = .int(Int64(clamping: value))
        case .unavailable:
            out["Message"] = .string(text(r).path)
        }
        return .object(out)
    }

    /// `text`: the file (with its NUL) for `file_len` bytes, then argv for `args_len`.
    private static func text(_ r: [UInt8]) -> (path: String, args: [String]) {
        let fileLength = min(Int(load(r, Layout.fileLength, UInt16.self)), Layout.textCapacity)
        let argsLength = min(Int(load(r, Layout.argsLength, UInt16.self)), Layout.textCapacity - fileLength)
        let file = r[Layout.text..<(Layout.text + fileLength)]
        let args = r[(Layout.text + fileLength)..<(Layout.text + fileLength + argsLength)]
        return (string(file), args.split(separator: 0, omittingEmptySubsequences: false).dropLast(args.last == 0 ? 1 : 0).map { String(decoding: $0, as: UTF8.self) })
    }

    private static func string(_ b: ArraySlice<UInt8>) -> String { String(decoding: b.prefix { $0 != 0 }, as: UTF8.self) }
    static func load<T: FixedWidthInteger>(_ r: [UInt8], _ at: Int, _: T.Type) -> T {
        r.withUnsafeBytes { T(littleEndian: $0.loadUnaligned(fromByteOffset: at, as: T.self)) }
    }

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
            var buffer = [UInt8](repeating: 0, count: 64 * Activity.Layout.size)
            // read(2), not FileHandle.read(upToCount:), which waits for the whole count.
            while case let n = read(handle.fileDescriptor, &buffer, buffer.count), n > 0 || (n < 0 && errno == EINTR) {
                guard n > 0 else { continue }
                pending.append(contentsOf: buffer[0..<n])
                let whole = pending.count / Activity.Layout.size * Activity.Layout.size
                for at in stride(from: 0, to: whole, by: Activity.Layout.size) {
                    if let event = Activity.decode(Array(pending[at..<(at + Activity.Layout.size)])) { log.append(event) }
                }
                pending.removeFirst(whole)
            }
        }.start()
    }
}
