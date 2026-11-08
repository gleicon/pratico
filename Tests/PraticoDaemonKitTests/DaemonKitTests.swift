import Foundation
import Testing

@testable import PraticoDaemonKit

@Test(arguments: [
    ("alpine", "docker.io/library/alpine:latest"),
    ("alpine:3.20", "docker.io/library/alpine:3.20"),
    ("me/a:1", "docker.io/me/a:1"),
    ("localhost:5000/a:1", "localhost:5000/a:1"),
    ("localhost:5000/a", "localhost:5000/a:latest"),
    ("ghcr.io/o/r", "ghcr.io/o/r:latest"),
    ("alpine@sha256:abc", "docker.io/library/alpine@sha256:abc"),
])
func normalizesImageRefs(input: String, expected: String) {
    #expect(ImageRef.normalize(input) == expected)
}

@Test func familiarStripsDockerHub() {
    #expect(ImageRef.familiar("docker.io/library/alpine:latest") == "alpine:latest")
    #expect(ImageRef.familiar("docker.io/me/a:1") == "me/a:1")
    #expect(ImageRef.familiar("localhost:5000/a:1") == "localhost:5000/a:1")
}

@Test func stripsAPIVersionPrefix() {
    #expect(Connection.stripVersion("/v1.55/containers/json") == "/containers/json")
    #expect(Connection.stripVersion("/_ping") == "/_ping")
    #expect(Connection.stripVersion("/volumes/v1") == "/volumes/v1")
}

@Test func parsesQueryEncoding() {
    let q = Connection.parseQuery("filters=%7B%22label%22%3A%5B%22a%3D1%22%5D%7D&all=1&x=a+b")
    #expect(q["all"] == "1")
    #expect(q["x"] == "a b")
    #expect(ContainerService.parseFilters(q["filters"]) == ["label": ["a=1"]])
}

@Test func filtersAcceptMapForm() {
    #expect(ContainerService.parseFilters(#"{"label":{"a=1":true}}"#) == ["label": ["a=1"]])
}

@Test func portBindingsDefaultToAllInterfaces() {
    let b: JSON = ["80/tcp": [["HostIp": "", "HostPort": "8080"]], "53/udp": [["HostIp": "127.0.0.1", "HostPort": "5353"]]]
    #expect(ContainerService.publishSpecs(b) == ["127.0.0.1:5353:53/udp", "0.0.0.0:8080:80/tcp"])
}

@Test func stdcopyFrameHeader() {
    let f = StdCopy.frame(stream: 2, Data("hi".utf8))
    #expect(Array(f) == [2, 0, 0, 0, 0, 0, 0, 2, 0x68, 0x69])
}

@Test func bindsAreReadWriteUnlessRo() throws {
    let host: JSON = ["Binds": ["/tmp/a:/a", "/tmp/b:/b:ro,z", "/tmp/c:/c:rw"]]
    let m = try ContainerService.mounts(host)
    #expect(m.map(\.readOnly) == [false, true, false])
    #expect(m.allSatisfy { $0.createSource })
}

@Test func namedVolumesAndBadSpecsRejected() {
    #expect(throws: APIError.self) { try ContainerService.mounts(["Binds": ["data:/data"]]) }
    #expect(throws: APIError.self) { try ContainerService.mounts(["Binds": ["/tmp:relative"]]) }
    #expect(throws: APIError.self) { try ContainerService.mounts(["Mounts": [["Type": "volume", "Target": "/v"]]]) }
}

@Test func mountFlagNeedsExistingSource() {
    let missing: JSON = ["Mounts": [["Type": "bind", "Source": "/nonexistent-pratico", "Target": "/x"]]]
    #expect(throws: APIError.self) { try ContainerService.mounts(missing) }
}

@Test func logStoreStaysUnderCapAndKeepsNewest() throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: "pratico-log-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = LogStore(path: dir.appending(path: "log"), maxBytes: 64 * 1024)
    for i in 0..<10_000 { store.append(stream: 1, Data("line \(i)\n".utf8)) }
    #expect(store.diskBytes <= 64 * 1024)
    let lines = store.read()
    #expect(String(decoding: lines.last!.data, as: UTF8.self) == "line 9999\n")
    #expect(lines.count < 10_000)
}

@Test func unixModeMapsToGoFileMode() {
    #expect(ArchiveService.goFileMode(0o100644) == 0o644)
    #expect(ArchiveService.goFileMode(0o040755) == (1 << 31) | 0o755)
    #expect(ArchiveService.goFileMode(0o120777) == (1 << 27) | 0o777)
    #expect(ArchiveService.goFileMode(0o104755) == (1 << 23) | 0o755)
}

@Test func statsCPUDeltaGivesDockerPercent() throws {
    let rec = ContainerRecord(id: "abc", name: "t1", appleId: "abc", image: "alpine", imageId: "sha256:x",
                              created: Date(), path: "sh", args: [], config: [:], hostConfig: [:])
    let t = Date()
    let pre = StatsService.Sample(time: t, raw: ["cpuUsageUsec": 1_000_000])
    let now = StatsService.Sample(time: t.addingTimeInterval(2), raw: ["cpuUsageUsec": 3_000_000])
    let j = StatsService.encode(rec, cpus: 64, now: now, pre: pre)  // many CPUs must not overflow
    let cpu = Double(j["cpu_stats"]!["cpu_usage"]!["total_usage"]!.int! - j["precpu_stats"]!["cpu_usage"]!["total_usage"]!.int!)
    let sys = Double(j["cpu_stats"]!["system_cpu_usage"]!.int! - j["precpu_stats"]!["system_cpu_usage"]!.int!)
    #expect(abs(cpu / sys * 64 * 100 - 100) < 0.01)  // one busy CPU for 2 s = 100%
}

@Test func eventFiltersOrWithinKeyAndAcrossKeys() {
    let e = DockerEvent(type: "container", action: "die", id: "abc123", attributes: ["name": "web", "a": "1"], time: Date())
    #expect(e.matches(["event": ["start", "die"], "container": ["web"]]))
    #expect(!e.matches(["event": ["die"], "label": ["a=2"]]))
    #expect(e.matches(["container": ["abc"], "label": ["a"]]))
    #expect(e.json["status"]?.string == "die")
}

@Test func healthConfigParsesDockerForms() {
    let shell = HealthConfig(["Test": ["CMD-SHELL", "test -f /ok"], "Interval": 1_000_000_000, "Retries": 2])
    #expect(shell?.command == ["/bin/sh", "-c", "test -f /ok"])
    #expect(shell?.interval == 1)
    #expect(shell?.retries == 2)
    #expect(shell?.timeout == 30)
    #expect(HealthConfig(["Test": ["NONE"]]) == nil)
    #expect(HealthConfig(nil) == nil)
}

@Test func healthTurnsUnhealthyAfterRetriesAndRecovers() {
    var h = HealthState()
    let fail = HealthState.Probe(start: Date(), end: Date(), exitCode: 1, output: "")
    let pass = HealthState.Probe(start: Date(), end: Date(), exitCode: 0, output: "")
    #expect(h.record(fail, retries: 2, inStartPeriod: true) == nil)  // start period: not counted
    #expect(h.record(fail, retries: 2, inStartPeriod: false) == nil)
    #expect(h.record(fail, retries: 2, inStartPeriod: false) == "unhealthy")
    #expect(h.record(pass, retries: 2, inStartPeriod: false) == "healthy")
    #expect(h.failingStreak == 0)
    for _ in 0..<7 { _ = h.record(pass, retries: 2, inStartPeriod: false) }
    #expect(h.log.count == 5)
}
