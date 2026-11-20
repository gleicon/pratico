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
    ("docker.io/alpine", "docker.io/library/alpine:latest"),
    ("index.docker.io/heroku/builder:24", "docker.io/heroku/builder:24"),
    ("index.docker.io/redis", "docker.io/library/redis:latest"),
    ("localhost/a", "localhost/a:latest"),
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
    #expect(Connection.splitVersion("/v1.55/containers/json") == ("/containers/json", "1.55"))
    #expect(Connection.splitVersion("/_ping") == ("/_ping", nil))
    #expect(Connection.splitVersion("/volumes/v1") == ("/volumes/v1", nil))
    #expect(throws: APIError.self) { try DockerAPI.accept("1.41") }
    #expect(throws: APIError.self) { try DockerAPI.accept("1.99") }
    #expect(throws: Never.self) { try DockerAPI.accept("1.44"); try DockerAPI.accept("1.55"); try DockerAPI.accept(nil) }
}

@Test func parsesQueryEncoding() {
    let q = Connection.parseQuery("filters=%7B%22label%22%3A%5B%22a%3D1%22%5D%7D&all=1&x=a+b&names=a&names=b%3A1")
    #expect(q["all"] == ["1"])
    #expect(q["x"] == ["a b"])
    #expect(q["names"] == ["a", "b:1"])
    #expect(ContainerService.parseFilters(q["filters"]?.last) == ["label": ["a=1"]])
}

@Test func filtersAcceptMapForm() {
    #expect(ContainerService.parseFilters(#"{"label":{"a=1":true}}"#) == ["label": ["a=1"]])
}

// moby's merge: (request Entrypoint, request Cmd) against an image with entrypoint
// ["/entry"] and cmd ["serve"].
@Test(arguments: [
    (nil, nil, ["/entry", "serve"]),
    (nil, ["run"], ["/entry", "run"]),
    ([], nil, ["serve"]),
    ([""], ["/cnb/lifecycle/creator", "-daemon"], ["/cnb/lifecycle/creator", "-daemon"]),
    ([""], nil, []),
    (["/other"], nil, ["/other"]),
] as [([String]?, [String]?, [String])])
func mergesEntrypointAsMoby(entry: [String]?, cmd: [String]?, expected: [String]) {
    let image: JSON = ["Entrypoint": ["/entry"], "Cmd": ["serve"]]
    let body: JSON = .object(["Entrypoint": entry.map { JSON($0) }, "Cmd": cmd.map { JSON($0) }].compactMapValues { $0 })
    #expect(ContainerService.containerConfig(body, image: image, imageRef: "a", hostname: "h").command == expected)
}

@Test func stdcopyFrameHeader() {
    let f = StdCopy.frame(stream: 2, Data("hi".utf8))
    #expect(Array(f) == [2, 0, 0, 0, 0, 0, 0, 2, 0x68, 0x69])
}

@Test func bindsAreReadWriteUnlessRo() throws {
    let host: JSON = ["Binds": ["/tmp/a:/a", "/tmp/b:/b:ro,z", "/tmp/c:/c:rw"]]
    let m = try ContainerService.mounts(host, volumeData: volumeData)
    #expect(m.map(\.readOnly) == [false, true, false])
    #expect(m.allSatisfy { $0.createSource })
}

private func volumeData(_ name: String) -> String { "/vols/\(name)/_data" }

@Test func namedVolumesMountTheirDataDirectory() throws {
    let m = try ContainerService.mounts(
        ["Binds": ["data:/data:ro"], "Mounts": [["Type": "volume", "Source": "cache", "Target": "/c"]]], volumeData: volumeData)
    #expect(m.map(\.source) == ["/vols/data/_data", "/vols/cache/_data"])
    #expect(m.map(\.volume) == ["data", "cache"])
    #expect(m.map(\.readOnly) == [true, false])
    #expect(!m.contains { $0.createSource })
}

@Test func badMountSpecsRejected() {
    #expect(throws: APIError.self) { try ContainerService.mounts(["Binds": ["/tmp:relative"]], volumeData: volumeData) }
    #expect(throws: APIError.self) { try ContainerService.mounts(["Binds": ["bad/name:/d"]], volumeData: volumeData) }
    #expect(throws: APIError.self) { try ContainerService.mounts(["Mounts": [["Type": "volume", "Target": "/v"]]], volumeData: volumeData) }
    #expect(throws: APIError.self) { try ContainerService.mounts(["Mounts": [["Type": "npipe", "Target": "/t"]]], volumeData: volumeData) }
    #expect(throws: APIError.self) { try ContainerService.mounts(["Tmpfs": ["relative": ""]], volumeData: volumeData) }
}

@Test func tmpfsTakesDockerDefaultsAndOverrides() throws {
    let m = try ContainerService.mounts(
        ["Tmpfs": ["/run": "size=64m,exec"], "Mounts": [["Type": "tmpfs", "Target": "/t", "TmpfsOptions": ["SizeBytes": 1048576, "Mode": 0o1777]]]],
        volumeData: volumeData)
    #expect(m.map(\.destination) == ["/t", "/run"])
    #expect(m[0].tmpfs == ["rw", "noexec", "nosuid", "nodev", "size=1048576", "mode=1777"])
    #expect(m[1].tmpfs == ["rw", "nosuid", "nodev", "size=64m", "exec"])
    #expect(ContainerService.shimMount(m[1], dockerSocket: "").tmpfs != nil)
}

