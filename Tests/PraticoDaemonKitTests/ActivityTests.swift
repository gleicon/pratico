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
