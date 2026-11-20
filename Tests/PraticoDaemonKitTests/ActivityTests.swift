import Foundation
import Testing

@testable import PraticoDaemonKit

/// A `struct pratico_event` (vm/bpf/recorder.h) as the guest sends it.
private func record(kind: UInt32, pid: UInt32 = 7, ppid: UInt32 = 1, value: UInt64 = 0, daddr: [UInt8] = [0, 0, 0, 0],
                    sport: UInt16 = 0, dport: UInt16 = 0, comm: String = "sh", file: String = "", args: [String] = []) -> [UInt8] {
    typealias L = Activity.Layout
    var r = [UInt8](repeating: 0, count: L.size)
    let fileBytes: [UInt8] = file.isEmpty ? [] : Array(file.utf8) + [0]
    let argBytes: [UInt8] = args.flatMap { Array($0.utf8) + [0] }
    r.withUnsafeMutableBytes { b in
        b.storeBytes(of: kind.littleEndian, toByteOffset: L.kind, as: UInt32.self)
        b.storeBytes(of: pid.littleEndian, toByteOffset: L.pid, as: UInt32.self)
        b.storeBytes(of: ppid.littleEndian, toByteOffset: L.ppid, as: UInt32.self)
        b.storeBytes(of: UInt64(1_700_000_000_000_000_000).littleEndian, toByteOffset: L.time, as: UInt64.self)
        b.storeBytes(of: value.littleEndian, toByteOffset: L.value, as: UInt64.self)
        b.storeBytes(of: sport.littleEndian, toByteOffset: L.sport, as: UInt16.self)
        b.storeBytes(of: dport.littleEndian, toByteOffset: L.dport, as: UInt16.self)
        b.storeBytes(of: UInt16(fileBytes.count).littleEndian, toByteOffset: L.fileLength, as: UInt16.self)
        b.storeBytes(of: UInt16(argBytes.count).littleEndian, toByteOffset: L.argsLength, as: UInt16.self)
    }
    r.replaceSubrange(L.daddr..<(L.daddr + 4), with: daddr)
    r.replaceSubrange(L.comm..<(L.comm + comm.utf8.count), with: comm.utf8)
    r.replaceSubrange(L.text..<(L.text + fileBytes.count + argBytes.count), with: fileBytes + argBytes)
    return r
}

@Test func activityReadsAnExec() throws {
    let e = try #require(Activity.decode(record(kind: 1, comm: "ls", file: "/bin/ls", args: ["ls", "-l", ""])))
    #expect(e["Kind"]?.string == "exec" && e["Pid"]?.int == 7 && e["ParentPid"]?.int == 1 && e["Command"]?.string == "ls")
    #expect(e["Path"]?.string == "/bin/ls" && e["Args"]?.strings == ["ls", "-l", ""])  // an empty argument is kept
    #expect(e["Time"]?.string?.hasPrefix("2023-11-14T22:13:20") == true)
}

@Test func activityReadsExitStatuses() throws {
    #expect(Activity.decode(record(kind: 2, value: 3 << 8))?["ExitCode"]?.int == 3)
    let killed = try #require(Activity.decode(record(kind: 2, value: 9)))
    #expect(killed["Signal"]?.int == 9 && killed["ExitCode"] == nil)
}

@Test func activityReadsAConnection() throws {
    let e = try #require(Activity.decode(record(kind: 3, value: 1, daddr: [1, 1, 1, 1], sport: 40_000, dport: 443)))
    #expect(e["Kind"]?.string == "connect" && e["Address"]?.string == "1.1.1.1" && e["Port"]?.int == 443)
    #expect(e["SourcePort"]?.int == 40_000 && e["Connected"]?.bool == true)
    #expect(Activity.decode(record(kind: 3, value: 7))?["Connected"]?.bool == false)
}

@Test func activityReadsTheRecordersOwnRecords() throws {
    #expect(Activity.decode(record(kind: 4, value: 12))?["Count"]?.int == 12)
    #expect(Activity.decode(record(kind: 5, file: "no ring buffer"))?["Message"]?.string == "no ring buffer")
    #expect(Activity.decode(record(kind: 99)) == nil)
}

@Test func activityLogRollsOverAndReadsBothFiles() throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: "activity-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let files = ShimFiles(dir: dir)
    let log = ActivityLog(files)
    let event: JSON = ["Kind": "exec", "Path": .string(String(repeating: "x", count: 1000))]
    let perLine = event.encoded().count + 1
    let lines = Activity.maxLogBytes / perLine + 10
    for _ in 0..<lines { log.append(event) }
    #expect(FileManager.default.fileExists(atPath: files.activityPrevious.path))
    #expect(Activity.read(files).count == lines)
    #expect(Activity.read(files, limit: 5).count == 5)
}