@Test func mountFlagNeedsExistingSource() {
    let missing: JSON = ["Mounts": [["Type": "bind", "Source": "/nonexistent-pratico", "Target": "/x"]]]
    #expect(throws: APIError.self) { try ContainerService.mounts(missing, volumeData: volumeData) }
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

@Test func guestAddressesAreAddedOncePerCard() {
    let held = GuestAddresses([["172.17.0.2/16"], ["169.254.255.2/32"]])
    #expect(!held.claim(0, "172.17.0.2/16"))
    #expect(held.claim(0, "172.18.0.3/24"))
    #expect(!held.claim(0, "172.18.0.3/24"))
    held.release(0, "172.18.0.3/24")
    #expect(held.claim(0, "172.18.0.3/24"))
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
    ], volumeData: volumeData)
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
    try fm.createDirectory(at: dst, withIntermediateDirectories: true)
    try Tar.extract(archive, to: dst, links: true, maxBytes: 1 << 20)
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
    try fm.createDirectory(at: root.appending(path: "dst2"), withIntermediateDirectories: true)
    #expect(throws: APIError.self) { try Tar.extract(evil, to: root.appending(path: "dst2"), links: true, maxBytes: 1 << 20) }
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

/// Where the helpers below put their files: one directory per test run, gone at exit.
private let scratch: URL = {
    let dir = FileManager.default.temporaryDirectory.appending(path: "pratico-tests-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    atexit { try? FileManager.default.removeItem(at: scratch) }
    return dir
}()

/// An archive of `members`: (path, kind) with kind "d", "f:<content>", or "l:<target>".
private func tarFile(_ members: [(String, String)]) throws -> URL {
    let file = scratch.appending(path: "tar-\(UUID().uuidString).tar")
    let w = try ArchiveWriter(configuration: ArchiveWriterConfiguration(format: .pax, filter: .none))
    try w.open(file: file)
    for (path, kind) in members {
        let e = WriteEntry()
        e.path = path
        // The file type first: libarchive's set-type resets the mode.
        if kind == "d" {
            e.fileType = .directory
            e.permissions = 0o755
            try w.writeEntry(entry: e, data: nil)
        } else if kind.hasPrefix("l:") {
            e.fileType = .symbolicLink
            e.permissions = 0o777
            e.symlinkTarget = String(kind.dropFirst(2))
            try w.writeEntry(entry: e, data: nil)
        } else {
            let data = Data(kind.dropFirst(2).utf8)
            e.fileType = .regular
            e.permissions = 0o644
            e.size = Int64(data.count)
            try w.writeEntry(entry: e, data: data)
        }
    }
    try w.finishEncoding()
    return file
}

private func emptyDir() throws -> URL {
    let dir = scratch.appending(path: "x-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@Test func extractNeverWritesThroughALink() throws {
    let outside = try emptyDir()
    let dir = try emptyDir()
    let tar = try tarFile([("a", "l:\(outside.path)"), ("a/pwned", "f:x")])
    #expect(throws: APIError.self) { try Tar.extract(tar, to: dir, links: true, maxBytes: 1 << 20) }
    #expect(!FileManager.default.fileExists(atPath: outside.appending(path: "pwned").path))
}

@Test func extractRefusesEscapesDuplicatesAndLinksWhereNoneBelong() throws {
    #expect(throws: APIError.self) { try Tar.extract(try tarFile([("../x", "f:x")]), to: try emptyDir(), links: true, maxBytes: 1 << 20) }
    #expect(throws: APIError.self) { try Tar.extract(try tarFile([("x", "f:1"), ("x", "f:2")]), to: try emptyDir(), links: true, maxBytes: 1 << 20) }
    #expect(throws: APIError.self) { try Tar.extract(try tarFile([("index.json", "l:/etc/hosts")]), to: try emptyDir(), links: false, maxBytes: 1 << 20) }
    #expect(throws: APIError.self) { try Tar.extract(try tarFile([("big", "f:" + String(repeating: "0", count: 4096))]), to: try emptyDir(), links: true, maxBytes: 1024) }
}

@Test func extractKeepsTreesAndLinks() throws {
    let dir = try emptyDir()
    try Tar.extract(try tarFile([("d", "d"), ("d/f", "f:hello"), ("d/l", "l:f"), ("./g/h", "f:deep")]), to: dir, links: true, maxBytes: 1 << 20)
    #expect(try String(contentsOf: dir.appending(path: "d/f"), encoding: .utf8) == "hello")
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: dir.appending(path: "d/l").path) == "f")
    #expect(try String(contentsOf: dir.appending(path: "g/h"), encoding: .utf8) == "deep")
}

@Test func pruneFilterUntilAndLabels() throws {
    #expect(PruneFilter.duration("1h30m") == 5400)
    #expect(PruneFilter.duration("10s") == 10)
    #expect(PruneFilter.duration("1x") == nil)
    let f = try PruneFilter(["until": ["1h"], "label": ["env=dev"], "label!": ["keep"]])
    let old = Date().addingTimeInterval(-7200)
    #expect(f.matches(created: old, labels: ["env": "dev"]))
    #expect(!f.matches(created: Date(), labels: ["env": "dev"]))
    #expect(!f.matches(created: old, labels: ["env": "prod"]))
    #expect(!f.matches(created: old, labels: ["env": "dev", "keep": "1"]))
    #expect(throws: APIError.self) { try PruneFilter(["status": ["exited"]]) }
    #expect(throws: APIError.self) { try PruneFilter(["until": ["yesterday"]]) }
}

