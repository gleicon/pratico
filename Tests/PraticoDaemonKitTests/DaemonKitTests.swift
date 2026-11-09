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

@Test func registryAuthHeaderDecodesBase64URL() {
    // {"username":"u","password":"p?>","serveraddress":"https://index.docker.io/v1/"}
    let json = #"{"username":"u","password":"p?>","serveraddress":"https://index.docker.io/v1/"}"#
    let b64url = Data(json.utf8).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    #expect(RegistryAuth.header(b64url) == RegistryAuth(username: "u", password: "p?>", server: "docker.io"))
    #expect(RegistryAuth.header("e30=") == nil)  // {} from an anonymous pull
}

@Test func loopbackRegistriesUseHTTPLikeDocker() {
    #expect(RegistryAuth.schemeArgs("localhost:5000") == ["--scheme", "http"])
    #expect(RegistryAuth.schemeArgs("127.0.0.1:15000") == ["--scheme", "http"])
    #expect(RegistryAuth.schemeArgs("ghcr.io").isEmpty)
    #expect(RegistryAuth.host(ofImage: "127.0.0.1:15000/e2e/bb:1") == "127.0.0.1:15000")
    #expect(RegistryAuth.host(ofImage: "alpine") == "docker.io")
}

@Test func emptyServerAddressMeansDockerHub() {
    #expect(RegistryAuth.body(["username": "u", "password": "p"])?.server == "docker.io")
    #expect(RegistryAuth.body(["username": "u", "password": "p", "serveraddress": "ghcr.io"])?.server == "ghcr.io")
}

@Test func onlyWellFormedDigestsBecomePaths() {
    #expect(ImageService.isDigest("sha256:" + String(repeating: "a", count: 64)))
    #expect(!ImageService.isDigest("sha256:../../etc/passwd"))
    #expect(!ImageService.isDigest("sha256:" + String(repeating: "A", count: 64)))
    #expect(!ImageService.isDigest("sha512:" + String(repeating: "a", count: 64)))
}

