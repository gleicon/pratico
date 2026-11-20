import Foundation

/// Where containers' traffic goes, and whether it may (D-51). Every outbound flow passes
/// through pratico's uplink on the Mac, out of the container's reach: the guard names it
/// (pratico's DNS answers, the TLS ClientHello's SNI, the HTTP Host header), records it,
/// and refuses it when a threat feed lists the name or address, or when the container
/// has an allowlist the destination is not on. In ask mode (D-62) a destination not on
/// it waits for an answer instead (`EgressQuestions`).
final class EgressGuard: @unchecked Sendable {
    struct Flow: Sendable {
        var time: Date
        var proto: String  // tcp, udp, dns
        var ip: UInt32
        var port: UInt16
        /// The container's side: with the address and port, the connection the recorder saw.
        var sourcePort: UInt16
        var name: String?
        var blocked: Bool
        var reason: String?
    }

    enum Verdict: Equatable {
        case allow
        case block(String)
        /// Ask mode: hold this, named so, until someone answers.
        case ask(String)
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
    /// A container's allowlist, if it has one (its `dev.pratico.egress.allow` label, and in
    /// ask mode what was answered `always`; an empty one in ask mode).
    var allowlist: @Sendable (String) -> [String]? = { _ in nil }
    /// Whether a container is in ask mode (its `dev.pratico.egress.ask` label).
    var askMode: @Sendable (String) -> Bool = { _ in false }
    let questions = EgressQuestions()
    /// Called once per refused or listed destination and container: alerts and events.
    var onThreat: @Sendable (_ container: String, _ destination: String, _ reason: String, _ blocked: Bool) -> Void = { _, _, _, _ in }

    init(blockThreats: Bool) { self.blockThreats = blockThreats }

    func setFeeds(_ set: ThreatSet) { lock.withLock { feeds = set } }

    var feedCounts: (names: Int, addresses: Int) { lock.withLock { (feeds.names.count, feeds.addresses.count + feeds.ranges.count) } }

    // MARK: Decisions

    /// A name a container asks pratico's DNS for.
    func checkName(_ container: String, _ name: String) -> Verdict {
        let host = Self.normalized(name)
        let feed = lock.withLock { feeds.listing(name: host) }
        if let allowed = allowlist(container), !Self.matches(host, allowed) {
            // A listed destination is refused, never offered for an answer.
            if let feed, blockThreats { return threat(container, host, feed) }
            switch asked(container, host) {
            case .allow?: break
            case let verdict?: return verdict
            case nil: return .block("\(host) is not on this container's egress allowlist")
            }
        }
        if let feed { return threat(container, host, feed) }
        return .allow
    }

    func hasAllowlist(_ container: String) -> Bool { allowlist(container) != nil }

    /// A connection's first packet: its address, and the name pratico resolved for it.
    func checkAddress(_ container: String, _ ip: UInt32, port: UInt16, isMac: Bool) -> Verdict {
        let known = lock.withLock { names[container]?[ip] }
        let feed = isMac ? nil : lock.withLock { feeds.listing(ip: ip, port: port) }
        // An address is allowed through a name pratico resolved for it, or listed itself
        // (as ask mode's `always` keeps a bare address).
        if let allowed = allowlist(container), !allowed.contains(IPv4.format(ip)),
            !(known.map { Self.matches($0, allowed) } ?? false), !(isMac && Self.matches("host.docker.internal", allowed)) {
            if let feed, blockThreats { return threat(container, known ?? IPv4.format(ip), feed) }
            switch asked(container, known ?? IPv4.format(ip)) {
            case .allow?: break
            case let verdict?: return verdict
            case nil: return .block("\(IPv4.format(ip)) was not resolved from a name on this container's egress allowlist")
            }
        }
        if let feed { return threat(container, known ?? IPv4.format(ip), feed) }
        return .allow
    }

    /// Ask mode, for a destination its allowlist does not hold: what was answered while the
    /// container runs, else a question. Nil outside ask mode.
    private func asked(_ container: String, _ destination: String) -> Verdict? {
        guard askMode(container) else { return nil }
        switch questions.decided(container, destination) {
        case true?: return .allow
        case false?: return .block("\(destination) was refused when asked")
        case nil: return .ask(destination)
        }
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
        questions.removed(container)
    }