@Test func activityJoinsConnectionsWithTheSwitchsFlows() throws {
    let connect = try #require(Activity.decode(record(kind: 3, value: 7, daddr: [1, 2, 3, 4], sport: 40_000, dport: 443)))
    let exec = try #require(Activity.decode(record(kind: 1, file: "/bin/ls")))
    let at = try #require(connect["Time"]?.string.flatMap(Timestamp.parse))
    let ip = try #require(IPv4.parse("1.2.3.4"))
    func flow(_ offset: TimeInterval, sourcePort: UInt16 = 40_000, proto: String = "tcp", name: String, blocked: Bool = false) -> EgressGuard.Flow {
        .init(time: at.addingTimeInterval(offset), proto: proto, ip: ip, port: 443, sourcePort: sourcePort, name: name, blocked: blocked, reason: blocked ? "listed" : nil)
    }
    let flows = [flow(-300, name: "older.example"), flow(1, name: "bad.example", blocked: true), flow(0, sourcePort: 40_001, name: "other.example"),
                 flow(0, proto: "udp", name: "udp.example")]
    let joined = Activity.join([exec, connect], flows)
    #expect(joined[0] == exec)  // only connections are named
    #expect(joined[1]["Name"]?.string == "bad.example" && joined[1]["Blocked"]?.bool == true && joined[1]["Reason"]?.string == "listed")
    #expect(joined[1]["Address"]?.string == "1.2.3.4" && joined[1]["Connected"]?.bool == false)  // the guest's record kept
    // Refused before it opened: no source port in the guest, matched on address and port.
    let refused = try #require(Activity.decode(record(kind: 3, value: 7, daddr: [1, 2, 3, 4], dport: 443)))
    let refusedFlows = [flow(-300, name: "older.example"), flow(2, sourcePort: 50_000, name: "refused.example", blocked: true)]
    #expect(Activity.join([refused], refusedFlows)[0]["Name"]?.string == "refused.example")
    // No flow for it, or none near enough in time: left as the guest recorded it.
    #expect(Activity.join([connect], []) == [connect])
    #expect(Activity.join([connect], [flow(-Activity.joinWindow - 1, name: "stale.example")]) == [connect])
}

@Test func activityNamesTheProcessBehindEachFlow() throws {
    let open = try #require(Activity.decode(record(kind: 3, pid: 9, value: 1, daddr: [1, 2, 3, 4], sport: 40_000, dport: 443, comm: "curl")))
    let refused = try #require(Activity.decode(record(kind: 3, pid: 11, value: 7, daddr: [5, 6, 7, 8], dport: 80, comm: "wget")))
    let at = try #require(open["Time"]?.string.flatMap(Timestamp.parse))
    func flow(_ ip: String, _ port: UInt16, _ source: UInt16, proto: String = "tcp") throws -> EgressGuard.Flow {
        .init(time: at.addingTimeInterval(1), proto: proto, ip: try #require(IPv4.parse(ip)), port: port, sourcePort: source, name: nil, blocked: false, reason: nil)
    }
    let flows = [try flow("1.2.3.4", 443, 40_000), try flow("5.6.7.8", 80, 50_000), try flow("1.2.3.4", 443, 40_001), try flow("9.9.9.9", 53, 40_000, proto: "udp")]
    let found = Activity.processes(flows, [open, refused])
    #expect(found.map { $0?.command } == ["curl", "wget", nil, nil])  // exact, port-less refused, other port, not TCP
    #expect(found[0]?.pid == 9 && found[1]?.pid == 11)
}

@Test func activityReadsAUDPDestinationAndJoinsIt() throws {
    let e = try #require(Activity.decode(record(kind: 6, daddr: [172, 17, 0, 1], sport: 51_000, dport: 53, comm: "nslookup")))
    #expect(e["Kind"]?.string == "connect" && e["Proto"]?.string == "udp" && e["Port"]?.int == 53 && e["SourcePort"]?.int == 51_000)
    #expect(e["Connected"] == nil && e["Command"]?.string == "nslookup")
    let at = try #require(e["Time"]?.string.flatMap(Timestamp.parse))
    let gateway = try #require(IPv4.parse("172.17.0.1"))
    let dns = EgressGuard.Flow(time: at, proto: "dns", ip: gateway, port: 53, sourcePort: 51_000, name: "bad.example", blocked: true, reason: "listed")
    let tcp = EgressGuard.Flow(time: at, proto: "tcp", ip: gateway, port: 53, sourcePort: 51_000, name: "tcp.example", blocked: false, reason: nil)
    #expect(Activity.join([e], [tcp, dns])[0]["Name"]?.string == "bad.example")  // a UDP record meets UDP and DNS flows only
    #expect(Activity.processes([dns, tcp], [e]).map { $0?.command } == ["nslookup", nil])
}
