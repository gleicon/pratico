import Foundation
import Testing

@testable import PraticoDaemonKit

/// A `struct pratico_event` (vm/bpf/recorder.h) as the guest sends it.
private func record(kind: UInt32, pid: UInt32 = 7, ppid: UInt32 = 1, value: UInt64 = 0, daddr: [UInt8] = [0, 0, 0, 0],
                    sport: UInt16 = 0, dport: UInt16 = 0, comm: String = "sh", file: String = "", args: [String] = []) -> [UInt8] {
    var r = [UInt8](repeating: 0, count: Activity.recordSize)
    func put(_ v: UInt64, _ at: Int, _ n: Int) { for i in 0..<n { r[at + i] = UInt8(truncatingIfNeeded: v >> (8 * i)) } }
    put(UInt64(kind), 0, 4)
    put(UInt64(pid), 4, 4)
    put(UInt64(ppid), 8, 4)
    put(1_700_000_000_000_000_000, 16, 8)
    put(value, 24, 8)
    r.replaceSubrange(32..<36, with: daddr)
    put(UInt64(sport), 36, 2)
    put(UInt64(dport), 38, 2)
    r.replaceSubrange(48..<(48 + comm.utf8.count), with: comm.utf8)
    let fileBytes: [UInt8] = file.isEmpty ? [] : Array(file.utf8) + [0]
    let argBytes: [UInt8] = args.flatMap { Array($0.utf8) + [0] }
    r.replaceSubrange(64..<(64 + fileBytes.count + argBytes.count), with: fileBytes + argBytes)
    put(UInt64(fileBytes.count), 40, 2)
    put(UInt64(argBytes.count), 42, 2)
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
