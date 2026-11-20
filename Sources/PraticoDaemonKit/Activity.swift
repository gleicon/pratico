import Containerization
import Foundation

/// The flight recorder (D-56): every exec and exit inside a container and the process
/// behind each TCP connection it opens and each UDP destination it sends to, seen by BPF probes in its VM (`vm/bpf`) and sent
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

    /// `PRATICO_EVENT_*`. A UDP record is a `connect` with `Proto` udp, as for TCP.
    enum Kind: UInt32 {
        case exec = 1, exit, connect, dropped, unavailable, udp

        var name: String { self == .udp ? "connect" : "\(self)" }
    }

    /// One record as the API shows it; nil for a kind this pratico does not know.
    static func decode(_ r: [UInt8]) -> JSON? {
        precondition(r.count == Layout.size, "a record of \(r.count) bytes, not \(Layout.size)")
        guard let kind = Kind(rawValue: load(r, Layout.kind, UInt32.self)) else { return nil }
        let value = load(r, Layout.value, UInt64.self)
        var out: [String: JSON] = [
            "Kind": .string(kind.name),
            "Time": .string(Timestamp.format(Date(timeIntervalSince1970: Double(load(r, Layout.time, UInt64.self)) / 1e9))),
        ]
        if [.exec, .exit, .connect, .udp].contains(kind) {
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
        case .connect, .udp:
            out["Proto"] = kind == .udp ? "udp" : "tcp"
            out["Address"] = .string(IPv4.format(UInt32(bigEndian: load(r, Layout.daddr, UInt32.self))))
            out["Port"] = .int(Int64(load(r, Layout.dport, UInt16.self)))
            out["SourcePort"] = .int(Int64(load(r, Layout.sport, UInt16.self)))
            if kind == .connect { out["Connected"] = .bool(value == 1) }  // TCP_ESTABLISHED; 7 is TCP_CLOSE
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

    /// How far apart in time a connect and the switch's flow for it may be: the switch
    /// records an allowed TCP flow at its first bytes, which a server-first protocol delays.
    static let joinWindow: TimeInterval = 600

    /// The recorder's connects and the switch's flows meet on address, port, and source port
    /// (D-57). A connection that never opened has no source port in the guest (the kernel
    /// clears it), so a connect with port 0 meets any flow to that address and port.
    struct ConnectionKey: Hashable {
        var udp: Bool, ip: UInt32, port: UInt16, sourcePort: UInt16

        init?(connect event: JSON) {
            guard event["Kind"]?.string == "connect", let proto = event["Proto"]?.string, let ip = event["Address"]?.string.flatMap(IPv4.parse),
                  let port = event["Port"]?.int, let source = event["SourcePort"]?.int else { return nil }
            (udp, self.ip, self.port, sourcePort) = (proto == "udp", ip, UInt16(clamping: port), UInt16(clamping: source))
        }

        /// A flow's key; nil for ICMP, which has no ports. A DNS flow is UDP.
        init?(flow: EgressGuard.Flow) {
            guard ["tcp", "udp", "dns"].contains(flow.proto) else { return nil }
            (udp, ip, port, sourcePort) = (flow.proto != "tcp", flow.ip, flow.port, flow.sourcePort)
        }

        var anySource: ConnectionKey { var k = self; k.sourcePort = 0; return k }
    }

    /// The candidate nearest `time`, if within `joinWindow`.
    static func nearest<T>(_ candidates: [T], to time: Date, _ timeOf: (T) -> Date) -> T? {
        guard let best = candidates.min(by: { abs(timeOf($0).timeIntervalSince(time)) < abs(timeOf($1).timeIntervalSince(time)) }),
              abs(timeOf(best).timeIntervalSince(time)) <= joinWindow else { return nil }
        return best
    }

    /// Each connect (TCP or UDP) named from the switch's flow for it, nearest in time. `Name`,
    /// `Blocked` and `Reason` are added only where the daemon still holds that flow
    /// (`EgressGuard.maxFlows`, since it started); the guest's own record stays as it was.
    static func join(_ events: [JSON], _ flows: [EgressGuard.Flow]) -> [JSON] {
        precondition(flows.count <= EgressGuard.maxFlows, "\(flows.count) flows, past their bound")
        var byKey: [ConnectionKey: [EgressGuard.Flow]] = [:]
        for flow in flows {
            guard let key = ConnectionKey(flow: flow) else { continue }
            byKey[key, default: []].append(flow)
            byKey[key.anySource, default: []].append(flow)
        }
        let out = events.map { event -> JSON in
            guard let key = ConnectionKey(connect: event), case .object(var fields) = event,
                  let time = event["Time"]?.string.flatMap(Timestamp.parse),
                  let flow = nearest(byKey[key] ?? [], to: time, \.time)
            else { return event }
            fields["Name"] = flow.name.map(JSON.string) ?? .null
            fields["Blocked"] = .bool(flow.blocked)
            fields["Reason"] = flow.reason.map(JSON.string) ?? .null
            return .object(fields)
        }
        assert(out.count == events.count, "the join dropped or added events")
        return out
    }

    /// The other way: the process behind each TCP, UDP or DNS flow, as `(Command, Pid)`
    /// from the recorder's connect for it; nil for ICMP and flows it has no record of.
    static func processes(_ flows: [EgressGuard.Flow], _ events: [JSON]) -> [(command: String, pid: Int64)?] {
        precondition(flows.count <= EgressGuard.maxFlows, "\(flows.count) flows, past their bound")
        var byKey: [ConnectionKey: [(time: Date, command: String, pid: Int64)]] = [:]
        for event in events {
            guard let key = ConnectionKey(connect: event), let time = event["Time"]?.string.flatMap(Timestamp.parse),
                  let command = event["Command"]?.string, let pid = event["Pid"]?.int else { continue }
            byKey[key, default: []].append((time, command, pid))
        }
        let out = flows.map { flow -> (command: String, pid: Int64)? in
            guard let key = ConnectionKey(flow: flow) else { return nil }
            let candidates = (byKey[key] ?? []) + (byKey[key.anySource] ?? [])
            return nearest(candidates, to: flow.time, \.time).map { ($0.command, $0.pid) }
        }
        assert(out.count == flows.count, "a process per flow")
        return out
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

extension ContainerService {
    /// A container's newest `limit` events, oldest first, named from the switch's flows:
    /// what the API and the MCP server return.
    func activity(_ id: String, limit: Int = Activity.maxListed) -> [JSON] {
        Activity.join(Activity.read(shimFiles(id), limit: limit), networks.netSwitch.egress.flows(id))
    }

    /// A container's newest `limit` egress flows, oldest first, each with the process that
    /// opened it where the recorder saw it: what the API, the menubar and MCP list.
    func connections(_ id: String, limit: Int = EgressGuard.maxFlows) -> [JSON] {
        precondition(limit > 0 && limit <= EgressGuard.maxFlows, "limit \(limit) outside 1...\(EgressGuard.maxFlows)")
        let flows = Array(networks.netSwitch.egress.flows(id).suffix(limit))
        let processes = Activity.processes(flows, Activity.read(shimFiles(id)))
        return zip(flows, processes).map { Daemon.flowJSON($0, process: $1) }
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

/// Reads the guest's recorder into the container's activity log until the VM stops.
/// Dialled while the VM boots, before the process runs, so its first exec is seen; the
/// shim waits on it at exit, so a short-lived container's last records are kept.
final class ActivityReader: Sendable {
    /// How long the shim waits for the process's exit record, then for the rest after the
    /// VM stops: the guest's pump wakes on each record, so both come in milliseconds.
    static let drainTimeout: DispatchTimeInterval = .seconds(1)

    private let sawExit = DispatchSemaphore(value: 0)
    private let finished = DispatchSemaphore(value: 0)

    /// Dials the guest's recorder and starts reading; an `unavailable` event if it does not answer.
    static func start(_ container: LinuxContainer, _ files: ShimFiles) async -> ActivityReader {
        let reader = ActivityReader()
        guard let handle = try? await container.withVirtualMachineInstance({ try await $0.dial(Activity.port) }) else {
            ActivityLog(files).append(["Time": .string(Timestamp.format(Date())), "Kind": "unavailable", "Message": "the VM's recorder did not answer"])
            reader.sawExit.signal()
            reader.finished.signal()
            return reader
        }
        Thread {
            reader.copy(handle, into: ActivityLog(files))
            try? handle.close()
            reader.finished.signal()
        }.start()
        return reader
    }

    private func copy(_ handle: FileHandle, into log: ActivityLog) {
        var pending: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 64 * Activity.Layout.size)
        var exited = false
        // read(2), not FileHandle.read(upToCount:), which waits for the whole count.
        while case let n = read(handle.fileDescriptor, &buffer, buffer.count), n > 0 || (n < 0 && errno == EINTR) {
            guard n > 0 else { continue }
            pending.append(contentsOf: buffer[0..<n])
            let whole = pending.count / Activity.Layout.size * Activity.Layout.size
            for at in stride(from: 0, to: whole, by: Activity.Layout.size) {
                guard let event = Activity.decode(Array(pending[at..<(at + Activity.Layout.size)])) else { continue }
                log.append(event)
                // The container's first process is pid 1 in its namespace: its exit is the last record that matters.
                if !exited, event["Kind"]?.string == "exit", event["Pid"]?.int == 1 {
                    exited = true
                    sawExit.signal()
                }
            }
            pending.removeFirst(whole)
            assert(pending.count < Activity.Layout.size, "a whole record left unread")
        }
    }

    /// After the process exits, before the VM stops: its exit record, or the timeout.
    func awaitExitRecord() async { await Self.wait(sawExit) }

    /// After the VM stops: the reader at the end of the guest's stream, or the timeout.
    func awaitFinish() async { await Self.wait(finished) }

    private static func wait(_ s: DispatchSemaphore) async {
        await withCheckedContinuation { done in
            DispatchQueue.global().async {
                if s.wait(timeout: .now() + drainTimeout) == .success { s.signal() }  // later waits see it too
                done.resume()
            }
        }
    }
}
