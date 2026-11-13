import ContainerizationArchive
import Foundation
import Testing

import PraticoCore
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
    _ = StatsService.epoch  // as StatsService.init does: samples before the epoch clamp to 0
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

@Test func registryHostOfAnImage() {
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

@Test func dnsQueriesParseAndAnswer() throws {
    // id 0x1234, RD, one question: db.example A IN
    let q: [UInt8] = [0x12, 0x34, 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0,
                      2, 0x64, 0x62, 7] + Array("example".utf8) + [0, 0, 1, 0, 1]
    let query = try #require(DNSQuery(q))
    #expect(query.name == "db.example" && query.qtype == 1)
    let a = query.answer(q, addresses: [0xac11_0002])
    #expect(a[3] & 0x0f == 0 && a[7] == 1)  // NOERROR, one answer
    #expect(Array(a.suffix(4)) == [172, 17, 0, 2])
    #expect(query.answer(q, addresses: nil)[3] & 0x0f == 3)  // NXDOMAIN
    #expect(DNSQuery(Array(q.prefix(14))) == nil)  // truncated
}

@Test func ipv4HeadersChecksumAndRoundTrip() throws {
    let p = IPv4Packet(src: 0xac11_0002, dst: 0xac11_0001, proto: 17, payload: [1, 2, 3])
    let parsed = try #require(IPv4Packet(p.bytes))
    #expect(parsed.src == p.src && parsed.dst == p.dst && parsed.payload == [1, 2, 3])
    var bad = p.bytes
    bad[8] ^= 0xff  // corrupt TTL: checksum no longer matches
    #expect(IPv4Packet(bad) == nil)
    let arp = ARP(op: 1, senderMAC: .gateway, senderIP: 1, targetMAC: .broadcast, targetIP: 2)
    #expect(ARP(arp.bytes)?.targetIP == 2)
}

@Test func largePacketsAreFragmentedToTheMTU() throws {
    let payload = [UInt8](repeating: 7, count: 4000)
    let frags = IPv4Packet.fragments(src: 1, dst: 2, proto: 17, payload: payload, mtu: 1500)
    #expect(frags.count == 3 && frags.allSatisfy { $0.count <= 1500 })
    #expect(frags.map { $0.count - 20 }.reduce(0, +) == 4000)
    #expect(frags[0][6] & 0x20 != 0 && frags[2][6] & 0x20 == 0)  // MF on all but the last
    #expect(inetChecksum(Array(frags[1][0..<20])) == 0)
    let tcp = TCPSegment(srcPort: 80, dstPort: 5000, seq: 1, ack: 2, flags: TCPSegment.ack, window: 100, payload: [1, 2, 3])
    #expect(TCPSegment(tcp.bytes(src: 10, dst: 20), src: 10, dst: 20)?.payload == [1, 2, 3])
    #expect(TCPSegment(tcp.bytes(src: 10, dst: 20), src: 10, dst: 21) == nil)  // wrong pseudo-header
    #expect(seqLT(0xffff_fff0, 0x10) && !seqLT(0x10, 0xffff_fff0))
}

@Test func guestMSSIsClamped() {
    #expect(TCPConn.clampMSS(0) == 536)
    #expect(TCPConn.clampMSS(nil) == 536)
    #expect(TCPConn.clampMSS(1) == 64)
    #expect(TCPConn.clampMSS(9000) == 1460)
}

@Test func nicSlotsBindRevertAndHandOverThePrimary() throws {
    let a = ShimNIC(networkId: "a", mac: "02:42:00:00:00:01", address: "172.17.0.2/16", gateway: "172.17.0.1", socket: "/s.0")
    let spare = ShimNIC.spare(1, mac: MAC.derive("x"), socket: "/s.1")
    #expect(spare.isSpare && spare.hasPlaceholder)
    var nics = NICSlots([a, spare, .spare(2, mac: MAC.derive("y"), socket: "/s.2")], primary: 0)

    let net = try #require(IPv4.cidr("172.18.0.0/24"))
    let (slot, reused) = try #require(nics.free(in: net))
    #expect(slot == 1 && !reused)
    let b = nics.bind(slot, networkId: "b", address: "172.18.0.2/24", gateway: "172.18.0.1")
    #expect(nics.primary == 0)
    nics.revert(b)
    #expect(nics.slots[1] == spare)

    _ = nics.bind(1, networkId: "b", address: "172.18.0.2/24", gateway: "172.18.0.1")
    let unbound = nics.unbind("a")
    let cut = try #require(unbound)
    #expect(cut.slot == 0 && cut.wasPrimary && cut.successor == 1 && nics.primary == 1)
    #expect(nics.slots[0].address == a.address)  // the guest still holds it
    _ = nics.unbind("b")
    #expect(nics.primary == nil)
    // Back on b: its old slot, with the same address.
    #expect(nics.free(in: net).map { $0.slot == 1 && $0.reused } == true)
    _ = nics.bind(1, networkId: "b", address: "172.18.0.2/24", gateway: "172.18.0.1")
    #expect(nics.primary == 1)
}

@Test func nicSlotsReadOlderSpecs() throws {
    let a = #"{"networkId":"a","mac":"02:42:00:00:00:01","address":"172.17.0.2/16","gateway":"172.17.0.1","socket":"/s.0""#
    let b = #"{"networkId":"b","mac":"02:42:00:00:00:02","address":"172.18.0.2/24","gateway":"172.18.0.1","socket":"/s.1""#
    func read(_ json: String) throws -> NICSlots { try JSONDecoder().decode(NICSlots.self, from: Data(json.utf8)) }
    #expect(try read("[\(a)}, \(b)}]").primary == 0)  // before slots: the first NIC
    #expect(try read(#"[\#(a),"primary":false}, \#(b),"primary":true}]"#).primary == 1)  // a flag per NIC
    let current = NICSlots(try read("[\(a)}]").slots, primary: nil)
    #expect(try JSONDecoder().decode(NICSlots.self, from: JSONEncoder().encode(current)) == current)
}

@Test func guestAddressesAreAddedOncePerSlot() {
    let held = GuestAddresses(["172.17.0.2/16", "169.254.255.2/32"])
    #expect(!held.claim(0, "172.17.0.2/16"))
    #expect(held.claim(1, "172.18.0.3/24"))
    #expect(!held.claim(1, "172.18.0.3/24"))
    held.release(1, "172.18.0.3/24")
    #expect(held.claim(1, "172.18.0.3/24"))
}

@Test func registryPolicyReadsConfigAndCAs() throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: "pratico-ca-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    // A real certificate (any will do): macOS must be able to read it.
    let pem = dir.appending(path: "ca.pem")
    let p = Process()
    p.executableURL = URL(filePath: "/usr/bin/openssl")
    p.arguments = ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1", "-subj", "/CN=pratico test CA",
                   "-keyout", dir.appending(path: "ca.key").path, "-out", pem.path]
    p.standardError = FileHandle.nullDevice
    try p.run()
    p.waitUntilExit()
    let config = try Config.parse("""
        registry_http = ["10.0.0.5:5000"]
        registry_ca = ["\(pem.path)"]
        """)
    let policy = try RegistryPolicy.load(config, environment: [:])
    #expect(policy.cas.count == 1 && policy.cas[0].subject == "pratico test CA" && policy.cas[0].sha256.count == 64)
    #expect(policy.plainHTTPReason("10.0.0.5:5000") != nil)
    #expect(policy.plainHTTPReason("127.0.0.1:5000") != nil)
    #expect(policy.plainHTTPReason("ghcr.io") == nil)
    #expect(policy.warnings.count == 2)
    #expect(policy.registryConfig["IndexConfigs"]?["10.0.0.5:5000"]?["Secure"] == .bool(false))

    #expect(throws: (any Error).self) { try RegistryPolicy.load(Config.parse("registry_ca = [\"/nonexistent.pem\"]"), environment: [:]) }
    #expect(throws: (any Error).self) { try RegistryPolicy.load(Config.parse("registry_system_roots = false"), environment: [:]) }
    let strict = try RegistryPolicy.load(Config.parse("registry_http_loopback = false"), environment: [:])
    #expect(strict.plainHTTPReason("localhost:5000") == nil)
}