@Test func labelFiltersMustAllMatch() {
    let web = ["project": "t", "service": "web"], api = ["project": "t", "service": "api"]
    let f = ["label": ["project=t", "service=web"]]
    #expect(Filters.pass(f, labels: web) { _, _ in true })
    #expect(!Filters.pass(f, labels: api) { _, _ in true })
    #expect(Filters.pass(["name": ["a", "b"]], labels: [:]) { _, v in v == "b" })  // OR within a key
    #expect(Filters.isTrue("TRUE") && Filters.isTrue("1") && !Filters.isTrue("0"))
}

@Test func switchRewritesCardMACToEndpointMAC() {
    let card = MAC.derive("card"), endpoint = MAC.derive("n2")
    let arp = ARP(op: 1, senderMAC: card, senderIP: 1, targetMAC: MAC(bytes: [0, 0, 0, 0, 0, 0]), targetIP: 2)
    let out = Ethernet(dst: .broadcast, src: card, type: EtherType.arp.rawValue, payload: arp.bytes).bytes
    let sent = NetSwitch.rewrite(out, from: card, to: endpoint, at: [6, 22])
    #expect(Ethernet(sent)?.src == endpoint && Ethernet(sent).flatMap { ARP($0.payload) }?.senderMAC == endpoint)
    #expect(Ethernet(sent)?.dst == .broadcast)
    // IPv4: only the header; payload bytes that happen to equal the MAC stay.
    let ip = Ethernet(dst: endpoint, src: .gateway, type: EtherType.ipv4.rawValue, payload: Array(repeating: 0, count: 18) + endpoint.bytes + Array(repeating: 0, count: 10)).bytes
    let back = NetSwitch.rewrite(ip, from: endpoint, to: card, at: [0, 32])
    #expect(Ethernet(back)?.dst == card && Array(back[32..<38]) == endpoint.bytes)
}

@Test func oneCardCarriesAnAddressPerNetwork() {
    let mac = MAC.derive("c").description
    let a = ShimNIC(networkId: "n1", mac: mac, address: "172.18.0.2/24", gateway: "172.18.0.1", socket: "/s.0")
    let b = ShimNIC(networkId: "n2", mac: mac, address: "172.19.0.2/24", gateway: "172.19.0.1", socket: "/s.0")
    var nics = NICSlots([a, b], primary: 1)
    #expect(nics.cards == ["/s.0"])
    #expect(nics.card(of: 1) == 0)
    #expect(nics.bootEntry(card: 0) == 1)  // the primary's address boots the card
    #expect(nics.cardShared(0) && nics.cardShared(1))
    let n3 = MAC.derive("n3").description
    let added = nics.add(networkId: "n3", mac: n3, address: "172.20.0.2/24", gateway: "172.20.0.1")!
    #expect(nics.slots.count == 3 && nics.slots[2].socket == "/s.0" && nics.slots[2].mac == n3 && nics.cardMAC(of: 2) == mac)
    nics.revert(added)
    #expect(nics.slots == [a, b] && nics.primary == 1)
    _ = nics.unbind("n2")
    #expect(nics.primary == 0 && !nics.cardShared(0))
    // No limit of 4: every network is another address on the card.
    for n in 4...9 { _ = nics.add(networkId: "n\(n)", mac: MAC.derive("n\(n)").description, address: "172.\(18 + n).0.2/24", gateway: "172.\(18 + n).0.1") }
    #expect(nics.cards == ["/s.0"] && nics.slots.count == 8 && nics.extraEntries(card: 0).count == 6)
    #expect(nics.addresses(card: 0).first == "172.18.0.2/24")
}