    /// A container stopped: answers given while it ran end, and its questions are refused.
    func stopped(_ container: String) { questions.stopped(container) }

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
        // HTTP is told by its request line (`TOKEN target HTTP/x.y`), whatever the method.
        // Bytes are held only while they read as text and until that first line ends: a
        // binary client (Postgres starts with length bytes) is never held, and a line-based
        // one (an SSH banner, Redis's PING) ends its line at once.
        let head = b.prefix(maxLine)
        guard let newline = head.firstIndex(where: { $0 == 10 || $0 == 13 }) else {
            guard head.allSatisfy({ (0x20...0x7E).contains($0) || $0 == 9 }) else { return .none }
            return b.count >= maxLine ? .unnamed : .needMore
        }
        let line = String(decoding: head[..<newline], as: UTF8.self)
        return requestLine(line) != nil ? httpHost(b) : .none
    }

    /// The longest line read, in a first request or later: past it, a line names nothing.
    static let maxLine = 8 * 1024

    /// `TOKEN target HTTP/x.y`: method and target, for any method.
    static func requestLine(_ line: String) -> (method: String, target: String)? {
        let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
        let tchars = Set("!#$%&'*+-.^_`|~0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")
        guard parts.count == 3, parts[2].hasPrefix("HTTP/"), !parts[0].isEmpty, parts[0].allSatisfy(tchars.contains) else { return nil }
        return (String(parts[0]), String(parts[1]))
    }

    /// The host a request target names: nil for origin-form (`/…`, `*`), the host for
    /// absolute-form and CONNECT's authority-form, "" for a target that cannot be read.
    static func targetHost(_ method: String, _ target: String) -> String? {
        if target.hasPrefix("/") || target == "*" { return nil }
        if method.uppercased() == "CONNECT" {
            let host = target.hasPrefix("[") ? "" : target.splitOnce(":").0
            return EgressGuard.normalized(host)
        }
        guard target.contains("://"), let host = URL(string: target)?.host, !host.isEmpty else { return "" }
        return EgressGuard.normalized(host)
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
        // A request head that never ends is HTTP all the same: unnamed, not another protocol.
        guard let end = find(Array(head), [13, 10, 13, 10]) else { return b.count >= 8 * 1024 ? .unnamed : .needMore }
        let text = String(decoding: head[..<end], as: UTF8.self)
        let lines = text.split(separator: "\r\n")
        // A folded header (a line starting with a space) may continue Host: unreadable.
        if lines.dropFirst().contains(where: { $0.first == " " || $0.first == "\t" }) { return .unnamed }
        // Bare line endings inside the head could hide a second Host: unreadable too.
        if text.replacingOccurrences(of: "\r\n", with: "").contains(where: { $0 == "\n" || $0 == "\r" }) { return .unnamed }
        // An absolute-form target (`GET http://host/ …`) or CONNECT's `host:port` is where a
        // proxy sends it; one that cannot be read names nothing.
        guard let request = lines.first.flatMap({ requestLine(String($0)) }) else { return .unnamed }
        let absolute = targetHost(request.method, request.target)
        if absolute == "" { return .unnamed }
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

/// Later requests on a plain-HTTP connection from a container with an allowlist: lines
/// read across segments, the incomplete one kept whole up to `FirstBytes.maxLine`, and
/// every host they name (request targets, Host headers) handed back to be checked. A body
/// that holds such a line is checked too, and a line past the bound is unreadable: both
/// err toward refusing (bodies of plain HTTP are rare beside HTTPS's).
struct HTTPStream {
    private var partial: [UInt8] = []
    private var afterHost = false
    private var lastCR = false

    /// The hosts complete lines in `bytes` name; nil when one cannot be read. CRLF, LF, and
    /// a lone CR each end a line (lenient servers read all three).
    mutating func feed(_ bytes: [UInt8]) -> [String]? {
        var hosts: [String] = []
        for byte in bytes {
            defer { lastCR = byte == 13 }
            if byte == 10 && lastCR { continue }  // the LF of a CRLF
            guard byte == 10 || byte == 13 else {
                partial.append(byte)
                if partial.count > FirstBytes.maxLine { return nil }
                continue
            }
            let line = String(decoding: partial, as: UTF8.self)
            partial.removeAll(keepingCapacity: true)
            guard let found = read(line) else { return nil }
            hosts += found
        }
        return hosts
    }

    private mutating func read(_ line: String) -> [String]? {
        if afterHost, line.first == " " || line.first == "\t" { return nil }  // a folded Host
        afterHost = false
        if let r = FirstBytes.requestLine(line) {
            guard let host = FirstBytes.targetHost(r.method, r.target) else { return [] }
            return host.isEmpty ? nil : [host]
        }
        let (name, value) = line.splitOnce(":")
        guard name.trimmingCharacters(in: .whitespaces).lowercased() == "host", let value else { return [] }
        afterHost = true
        var host = value.trimmingCharacters(in: .whitespaces)
        if let colon = host.lastIndex(of: ":"), !host.contains("]") { host = String(host[..<colon]) }
        return host.isEmpty ? nil : [EgressGuard.normalized(host)]
    }
}
