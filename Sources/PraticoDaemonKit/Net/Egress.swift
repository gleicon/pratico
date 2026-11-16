import Foundation

/// Where containers' traffic goes, and whether it may (D-51). Every outbound flow passes
/// through pratico's uplink on the Mac, out of the container's reach: the guard names it
/// (pratico's DNS answers, the TLS ClientHello's SNI, the HTTP Host header), records it,
/// and refuses it when a threat feed lists the name or address, or when the container
/// has an allowlist the destination is not on.
final class EgressGuard: @unchecked Sendable {
    struct Flow: Sendable {
        var time: Date
        var proto: String  // tcp, udp, dns
        var ip: UInt32
        var port: UInt16
        var name: String?
        var blocked: Bool
        var reason: String?
    }

    enum Verdict: Equatable {
        case allow
        case block(String)
    }

    /// Flows kept per container, and names it resolved: bounded, oldest out first.
    static let maxFlows = 2_000
    static let maxNames = 4_096

    private let lock = NSLock()
    private var feeds = ThreatSet()
    private var flows: [String: [Flow]] = [:]
    private var names: [String: [UInt32: String]] = [:]
    /// Off: flows are recorded and threats alert, nothing is refused (`egress_block`).
    let blockThreats: Bool
    /// A container's allowlist, if it has one (its `dev.pratico.egress.allow` label).
    var allowlist: @Sendable (String) -> [String]? = { _ in nil }
    /// Called once per refused or listed destination and container: alerts and events.
    var onThreat: @Sendable (_ container: String, _ destination: String, _ reason: String, _ blocked: Bool) -> Void = { _, _, _, _ in }

    init(blockThreats: Bool) { self.blockThreats = blockThreats }

    func setFeeds(_ set: ThreatSet) { lock.withLock { feeds = set } }

    var feedCounts: (names: Int, addresses: Int) { lock.withLock { (feeds.names.count, feeds.addresses.count + feeds.ranges.count) } }

    // MARK: Decisions

    /// A name a container asks pratico's DNS for.
    func checkName(_ container: String, _ name: String) -> Verdict {
        let host = Self.normalized(name)
        if let allowed = allowlist(container), !Self.matches(host, allowed) {
            return .block("\(host) is not on this container's egress allowlist")
        }
        if let feed = lock.withLock({ feeds.listing(name: host) }) { return threat(container, host, feed) }
        return .allow
    }

    func hasAllowlist(_ container: String) -> Bool { allowlist(container) != nil }

    /// A connection's first packet: its address, and the name pratico resolved for it.
    func checkAddress(_ container: String, _ ip: UInt32, port: UInt16, isMac: Bool) -> Verdict {
        let known = lock.withLock { names[container]?[ip] }
        if let allowed = allowlist(container) {
            guard let known, Self.matches(known, allowed) || (isMac && Self.matches("host.docker.internal", allowed)) else {
                return .block("\(IPv4.format(ip)) was not resolved from a name on this container's egress allowlist")
            }
        }
        if !isMac, let feed = lock.withLock({ feeds.listing(ip: ip, port: port) }) { return threat(container, known ?? IPv4.format(ip), feed) }
        return .allow
    }

    /// The name a connection's first bytes carry (SNI, Host): checked like a DNS name.
    func checkCarried(_ container: String, _ name: String) -> Verdict { checkName(container, name) }

    private func threat(_ container: String, _ destination: String, _ feed: String) -> Verdict {
        onThreat(container, destination, feed, blockThreats)
        return blockThreats ? .block("\(destination) is listed by \(feed)") : .allow
    }

    // MARK: Records

    func resolved(_ container: String, _ name: String, _ addresses: [UInt32]) {
        lock.withLock {
            var map = names[container] ?? [:]
            if map.count + addresses.count > Self.maxNames { map.removeAll(keepingCapacity: true) }
            for a in addresses { map[a] = Self.normalized(name) }
            names[container] = map
        }
    }

    func record(_ container: String, _ flow: Flow) {
        lock.withLock {
            var list = flows[container] ?? []
            if list.count >= Self.maxFlows { list.removeFirst(list.count - Self.maxFlows + 1) }
            list.append(flow)
            flows[container] = list
            precondition(list.count <= Self.maxFlows, "egress record past its bound")
        }
    }