@Test func registryChallengesParse() {
    let c = RegistrySession.parseChallenges(#"Bearer realm="https://auth.docker.io/token",service="registry.docker.io",scope="repository:library/alpine:pull""#)
    #expect(c.count == 1 && c[0].type == "bearer")
    #expect(c[0].params["realm"] == "https://auth.docker.io/token")
    #expect(c[0].params["scope"] == "repository:library/alpine:pull")
    let b = RegistrySession.parseChallenges(#"Basic realm="e2e""#)
    #expect(b.first?.type == "basic" && b.first?.params["realm"] == "e2e")
}

@Test func registryProxyComesFromTheEnvironment() {
    #expect(RegistrySession.environmentProxy([:]) == nil)
    let d = RegistrySession.environmentProxy(["HTTPS_PROXY": "http://proxy.corp:3128", "NO_PROXY": "localhost, .corp"])
    #expect(d?[kCFNetworkProxiesHTTPSProxy] as? String == "proxy.corp")
    #expect(d?[kCFNetworkProxiesHTTPSPort] as? Int == 3128)
    #expect(d?["ExceptionsList"] as? [String] == ["localhost", ".corp"])
}

@Test func onlyRealLoopbackHostsCountAsLoopback() {
    for h in ["localhost", "localhost:5000", "127.0.0.1", "127.1.2.3:5000", "[::1]:5000"] {
        #expect(RegistryPolicy.isLoopback(h), "\(h)")
    }
    // DNS names that merely look like loopback must never get plain HTTP with credentials.
    for h in ["127.attacker.example", "127.0.0.1.nip.io:5000", "localhost.example.com", "128.0.0.1", "10.0.0.1:5000"] {
        #expect(!RegistryPolicy.isLoopback(h), "\(h)")
    }
}

@Test func registryHTTPMatchesHostsPortsAndCIDRs() {
    var p = RegistryPolicy()
    p.httpHosts = ["10.0.0.0/8", "reg.local", "build:5000"]
    p.httpLoopback = false
    #expect(p.plainHTTPReason("10.1.2.3:5000") != nil)
    #expect(p.plainHTTPReason("11.0.0.1") == nil)
    #expect(p.plainHTTPReason("reg.local:443") != nil)  // a bare host covers its ports
    #expect(p.plainHTTPReason("build:5000") != nil)
    #expect(p.plainHTTPReason("build:5001") == nil)
    #expect(p.plainHTTPReason("127.0.0.1:5000") == nil)
    #expect(p.registryConfig["InsecureRegistryCIDRs"] == ["10.0.0.0/8"])
}

@Test func socketMountsAreRelayedAndDockerSocketIsTheDaemons() throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: "pratico-sock-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let api = dir.appending(path: "d.sock").path
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    defer { close(fd) }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &addr.sun_path) { dst in api.utf8CString.withUnsafeBytes { dst.copyMemory(from: $0) } }
    #expect(withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } } == 0)

    let mounts = try ContainerService.mounts([
        "Binds": ["/var/run/docker.sock:/var/run/docker.sock", .string("\(dir.path):/data:ro")],
        "Mounts": [["Type": "bind", "Source": "/run/docker.sock", "Target": "/d.sock"]],
    ])
    #expect(mounts.map(\.createSource) == [false, true, false])
    let shim = mounts.map { ContainerService.shimMount($0, dockerSocket: api) }
    #expect(shim == [
        ShimMount(source: api, destination: "/var/run/docker.sock", readOnly: false, socket: true),
        ShimMount(source: dir.path, destination: "/data", readOnly: true),
        ShimMount(source: api, destination: "/d.sock", readOnly: false, socket: true),
    ])
    let old = try JSONDecoder().decode(ShimMount.self, from: Data(#"{"source":"/a","destination":"/b","readOnly":false}"#.utf8))
    #expect(old == ShimMount(source: "/a", destination: "/b", readOnly: false))
}

@Test func loginsNotKeptAreNeverReadBack() throws {
    var p = try RegistryPolicy.load(try Config.parse("registry_keep_logins = false"), environment: [:])
    #expect(!p.keepLogins)
    let r = Registries(policy: p, home: FileManager.default.temporaryDirectory)
    #expect(r.credentials(nil, for: "registry-1.docker.io") == nil)
    let sent = RegistryAuth(username: "u", password: "p", server: "reg.local")
    #expect(r.credentials(sent, for: "reg.local")?.username == "u")
    p.keepLogins = true
    #expect(p.summary["keepLogins"]?.bool == true)
}

@Test func tarKeepsLinksAsLinksAndRefusesEscapes() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appending(path: "pratico-tar-\(UUID().uuidString.prefix(8))")
    defer { try? fm.removeItem(at: root) }
    let src = root.appending(path: "src/d")
    try fm.createDirectory(at: src, withIntermediateDirectories: true)
    try Data("hi".utf8).write(to: src.appending(path: "f"))
    try fm.createSymbolicLink(atPath: src.appending(path: "out").path, withDestinationPath: "/etc/hosts")
    let archive = root.appending(path: "a.tar")
    try Tar.create(archive, base: root.appending(path: "src"), names: ["d"])

    let dst = root.appending(path: "dst")
    try Tar.extract(archive, to: dst)
    #expect(try String(contentsOf: dst.appending(path: "d/f"), encoding: .utf8) == "hi")
    #expect(try fm.destinationOfSymbolicLink(atPath: dst.appending(path: "d/out").path) == "/etc/hosts")

    // A member that climbs out of the destination is refused.
    let evil = root.appending(path: "evil.tar")
    let w = try ArchiveWriter(configuration: ArchiveWriterConfiguration(format: .pax, filter: .none))
    try w.open(file: evil)
    let e = WriteEntry()
    e.path = "../escaped"
    e.fileType = .regular
    e.permissions = 0o644
    e.size = 1
    try w.writeEntry(entry: e, data: Data("x".utf8))
    try w.finishEncoding()
    #expect(throws: APIError.self) { try Tar.extract(evil, to: root.appending(path: "dst2")) }
    #expect(!fm.fileExists(atPath: root.appending(path: "escaped").path))
}