@Test func runOptionsApplyWhatTheyAccept() throws {
    func parse(_ host: JSON, _ config: JSON = [:]) throws -> RunOptions {
        try RunOptions.parse(host: host, config: config, defaultCPUs: 4, defaultMemoryMiB: 1024)
    }
    let half = try parse(["NanoCpus": 500_000_000])
    #expect(half.cpus == 1 && half.cgroup["cpu.max"] == "50000 100000")
    let quota = try parse(["CpuQuota": 150_000, "CpuPeriod": 100_000, "CpuShares": 512, "CpusetCpus": "0-1", "PidsLimit": 64])
    #expect(quota.cpus == 2 && quota.cgroup["cpu.max"] == "150000 100000" && quota.cgroup["cpuset.cpus"] == "0-1")
    #expect(quota.cgroup["cpu.weight"] == "20" && quota.cgroup["pids.max"] == "64")
    #expect(throws: APIError.self) { try parse(["CpusetCpus": "0-7"]) }  // 4 vCPUs
    #expect(throws: APIError.self) { try parse(["NanoCpus": 1_000_000_000, "CpuQuota": 50_000]) }
    let mem = try parse(["Memory": 268_435_456, "MemorySwap": 536_870_912, "MemoryReservation": 134_217_728])
    #expect(mem.memoryMiB == 256 && mem.cgroup["memory.swap.max"] == "268435456" && mem.cgroup["memory.low"] == "134217728")
    let caps = try parse(["CapAdd": ["NET_ADMIN"], "CapDrop": ["chown"]])
    #expect(caps.capabilities?.contains("CAP_NET_ADMIN") == true && caps.capabilities?.contains("CAP_CHOWN") == false)
    #expect(try parse(["CapDrop": ["ALL"], "CapAdd": ["CAP_KILL"]]).capabilities == ["CAP_KILL"])
    #expect(try parse([:]).capabilities == nil)
    let priv = try parse(["Privileged": true])
    #expect(priv.unmaskedPaths && (priv.capabilities?.count ?? 0) > 30)
    let sec = try parse(["SecurityOpt": ["no-new-privileges", "seccomp=unconfined"]])
    #expect(sec.noNewPrivileges && sec.seccomp == .unconfined)
    #expect(try parse([:]).seccomp == .default)
    #expect(try parse(["SecurityOpt": ["seccomp=builtin"]]).seccomp == .default)
    #expect(priv.seccomp == .unconfined)  // as on Docker
    let custom = #"{"defaultAction":"SCMP_ACT_ALLOW","syscalls":[{"names":["mkdirat"],"action":"SCMP_ACT_ERRNO"}]}"#
    #expect(try parse(["SecurityOpt": [.string("seccomp=" + custom)]]).seccomp == .profile(custom))
    #expect(throws: APIError.self) { try parse(["SecurityOpt": ["seccomp=/tmp/profile.json"]]) }  // a path, not contents
    #expect(throws: APIError.self) { try parse(["SecurityOpt": [#"seccomp={"syscalls":[]}"#]]) }  // no defaultAction
    #expect(throws: APIError.self) { try parse(["SecurityOpt": [#"seccomp={"defaultAction":"SCMP_ACT_NOTIFY"}"#]]) }
    let proc = try parse(["Ulimits": [["Name": "nofile", "Soft": 1024, "Hard": 2048]], "Sysctls": ["net.ipv4.ip_forward": "1"],
                          "ExtraHosts": ["db:10.0.0.5", "mac=host-gateway"], "Dns": ["9.9.9.9"], "Init": true, "ShmSize": 134_217_728],
                         ["Domainname": "example.com", "StopSignal": "SIGWINCH", "StopTimeout": 3])
    #expect(proc.ulimits == [.init(kind: "RLIMIT_NOFILE", soft: 1024, hard: 2048)] && proc.useInit && proc.shmBytes == 134_217_728)
    #expect(proc.sysctls == ["net.ipv4.ip_forward": "1", "kernel.domainname": "example.com"])
    #expect(proc.extraHosts == [.init(name: "db", address: "10.0.0.5"), .init(name: "mac", address: "host-gateway")])
    #expect(proc.dns?.servers == ["9.9.9.9"] && proc.stopSignal == "SIGWINCH" && proc.stopTimeout == 3)
    let restart = try parse(["RestartPolicy": ["Name": "on-failure", "MaximumRetryCount": 3], "LogConfig": ["Type": "json-file", "Config": ["max-size": "10m", "max-file": "3"]]])
    #expect(restart.restart == .init(name: "on-failure", maxRetries: 3) && restart.logBytes == 30 * 1_048_576)
    #expect(throws: APIError.self) { try parse(["RestartPolicy": ["Name": "always"], "AutoRemove": true]) }
    // Refused when set, accepted at the CLI's defaults.
    for refused: JSON in [["Devices": [["PathOnHost": "/dev/null"]]], ["PidMode": "host"], ["VolumesFrom": ["a"]], ["OomKillDisable": true],
                          ["LogConfig": ["Type": "syslog"]], ["MemorySwappiness": 10], ["BlkioWeight": 300],
                          ["PortBindings": ["80/tcp": [["HostIp": "::1", "HostPort": "8080"]]]]] {
        #expect(throws: APIError.self) { try parse(refused) }
    }
    _ = try parse(["Devices": [], "PidMode": "", "OomKillDisable": false, "MemorySwappiness": -1, "BlkioWeight": 0, "IpcMode": "private"])
}

@Test func signalsCoverLinuxNames() {
    #expect(Signals.number("SIGWINCH") == 28 && Signals.number("quit") == 3 && Signals.number("9") == 9)
    #expect(Signals.number("SIGRTMIN+3") == 37 && Signals.number("NOPE") == nil && Signals.number("65") == nil)
}

@Test func restartPolicyDecides() {
    typealias P = RunOptions.RestartPolicy
    #expect(RestartSupervisor.shouldRestart(P(name: "always"), code: 0, restarts: 9, byHand: false))
    #expect(!RestartSupervisor.shouldRestart(P(name: "always"), code: 1, restarts: 0, byHand: true))
    #expect(RestartSupervisor.shouldRestart(P(name: "on-failure", maxRetries: 2), code: 1, restarts: 1, byHand: false))
    #expect(!RestartSupervisor.shouldRestart(P(name: "on-failure", maxRetries: 2), code: 1, restarts: 2, byHand: false))
    #expect(!RestartSupervisor.shouldRestart(P(name: "on-failure"), code: 0, restarts: 0, byHand: false))
    #expect(RestartSupervisor.atDaemonStart(P(name: "always"), byHand: true) && !RestartSupervisor.atDaemonStart(P(name: "unless-stopped"), byHand: true))
    #expect(RestartSupervisor.delay(0) == 0.1 && RestartSupervisor.delay(20) == 60)
}

@Test func sizesAndCPUListsParse() throws {
    #expect(try RunOptions.bytes("10m") == 10_485_760 && RunOptions.bytes("1g") == 1 << 30 && RunOptions.bytes("512") == 512 && RunOptions.bytes("64kb") == 65_536)
    #expect(RunOptions.cpuList("0-2,4") == [0, 1, 2, 4] && RunOptions.cpuList("2-1") == nil && RunOptions.cpuList("a") == nil)
}