    /// The name pratico resolved for an address, for naming a flow.
    func name(_ container: String, _ ip: UInt32) -> String? { lock.withLock { names[container]?[ip] } }

    func flows(_ container: String) -> [Flow] { lock.withLock { flows[container] ?? [] } }

    func forget(_ container: String) {
        lock.withLock {
            flows[container] = nil
            names[container] = nil
        }
    }

    // MARK: Matching

    static func normalized(_ name: String) -> String {
        var n = name.lowercased()
        if n.hasSuffix(".") { n.removeLast() }
        return n
    }

    /// `pypi.org` matches itself; `*.example.com` and `.example.com` match its subdomains.
    static func matches(_ name: String, _ patterns: [String]) -> Bool {
        let n = normalized(name)
        return patterns.contains { raw in
            let p = normalized(raw)
            if p.hasPrefix("*.") { return n.hasSuffix(String(p.dropFirst(1))) }
            if p.hasPrefix(".") { return n.hasSuffix(p) }
            return n == p
        }
    }
}

/// Threat feed contents, merged: names (a listed domain covers its subdomains), single
/// addresses, `ip:port` pairs, and CIDR ranges, each with the feed that listed it.
struct ThreatSet: Sendable {
    var names: [String: String] = [:]
    var addresses: [UInt32: String] = [:]
    var ipPorts: [UInt64: String] = [:]
    /// Sorted, non-overlapping as given (Spamhaus DROP is): start, end, feed.
    var ranges: [(start: UInt32, end: UInt32, feed: String)] = []

    func listing(name: String) -> String? {
        var n = Substring(name)
        for _ in 0..<64 {  // a DNS name has at most 127 labels; 64 parents is plenty
            if let feed = names[String(n)] { return feed }
            guard let dot = n.firstIndex(of: ".") else { return nil }
            n = n[n.index(after: dot)...]
        }
        return nil
    }

    func listing(ip: UInt32, port: UInt16) -> String? {
        if let feed = addresses[ip] { return feed }
        if let feed = ipPorts[UInt64(ip) << 16 | UInt64(port)] { return feed }
        var lo = 0, hi = ranges.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if ranges[mid].end < ip { lo = mid + 1 } else { hi = mid }
        }
        return lo < ranges.count && ranges[lo].start <= ip ? ranges[lo].feed : nil
    }

    mutating func addRange(_ cidr: String, _ feed: String) {
        guard let c = IPv4.cidr(cidr) else { return }
        let size = UInt32(1) << UInt32(32 - c.prefix)
        ranges.append((c.base, c.base &+ (size &- 1), feed))
    }

    mutating func sortRanges() { ranges.sort { $0.start < $1.start } }
}

/// The name a connection's first bytes carry: a TLS ClientHello's SNI or an HTTP
/// request's Host. Parsed from untrusted bytes with every length checked.
enum FirstBytes {
    enum Result: Equatable {
        case needMore
        case name(String)
        /// TLS or HTTP whose name cannot be read: no SNI, a malformed or split ClientHello,
        /// an ambiguous request (two Host headers, a target naming another host).
        case unnamed
        /// Another protocol.
        case none
    }

    /// Bytes held before deciding: a ClientHello with post-quantum key shares spans
    /// segments; past this, the connection carries no name pratico can read.
    static let maxInspect = 16 * 1024 + 5

    static func inspect(_ b: [UInt8]) -> Result {
        guard !b.isEmpty else { return .needMore }
        if b[0] == 0x16 { return clientHello(b) }
        // HTTP only while the bytes still spell a method: a protocol whose client speaks
        // and then waits (SSH's banner, SMTP's EHLO) must never be held.
        let start = b.prefix(8)
        let methods = ["GET ", "POST ", "PUT ", "HEAD ", "DELETE ", "OPTIONS ", "PATCH ", "CONNECT "].map { Array($0.utf8) }
        if methods.contains(where: { $0.starts(with: start) }) { return .needMore }
        if methods.contains(where: { start.starts(with: $0) }) { return httpHost(b) }
        return .none
    }