private let osvSample = Data(#"""
{"results":[{"packages":[
 {"package":{"name":"zlib","version":"1.3.2-r1","ecosystem":"Alpine:v3.24"},
  "vulnerabilities":[{"id":"ALPINE-CVE-2026-4738"}],
  "groups":[{"ids":["ALPINE-CVE-2026-4738"],"aliases":["ALPINE-CVE-2026-4738","CVE-2026-4738"],"max_severity":"9.4"}]},
 {"package":{"name":"evil-pkg","version":"1.0.0","ecosystem":"npm"},
  "groups":[{"ids":["MAL-2026-1"],"aliases":[],"max_severity":""}]},
 {"package":{"name":"musl","version":"1.2.5-r9","ecosystem":"Alpine:v3.24"}}]}]}
"""#.utf8)

private let grypeSample = Data(#"""
{"matches":[{"vulnerability":{"id":"CVE-2026-4738","severity":"Critical","fix":{"state":"fixed","versions":["1.4-r0"]},
  "cvss":[{"metrics":{"baseScore":9.4}}]},"relatedVulnerabilities":[],"artifact":{"name":"zlib","version":"1.3.2-r1"}}]}
"""#.utf8)

@Test func osvParserReadsFindingsAndBOM() {
    let (findings, packages) = ScanParsers.osv(osvSample)
    #expect(packages.count == 3)
    #expect(findings.count == 2)
    #expect(findings[0].severity == "critical" && findings[0].cves == ["CVE-2026-4738"])
    #expect(findings[1].malicious)
}

@Test func mergeJoinsScannersByAlias() {
    let merged = ScanParsers.merge([ScanParsers.osv(osvSample).findings, ScanParsers.grype(grypeSample)])
    #expect(merged.count == 2)
    let zlib = merged.first { $0.package == "zlib" }
    #expect(zlib?.sources == ["grype", "osv"])
    #expect(zlib?.fixed == ["1.4-r0"])
}

@Test func verdictFollowsScanBlockLevel() {
    var findings = ScanParsers.merge([ScanParsers.osv(osvSample).findings])
    let critOnly = findings.filter { !$0.malicious }
    #expect(ScanVerdict.judge(critOnly, ran: true, block: "kev").0 == .warning)  // default: Critical warns
    #expect(ScanVerdict.judge(critOnly, ran: true, block: "critical").0 == .serious)
    #expect(ScanVerdict.judge(findings, ran: true, block: "malware").0 == .serious)
    #expect(ScanVerdict.judge(findings, ran: true, block: "off").0 == .warning)
    findings = critOnly
    findings[0].kev = true
    #expect(ScanVerdict.judge(findings, ran: true, block: "kev").0 == .serious)
    #expect(ScanVerdict.judge(findings, ran: true, block: "malware").0 == .warning)
    #expect(ScanVerdict.judge([], ran: false, block: "kev").0 == .unknown)
    #expect(ScanVerdict.judge([], ran: true, block: "kev").0 == .ok)
}

@Test func failedScannerKeepsItsPriorFindings() {
    let mal = ScanFinding(id: "MAL-1", sources: ["osv"], package: "p", version: "1", severity: "unknown", malicious: true)
    let both = ScanFinding(id: "CVE-1", sources: ["grype", "osv"], package: "q", version: "1", severity: "critical")
    let grypeOnly = ScanFinding(id: "CVE-2", sources: ["grype"], package: "r", version: "1", severity: "low")
    #expect(ScanParsers.carryOver([mal, both, grypeOnly], failed: ["osv"]) == [mal, both])
    #expect(ScanParsers.carryOver([mal, both, grypeOnly], failed: []).isEmpty)
    // osv offline, grype re-reports CVE-1 as only High: the merged finding stays Critical.
    var weaker = both
    weaker.sources = ["grype"]
    weaker.severity = "high"
    let merged = ScanParsers.merge([[weaker], ScanParsers.carryOver([both], failed: ["osv"])])
    #expect(merged.count == 1 && merged[0].severity == "critical")
}

@Test func subnetsSkipOverlapsWithNetworksAndHost() {
    #expect(IPv4.overlaps("172.18.0.0/24", "172.18.0.77/32"))
    #expect(IPv4.overlaps("172.16.0.0/12", "172.18.5.0/24"))
    #expect(!IPv4.overlaps("172.18.0.0/24", "172.18.1.0/24"))
    #expect(IPv4.freeSubnet(avoiding: []) == "172.18.0.0/24")
    #expect(IPv4.freeSubnet(avoiding: ["172.18.0.0/24", "172.18.1.9/16"]) == nil)
    #expect(IPv4.freeSubnet(avoiding: ["172.18.0.0/23", "192.168.64.0/24"]) == "172.18.2.0/24")
}

@Test func hostsFileListsPeersOnceWithAliases() {
    let text = NetworkService.hostsFile(
        hostname: "abc123", ownIP: "172.18.0.2",
        peers: [("172.18.0.2", ["a", "abc123"]), ("172.18.0.3", ["b", "db", "def456"]), ("172.18.0.3", ["b"])])
    #expect(text == """
        127.0.0.1\tlocalhost
        ::1\tlocalhost ip6-localhost ip6-loopback
        172.18.0.2\tabc123
        # pratico: containers on shared networks
        172.18.0.2\ta abc123
        172.18.0.3\tb db def456

        """)
}

@Test func networkFlagsFollowTheContainerName() {
    let args = ContainerService.withNetworks(["create", "--name", "x", "-e", "A=1", "--", "img"], ["pratico-n", "default"])
    #expect(args == ["create", "--name", "x", "--network", "pratico-n", "--network", "default", "-e", "A=1", "--", "img"])
}

@Test func startErrorsUseDockerWording() {
    let missing = ContainerService.startError("cannot start: failed to find target executable /x", executable: "/x")
    #expect(missing.status == 400 && missing.message.contains("executable file not found"))
    #expect(ContainerService.startError("permission denied", executable: "/x").message.contains("permission denied"))
    #expect(ContainerService.startError("vm failed", executable: "/x").status == 500)
}

@Test func collectingWriterStopsAtItsLimit() throws {
    let w = CollectingWriter(limit: 5)
    try w.write(Data("abc".utf8))
    try w.write(Data("defgh".utf8))
    try w.write(Data("ijk".utf8))
    #expect(w.data == Data("abcde".utf8))
}

@Test func hostNamesNeverEscapeTheWorkDirectory() throws {
    #expect(try ArchiveService.hostName("/etc/hosts") == "hosts")
    #expect(try ArchiveService.hostName("/") == "rootfs")
    #expect(throws: APIError.self) { try ArchiveService.hostName("/tmp/..") }
    #expect(throws: APIError.self) { try ArchiveService.hostName("/tmp/.") }
}

@Test func shimCopyPathsStayInsideTheContainerDirectory() {
    let dir = FileManager.default.temporaryDirectory
    #expect(ShimControl.inside(dir.appending(path: "cp-1/x").path, dir))
    #expect(!ShimControl.inside(dir.appending(path: "cp-1/../../etc/passwd").path, dir))
    #expect(!ShimControl.inside(dir.appending(path: "..").path, dir))
    #expect(!ShimControl.inside("/etc/passwd", dir))
}

@Test func escapingLinksAreFoundWithoutFollowingThem() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "pratico-links-\(UUID().uuidString)")
    let fm = FileManager.default
    try fm.createDirectory(at: root.appending(path: "d"), withIntermediateDirectories: true)
    try Data("x".utf8).write(to: root.appending(path: "d/f"))
    try fm.createSymbolicLink(atPath: root.appending(path: "d/in").path, withDestinationPath: "f")
    try fm.createSymbolicLink(atPath: root.appending(path: "d/out").path, withDestinationPath: "/etc/passwd")
    try fm.createSymbolicLink(atPath: root.appending(path: "up").path, withDestinationPath: "../x")
    defer { try? fm.removeItem(at: root) }
    let links = try ArchiveService.escapingLinks(in: root).map(\.0).sorted()
    #expect(links == ["d/out", "up"])
}