@Test func logWindowBoundsByUnixSeconds() throws {
    let w = try LogWindow(since: "100.5", until: "200")
    #expect(w.contains(Date(timeIntervalSince1970: 150)) && !w.contains(Date(timeIntervalSince1970: 100)) && !w.contains(Date(timeIntervalSince1970: 201)))
    #expect(try LogWindow(since: "0", until: nil) == LogWindow(since: nil, until: nil))
    #expect(throws: APIError.self) { try LogWindow(since: "10m", until: nil) }
    #expect(throws: APIError.self) { try LogWindow(since: "300", until: "200") }
}

@Test func psOutputBecomesDockerTop() {
    #expect(throws: APIError.self) { try ContainerService.psTable("   \n1 x\n", hiding: "ps") }
    let t = try! ContainerService.psTable("PID   USER  TIME  COMMAND\n    1 root  0:00  sleep 300\n    7 root  0:00  ps -ef\n", hiding: "ps -ef")
    #expect(t["Titles"]?.strings == ["PID", "USER", "TIME", "COMMAND"])
    #expect(t["Processes"]?.array?.count == 1 && t["Processes"]?.array?[0].strings == ["1", "root", "0:00", "sleep 300"])
}

@Test func diffReportsWhatDockerWould() {
    typealias E = RootfsTree.Entry
    let dir = E(mode: 0o040755, uid: 0, gid: 0, size: 4096, mtime: 1, link: "")
    let file = E(mode: 0o100644, uid: 0, gid: 0, size: 3, mtime: 1, link: "")
    let image: [String: E] = ["/etc": dir, "/etc/motd": file, "/etc/os": file, "/old": dir, "/old/a": file, "/usr": dir]
    var mine = image
    mine["/etc"]?.mtime = 9  // a timestamp alone is no change
    mine["/usr"]?.mtime = 9
    mine["/etc/motd"] = nil
    mine["/etc/new"] = file
    mine["/old"] = nil
    mine["/old/a"] = nil
    mine["/etc/hosts"] = file  // pratico's own
    let c = RootfsTree.changes(from: image, to: mine).map { "\($0.kind) \($0.path)" }
    #expect(c == ["0 /etc", "1 /etc/new", "2 /etc/motd", "2 /old"].sorted { $0.dropFirst(2) < $1.dropFirst(2) })
}

@Test func commitChangesAreDockerfileInstructions() throws {
    let c = try Dockerfile.apply(["CMD [\"cat\", \"/f\"]", "ENTRYPOINT /run.sh", "ENV A=1 B=\"two words\"", "ENV OLD value",
                                  "LABEL team=core", "EXPOSE 8080 53/udp", "VOLUME /data", "USER nobody", "WORKDIR /srv",
                                  "STOPSIGNAL SIGQUIT", "ONBUILD RUN make"], to: ["Env": ["A=0", "PATH=/bin"]])
    #expect(c["Cmd"]?.strings == ["cat", "/f"] && c["Entrypoint"]?.strings == ["/bin/sh", "-c", "/run.sh"])
    #expect(c["Env"]?.strings == ["PATH=/bin", "A=1", "B=two words", "OLD=value"])
    #expect(c["Labels"]?["team"]?.string == "core" && c["ExposedPorts"]?.object?.keys.sorted() == ["53/udp", "8080/tcp"])
    #expect(c["Volumes"]?["/data"] != nil && c["User"]?.string == "nobody" && c["WorkingDir"]?.string == "/srv")
    #expect(c["StopSignal"]?.string == "SIGQUIT" && c["OnBuild"]?.strings == ["RUN make"])
    #expect(throws: APIError.self) { try Dockerfile.apply(["RUN make"], to: [:]) }
}

@Test func mcpTokensCompareWholeAndPortsParse() throws {
    #expect(MCPServer.same("abc", "abc") && !MCPServer.same("abc", "abd") && !MCPServer.same("abc", "abcd"))
    let (b, exposed) = try MCPTools.portBindings(["8080:80", "127.0.0.1:5432:5432/tcp", "53/udp"])
    #expect(Set(exposed) == ["80/tcp", "5432/tcp", "53/udp"])
    #expect(b["80/tcp"]?.array?[0]["HostPort"]?.string == "8080" && b["5432/tcp"]?.array?[0]["HostIp"]?.string == "127.0.0.1")
    #expect(throws: APIError.self) { try MCPTools.portBindings(["80/sctp"]) }
    #expect(throws: APIError.self) { try MCPTools.portBindings(["x:80"]) }
}

@Test func shimMountsRoundTripEveryField() throws {
    let all = [ShimMount(source: "/v/disk.ext4", destination: "/data", readOnly: false, block: true),
               ShimMount(source: "tmpfs", destination: "/t", readOnly: false, tmpfs: ["size=1m"]),
               ShimMount(source: "/s.sock", destination: "/s", readOnly: true, socket: true)]
    #expect(try JSONDecoder().decode([ShimMount].self, from: JSONEncoder().encode(all)) == all)
}