    static func clientHello(_ b: [UInt8]) -> Result {
        guard b.count >= 5 else { return .needMore }
        guard b[1] == 0x03 else { return .unnamed }
        let recordLength = Int(b[3]) << 8 | Int(b[4])
        guard b.count >= 5 + min(recordLength, 4) else { return .needMore }
        var r = Reader(b, from: 5, to: min(b.count, 5 + recordLength))
        guard r.byte() == 0x01, let _ = r.skip(3), let _ = r.skip(2 + 32) else { return b.count < 5 + recordLength ? .needMore : .unnamed }
        guard let sid = r.byte(), r.skip(Int(sid)) != nil,
            let suites = r.u16(), r.skip(Int(suites)) != nil,
            let comp = r.byte(), r.skip(Int(comp)) != nil,
            let extLen = r.u16()
        else { return b.count < 5 + recordLength ? .needMore : .unnamed }
        let end = r.offset + Int(extLen)
        var count = 0
        while r.offset + 4 <= end, count < 256 {
            count += 1
            guard let type = r.u16(), let len = r.u16() else { break }
            guard type == 0 else {
                if r.skip(Int(len)) == nil { break }
                continue
            }
            guard r.u16() != nil, r.byte() == 0, let nameLen = r.u16(), let bytes = r.take(Int(nameLen)),
                let name = String(bytes: bytes, encoding: .ascii), !name.isEmpty, name.count <= 253
            else { return .unnamed }
            return .name(EgressGuard.normalized(name))
        }
        return b.count < 5 + recordLength ? .needMore : .unnamed
    }

    static func httpHost(_ b: [UInt8]) -> Result {
        let head = b.prefix(8 * 1024)
        guard let end = find(Array(head), [13, 10, 13, 10]) else { return b.count >= 8 * 1024 ? .none : .needMore }
        let text = String(decoding: head[..<end], as: UTF8.self)
        let lines = text.split(separator: "\r\n")
        // An absolute-form target (`GET http://host/ …`) is where a proxy sends it.
        let target = lines.first?.split(separator: " ").dropFirst().first.map(String.init) ?? ""
        let absolute = target.contains("://") ? URL(string: target)?.host.map(EgressGuard.normalized) : nil
        let hosts = lines.dropFirst().compactMap { line -> String? in
            let (key, value) = String(line).splitOnce(":")
            guard key.trimmingCharacters(in: .whitespaces).lowercased() == "host", let value else { return nil }
            var host = value.trimmingCharacters(in: .whitespaces)
            if let colon = host.lastIndex(of: ":"), !host.contains("]") { host = String(host[..<colon]) }
            return EgressGuard.normalized(host)
        }
        guard hosts.count <= 1 else { return .unnamed }
        if let absolute, let host = hosts.first, host != absolute { return .unnamed }
        guard let name = absolute ?? hosts.first, !name.isEmpty else { return .unnamed }
        return .name(name)
    }

    private static func find(_ hay: [UInt8], _ needle: [UInt8]) -> Int? {
        guard hay.count >= needle.count else { return nil }
        outer: for i in 0...(hay.count - needle.count) {
            for j in needle.indices where hay[i + j] != needle[j] { continue outer }
            return i
        }
        return nil
    }

    /// A bounds-checked cursor.
    struct Reader {
        let b: [UInt8]
        var offset: Int
        let end: Int
        init(_ b: [UInt8], from: Int, to: Int) {
            self.b = b
            offset = from
            end = to
        }
        mutating func byte() -> UInt8? {
            guard offset < end else { return nil }
            defer { offset += 1 }
            return b[offset]
        }
        mutating func u16() -> UInt16? {
            guard offset + 2 <= end else { return nil }
            defer { offset += 2 }
            return UInt16(b[offset]) << 8 | UInt16(b[offset + 1])
        }
        mutating func skip(_ n: Int) -> Void? {
            guard n >= 0, offset + n <= end else { return nil }
            offset += n
            return ()
        }
        mutating func take(_ n: Int) -> [UInt8]? {
            guard n >= 0, offset + n <= end else { return nil }
            defer { offset += n }
            return Array(b[offset..<offset + n])
        }
    }
}