@Test func trivyAndCustomScannerOutputBecomeFindings() throws {
    let trivy = Data(#"{"Results":[{"Vulnerabilities":[{"VulnerabilityID":"CVE-2024-1","PkgName":"openssl","InstalledVersion":"3.0.1","FixedVersion":"3.0.2, 3.1.0","Severity":"HIGH","CVSS":{"nvd":{"V3Score":7.5}}}]}]}"#.utf8)
    let t = ScanParsers.trivy(trivy)
    #expect(t.count == 1 && t[0].id == "CVE-2024-1" && t[0].package == "openssl" && t[0].fixed == ["3.0.2", "3.1.0"])
    #expect(t[0].severity == "high" && t[0].cvss == 7.5 && t[0].sources == ["trivy"])

    let custom = Data(#"{"findings":[{"id":"MAL-X","package":"p","version":"1","severity":"Critical","malicious":true},{"id":"CVE-2","package":"q","severity":"bogus"},{"package":"no-id"}]}"#.utf8)
    let c = try #require(ScanParsers.custom(custom, source: "mine"))
    #expect(c.map(\.id) == ["MAL-X", "CVE-2"])
    #expect(c[0].malicious && c[0].severity == "critical" && c[0].sources == ["mine"])
    #expect(c[1].severity == "unknown")
    #expect(ScanParsers.custom(Data("not json".utf8), source: "mine") == nil)
}