@Test func firstBytesNameTheirDestination() {
    // A minimal ClientHello carrying SNI example.com.
    let name = Array("example.com".utf8)
    var sni: [UInt8] = [0, 0] + [UInt8(0), UInt8(name.count + 5)] + [UInt8(0), UInt8(name.count + 3), 0, 0, UInt8(name.count)] + name
    sni.removeFirst(0)
    let ext: [UInt8] = [UInt8(0), UInt8(sni.count)] + sni
    var hello: [UInt8] = [3, 3] + Array(repeating: 0, count: 32) + [0] + [0, 2, 0x13, 0x01] + [1, 0]
    hello += ext
    let handshake: [UInt8] = [1, 0, UInt8(hello.count >> 8), UInt8(hello.count & 0xff)] + hello
    let record: [UInt8] = [0x16, 3, 1, UInt8(handshake.count >> 8), UInt8(handshake.count & 0xff)] + handshake
    #expect(FirstBytes.inspect(record) == .name("example.com"))
    #expect(FirstBytes.inspect(Array(record.prefix(20))) == .needMore)
    #expect(FirstBytes.inspect(Array("GET / HTTP/1.1\r\nHost: Pypi.org:8080\r\nAccept: */*\r\n\r\n".utf8)) == .name("pypi.org"))
    #expect(FirstBytes.inspect(Array("GET / HTTP/1.1\r\nHost: x".utf8)) == .needMore)
    #expect(FirstBytes.inspect(Array("SSH-2.0-OpenSSH_9.6\r\n".utf8)) == .none)  // a banner ends its line
    #expect(FirstBytes.inspect([0x16, 3, 1, 0xff, 0xff, 1, 0, 0]) == .needMore)  // a claimed 64 KiB record, cut short
}

@Test func threatSetsMatchNamesAddressesAndRanges() {
    var s = ThreatSet()
    s.names["evil.example"] = "test"
    s.addresses[IPv4.parse("203.0.113.9")!] = "c2"
    s.addRange("198.51.100.0/24", "drop")
    s.addRange("10.0.0.0/8", "drop")
    s.sortRanges()
    #expect(s.listing(name: "cdn.evil.example") == "test" && s.listing(name: "notevil.example") == nil)
    #expect(s.listing(ip: IPv4.parse("203.0.113.9")!, port: 443) == "c2")
    #expect(s.listing(ip: IPv4.parse("198.51.100.77")!, port: 1) == "drop" && s.listing(ip: IPv4.parse("198.51.101.1")!, port: 1) == nil)
    #expect(s.listing(ip: IPv4.parse("10.200.0.1")!, port: 1) == "drop")
    #expect(EgressGuard.matches("files.pythonhosted.org", ["pypi.org", "*.pythonhosted.org"]) && !EgressGuard.matches("evil.org", ["pypi.org"]))
    #expect(EgressFeeds.sharedHost("raw.githubusercontent.com") && !EgressFeeds.sharedHost("evil-github.com"))
    let rows = EgressFeeds.csv(Data("# c\n\"1\",\"2024\",\"http://bad.example/x\",\"online\"\n".utf8))
    #expect(rows == [["1", "2024", "http://bad.example/x", "online"]])
}

@Test func ambiguousFirstBytesAreUnnamed() {
    func http(_ s: String) -> FirstBytes.Result { FirstBytes.inspect(Array(s.utf8)) }
    #expect(http("GET http://evil.example/x HTTP/1.1\r\nHost: allowed.example\r\n\r\n") == .unnamed)
    #expect(http("GET / HTTP/1.1\r\nHost: a.example\r\nHost: b.example\r\n\r\n") == .unnamed)
    #expect(http("GET http://a.example/x HTTP/1.1\r\nHost: a.example\r\n\r\n") == .name("a.example"))
    #expect(http("GET / HTTP/1.1\r\nAccept: */*\r\n\r\n") == .unnamed)
    #expect(FirstBytes.inspect([0x16, 0x02, 0, 0, 1, 0]) == .unnamed)  // TLS-looking, wrong version
}

@Test func httpHeadsNameOrAreUnnamed() {
    func http(_ s: String) -> FirstBytes.Result { FirstBytes.inspect(Array(s.utf8)) }
    #expect(FirstBytes.inspect(Array(("GET / HTTP/1.1\r\nX: " + String(repeating: "a", count: 9000)).utf8)) == .unnamed)
    #expect(http("GET http:/// HTTP/1.1\r\n\r\n") == .unnamed)
    #expect(http("GET evil.example HTTP/1.1\r\nHost: a.example\r\n\r\n") == .unnamed)
    #expect(http("CONNECT evil.example:443 HTTP/1.1\r\nHost: evil.example:443\r\n\r\n") == .name("evil.example"))
    var stream = HTTPStream()
    let later = stream.feed(Array("GET / HTTP/1.1\r\nHost: a.example\r\n\r\nGET http://b.example/ HTTP/1.1\r\nhost: C.example:80\r\n\r\n".utf8))
    #expect(later == ["a.example", "b.example", "c.example"])
}

@Test func hostsHideNowhere() {
    func hosts(_ chunks: [String]) -> [String]? {
        var stream = HTTPStream()
        var all: [String] = []
        for c in chunks {
            guard let h = stream.feed(Array(c.utf8)) else { return nil }
            all += h
        }
        return all
    }
    #expect(hosts(["GET / HTTP/1.1\nHost: evil.example\n\n"]) == ["evil.example"])
    #expect(hosts(["GET / HTTP/1.1\r\nHost : evil.example\r\n\r\n"]) == ["evil.example"])
    #expect(hosts(["GET / HTTP/1.1\r\nHost: a.example\r\n evil.example\r\n\r\n"]) == nil)  // folded
    #expect(hosts(["PROPFIND http://evil.example/ HTTP/1.1\r\n"]) == ["evil.example"])  // any method
    #expect(hosts(["GET /x HTTP/1.1\r\nHo", "st: evil.example\r\n"]) == ["evil.example"])  // split across segments
    #expect(hosts([String(repeating: "a", count: 9000)]) == nil)  // a line past the bound
    #expect(hosts(["GET  \tevil.example:80  HTTP/1.1\r\n"]) == nil)  // an unreadable target
    #expect(FirstBytes.inspect(Array("GET / HTTP/1.1\r\nHost: a.example\r\n evil\r\n\r\n".utf8)) == .unnamed)
    #expect(FirstBytes.inspect(Array("GET / HTTP/1.1\r\nHost: a.example\nHost: evil.example\r\n\r\n".utf8)) == .unnamed)
    #expect(FirstBytes.inspect(Array("PROPFIND / HTTP/1.1\r\nHost: a.example\r\n\r\n".utf8)) == .name("a.example"))
    #expect(FirstBytes.inspect(Array("SSH-2.0-OpenSSH_9.6\r\n".utf8)) == .none)
    #expect(FirstBytes.inspect([0, 0, 0, 8, 4, 210, 22, 47]) == .none)  // Postgres SSLRequest: never held
    #expect(FirstBytes.inspect(Array("PING".utf8)) == .needMore)
}

@Test func guestKernelVersionMatchesTheBuild() throws {
    let script = try String(contentsOfFile: "scripts/build-kernel.sh", encoding: .utf8)
    let line = script.split(separator: "\n").first { $0.hasPrefix("KERNEL_VERSION=") }
    let parts = line?.dropFirst("KERNEL_VERSION=".count).split(separator: ".").compactMap { Int($0) } ?? []
    #expect(parts.count == 3 && parts[0] == RunOptions.guestKernel.major && parts[1] == RunOptions.guestKernel.minor)
}

@Test func alertsWithoutKeysMergeByTitle() throws {
    let file = FileManager.default.temporaryDirectory.appending(path: "alerts-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: file) }
    let old: JSON = [["time": "1", "level": "warning", "title": "nginx: 264 finding(s)", "detail": "a"],
                     ["time": "2", "level": "warning", "title": "alpine: 1 finding(s)", "detail": "b"],
                     ["time": "3", "level": "warning", "title": "nginx: 264 finding(s)", "detail": "c"],
                     ["time": "4", "level": "warning", "key": "port:x", "title": "web is reachable", "detail": "d"]]
    try old.encoded().write(to: file)
    _ = AlertLog(path: file)
    let list = try #require(JSON.parse(try Data(contentsOf: file))?.array)
    #expect(list.map { $0["detail"]?.string } == ["b", "c", "d"])  // newest of each title, order kept
    #expect(list.allSatisfy { $0["key"] != nil })
}

@Test func alertsResolveByPrefix() throws {
    let file = FileManager.default.temporaryDirectory.appending(path: "alerts-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: file) }
    let log = AlertLog(path: file)
    log.raise(key: "port:aa:0.0.0.0:80", level: "warning", title: "a", detail: "")
    log.raise(key: "port:aa:0.0.0.0:443", level: "warning", title: "b", detail: "")
    log.raise(key: "port:aab:0.0.0.0:80", level: "warning", title: "c", detail: "")
    log.resolve(prefix: "port:aa:")
    #expect(JSON.parse(try Data(contentsOf: file))?.array?.map { $0["title"]?.string } == ["c"])  // another container's stays
}

@Test func alertsOfMissingContainersAreDropped() throws {
    let file = FileManager.default.temporaryDirectory.appending(path: "alerts-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: file) }
    let log = AlertLog(path: file)
    log.raise(key: "port:gone:0.0.0.0:80", level: "warning", title: "gone port", detail: "")
    log.raise(key: "health:gone", level: "warning", title: "gone health", detail: "")
    log.raise(key: "port:here:0.0.0.0:80", level: "warning", title: "here port", detail: "")
    log.raise(key: "image:sha256:abc", level: "serious", title: "image", detail: "")
    log.dropContainerAlerts(except: ["here"])
    #expect(JSON.parse(try Data(contentsOf: file))?.array?.map { $0["title"]?.string } == ["here port", "image"])
}

// `docker cp -a`: the container's User against its passwd and group files.
@Test func resolvesCopyOwner() {
    let passwd = "root:x:0:0::/root:/bin/sh\nheroku:x:1001:1002::/home/heroku:/bin/bash\n"
    let group = "root:x:0:\nstaff:x:50:\n"
    #expect(ArchiveService.owner(of: "heroku", passwd: passwd, group: group) == Tar.Owner(uid: 1001, gid: 1002))
    #expect(ArchiveService.owner(of: "heroku:staff", passwd: passwd, group: group) == Tar.Owner(uid: 1001, gid: 50))
    #expect(ArchiveService.owner(of: "1234:5678", passwd: passwd, group: group) == Tar.Owner(uid: 1234, gid: 5678))
    #expect(ArchiveService.owner(of: "1001", passwd: passwd, group: group) == Tar.Owner(uid: 1001, gid: 1002))
    #expect(ArchiveService.owner(of: "nobody", passwd: passwd, group: group) == nil)
    #expect(ArchiveService.owner(of: "heroku:nogroup", passwd: passwd, group: group) == nil)
}

// A Docker archive's manifest names its members: inside the archive only.
@Test func dockerArchiveMembersStayInside() throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: "pratico-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try Data().write(to: dir.appending(path: "a.tar"))
    #expect(try DockerArchive.member(dir, "/a.tar") == dir.appending(path: "a.tar"))
    #expect(try DockerArchive.member(dir, "a.tar") == dir.appending(path: "a.tar"))
    #expect(throws: APIError.self) { try DockerArchive.member(dir, "../a.tar") }
    #expect(throws: APIError.self) { try DockerArchive.member(dir, "missing.tar") }
    #expect(throws: APIError.self) { try DockerArchive.member(dir, "/") }
}

// cp into a stopped container: an archive's link at a mount point never leads to the Mac.
@Test func mountPointsInArchivesAreRealDirectories() throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: "pratico-test-\(UUID().uuidString)")
    let outside = dir.appending(path: "outside")
    try FileManager.default.createDirectory(at: outside.appending(path: "data"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: dir.appending(path: "work/real/data"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let work = dir.appending(path: "work")
    try FileManager.default.createSymbolicLink(atPath: work.appending(path: "link").path, withDestinationPath: outside.path)
    #expect(try ArchiveService.realDirectory(work, "real/data") == work.appending(path: "real/data"))
    #expect(try ArchiveService.realDirectory(work, "absent/data") == nil)
    #expect(throws: APIError.self) { try ArchiveService.realDirectory(work, "link/data") }
    #expect(throws: APIError.self) { try ArchiveService.realDirectory(work, "link") }
}

// Ask mode (D-62): one question per container and destination, its answer standing
// until the container stops, `always` kept, silence refused.
@Test func egressQuestionsShareOneQuestionAndRemember() async throws {
    let q = EgressQuestions(wait: 30)
    let saved = LockedBox<[String]>([])
    q.save = { _, list in saved.set(list) }
    let outcomes = LockedBox<[EgressQuestions.Outcome]>([])
    await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
        let both = LockedBox(0)
        for _ in 0..<2 {
            q.ask("c1", "example.com", port: 443) { o in
                outcomes.update { $0.append(o) }
                if both.update({ $0 += 1; return $0 }) == 2 { done.resume() }
            }
        }
        #expect(q.list().count == 1)
        #expect(q.answer(q.list()[0].id, .allow))
    }
    #expect(outcomes.get() == [.allowed, .allowed])
    #expect(q.decided("c1", "example.com") == true && q.list().isEmpty)
    #expect(!q.answer("gone", .deny))

    q.ask("c1", "evil.example", port: 80) { _ in }
    q.answer(q.list()[0].id, .deny)
    #expect(q.decided("c1", "evil.example") == false)
    q.ask("c1", "pypi.org", port: 443) { _ in }
    q.answer(q.list()[0].id, .always)
    #expect(saved.get() == ["pypi.org"] && q.alwaysAllowed("c1") == ["pypi.org"] && q.decided("c1", "pypi.org") == nil)

    q.stopped("c1")
    #expect(q.decided("c1", "example.com") == nil && q.alwaysAllowed("c1") == ["pypi.org"])
    q.removed("c1")
    q.load = { _ in [] }
    #expect(q.alwaysAllowed("c1").isEmpty)
}

@Test func egressQuestionsRefuseWhenNobodyAnswers() async {
    let q = EgressQuestions(wait: 0.1)
    let outcome = await withCheckedContinuation { (done: CheckedContinuation<EgressQuestions.Outcome, Never>) in
        q.ask("c1", "example.com", port: 443) { done.resume(returning: $0) }
    }
    #expect(outcome == .refused("example.com was not answered within 0 s"))
    #expect(q.decided("c1", "example.com") == nil && q.list().isEmpty)  // the next connection asks again
}

// Ask mode in the guard: off the allowlist is a question; an allowed answer still meets the feeds.
@Test func egressGuardAsksInAskMode() {
    let g = EgressGuard(blockThreats: true)
    g.askMode = { _ in true }
    g.allowlist = { _ in ["pypi.org"] }
    g.questions.load = { _ in ["1.1.1.1", "files.example"] }  // answered `always`, matched exactly
    var feeds = ThreatSet()
    feeds.names["evil.example"] = "URLhaus"
    g.setFeeds(feeds)
    #expect(g.checkName("c1", "pypi.org") == .allow)
    #expect(g.checkName("c1", "example.com") == .ask("example.com"))
    #expect(g.checkAddress("c1", 0x0808_0808, port: 53, isMac: false) == .ask("8.8.8.8"))
    #expect(g.checkAddress("c1", 0x0101_0101, port: 53, isMac: false) == .allow)
    #expect(g.checkName("c1", "files.example") == .allow && g.checkName("c1", "a.files.example") == .ask("a.files.example"))
    #expect(g.checkName("c1", "*.example.com") == .block("*.example.com is not a host name pratico asks about"))
    #expect(!EgressGuard.isAskable("-a.com") && !EgressGuard.isAskable("a..com") && EgressGuard.isAskable("_svc.example.com"))
    #expect(g.checkName("c1", "evil.example") == .block("evil.example is listed by URLhaus"))  // listed: never asked
    g.questions.ask("c1", "evil.example", port: 80) { _ in }
    g.questions.answer(g.questions.list()[0].id, .allow)
    #expect(g.checkName("c1", "evil.example") == .block("evil.example is listed by URLhaus"))
    g.askMode = { _ in false }
    #expect(g.checkName("c1", "example.com") == .block("example.com is not on this container's egress allowlist"))
}

/// A value callbacks on other queues update, for tests.
final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ value: T) { self.value = value }
    func get() -> T { lock.withLock { value } }
    func set(_ v: T) { lock.withLock { value = v } }
    @discardableResult func update<R>(_ f: (inout T) -> R) -> R { lock.withLock { f(&value) } }
}
