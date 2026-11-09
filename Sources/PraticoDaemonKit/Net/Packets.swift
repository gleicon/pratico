import Foundation

/// Wire formats pratico-net speaks (SPEC D-27). Every parser checks bounds: frames come
/// from containers, which are untrusted.

struct MAC: Hashable, Sendable, CustomStringConvertible {
    var bytes: [UInt8]  // 6

    static let broadcast = MAC(bytes: [0xff, 0xff, 0xff, 0xff, 0xff, 0xff])
    /// The gateway's address on every network: locally administered, unicast.
    static let gateway = MAC(bytes: [0x02, 0x50, 0x52, 0x00, 0x00, 0x01])

    var isMulticast: Bool { bytes[0] & 1 == 1 }
    var description: String { bytes.map { String(format: "%02x", $0) }.joined(separator: ":") }

    /// Stable per container and NIC: `02:42` + 4 bytes of a hash, as Docker's are `02:42:…`.
    static func derive(_ seed: String) -> MAC {
        var h: UInt32 = 2_166_136_261
        for b in seed.utf8 { h = (h ^ UInt32(b)) &* 16_777_619 }
        return MAC(bytes: [0x02, 0x42, UInt8(h >> 24), UInt8(h >> 16 & 0xff), UInt8(h >> 8 & 0xff), UInt8(h & 0xff)])
    }

    init(bytes: [UInt8]) { self.bytes = bytes }

    init?(_ s: String) {
        let parts = s.split(separator: ":").compactMap { UInt8($0, radix: 16) }
        guard parts.count == 6 else { return nil }
        bytes = parts
    }
}

enum EtherType: UInt16 {
    case ipv4 = 0x0800
    case arp = 0x0806
}

/// Read-only view over a frame with bounds-checked big-endian accessors.
struct Bytes {
    let data: [UInt8]
    var count: Int { data.count }

    func u8(_ i: Int) -> UInt8? { i >= 0 && i < data.count ? data[i] : nil }
    func u16(_ i: Int) -> UInt16? {
        guard i >= 0, i + 2 <= data.count else { return nil }
        return UInt16(data[i]) << 8 | UInt16(data[i + 1])
    }
    func u32(_ i: Int) -> UInt32? {
        guard i >= 0, i + 4 <= data.count else { return nil }
        return UInt32(data[i]) << 24 | UInt32(data[i + 1]) << 16 | UInt32(data[i + 2]) << 8 | UInt32(data[i + 3])
    }
    func slice(_ i: Int, _ n: Int) -> [UInt8]? {
        guard i >= 0, n >= 0, i + n <= data.count else { return nil }
        return Array(data[i..<(i + n)])
    }
}

struct Ethernet {
    var dst: MAC
    var src: MAC
    var type: UInt16
    var payload: [UInt8]

    init(dst: MAC, src: MAC, type: UInt16, payload: [UInt8]) {
        self.dst = dst
        self.src = src
        self.type = type
        self.payload = payload
    }

    init?(_ frame: [UInt8]) {
        let b = Bytes(data: frame)
        guard let d = b.slice(0, 6), let s = b.slice(6, 6), let t = b.u16(12) else { return nil }
        dst = MAC(bytes: d)
        src = MAC(bytes: s)
        type = t
        payload = Array(frame[14...])
    }

    var bytes: [UInt8] { dst.bytes + src.bytes + [UInt8(type >> 8), UInt8(type & 0xff)] + payload }
}

struct ARP {
    var op: UInt16  // 1 request, 2 reply
    var senderMAC: MAC
    var senderIP: UInt32
    var targetMAC: MAC
    var targetIP: UInt32

    init(op: UInt16, senderMAC: MAC, senderIP: UInt32, targetMAC: MAC, targetIP: UInt32) {
        self.op = op
        self.senderMAC = senderMAC
        self.senderIP = senderIP
        self.targetMAC = targetMAC
        self.targetIP = targetIP
    }

    init?(_ p: [UInt8]) {
        let b = Bytes(data: p)
        guard b.u16(0) == 1, b.u16(2) == 0x0800, b.u8(4) == 6, b.u8(5) == 4, let op = b.u16(6),
            let sha = b.slice(8, 6), let spa = b.u32(14), let tha = b.slice(18, 6), let tpa = b.u32(24)
        else { return nil }
        self.op = op
        senderMAC = MAC(bytes: sha)
        senderIP = spa
        targetMAC = MAC(bytes: tha)
        targetIP = tpa
    }

    var bytes: [UInt8] {
        [0, 1, 0x08, 0x00, 6, 4, UInt8(op >> 8), UInt8(op & 0xff)] + senderMAC.bytes + be32(senderIP)
            + targetMAC.bytes + be32(targetIP)
    }
}

func be16(_ v: UInt16) -> [UInt8] { [UInt8(v >> 8), UInt8(v & 0xff)] }
func be32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8(v >> 16 & 0xff), UInt8(v >> 8 & 0xff), UInt8(v & 0xff)] }

/// RFC 1071 one's-complement checksum.
func inetChecksum(_ data: [UInt8], initial: UInt32 = 0) -> UInt16 {
    var sum = initial
    var i = 0
    while i + 1 < data.count {
        sum += UInt32(data[i]) << 8 | UInt32(data[i + 1])
        i += 2
    }
    if i < data.count { sum += UInt32(data[i]) << 8 }
    while sum >> 16 != 0 { sum = (sum & 0xffff) + (sum >> 16) }
    return ~UInt16(sum)
}

struct IPv4Packet {
    var src: UInt32
    var dst: UInt32
    var proto: UInt8  // 1 ICMP, 6 TCP, 17 UDP
    var ttl: UInt8
    var payload: [UInt8]

    init(src: UInt32, dst: UInt32, proto: UInt8, ttl: UInt8 = 64, payload: [UInt8]) {
        self.src = src
        self.dst = dst
        self.proto = proto
        self.ttl = ttl
        self.payload = payload
    }

    /// Only unfragmented packets with a valid header; fragments are dropped.
    init?(_ p: [UInt8]) {
        let b = Bytes(data: p)
        guard let vihl = b.u8(0), vihl >> 4 == 4 else { return nil }
        let ihl = Int(vihl & 0x0f) * 4
        guard ihl >= 20, let total = b.u16(2), Int(total) >= ihl, Int(total) <= p.count,
            let flags = b.u16(6), flags & 0x3fff == 0,  // no MF, offset 0
            let ttl = b.u8(8), let proto = b.u8(9), let src = b.u32(12), let dst = b.u32(16),
            inetChecksum(Array(p[0..<ihl])) == 0
        else { return nil }
        self.src = src
        self.dst = dst
        self.proto = proto
        self.ttl = ttl
        payload = Array(p[ihl..<Int(total)])
    }

    var bytes: [UInt8] {
        let total = UInt16(20 + payload.count)
        var h: [UInt8] = [0x45, 0] + be16(total) + [0, 0, 0x40, 0, ttl, proto, 0, 0] + be32(src) + be32(dst)
        let c = inetChecksum(h)
        h[10] = UInt8(c >> 8)
        h[11] = UInt8(c & 0xff)
        return h + payload
    }

    /// The packet as wire bytes, split into fragments when it exceeds `mtu` (RFC 791).
    static func fragments(src: UInt32, dst: UInt32, proto: UInt8, payload: [UInt8], mtu: Int) -> [[UInt8]] {
        guard 20 + payload.count > mtu else { return [IPv4Packet(src: src, dst: dst, proto: proto, payload: payload).bytes] }
        let step = (mtu - 20) & ~7
        let id = UInt16.random(in: 1...UInt16.max)
        var out: [[UInt8]] = []
        var offset = 0
        while offset < payload.count {
            let chunk = Array(payload[offset..<min(offset + step, payload.count)])
            let more = offset + chunk.count < payload.count
            let flagsOffset = (more ? UInt16(0x2000) : 0) | UInt16(offset / 8)
            var h: [UInt8] = [0x45, 0] + be16(UInt16(20 + chunk.count)) + be16(id) + be16(flagsOffset)
                + [64, proto, 0, 0] + be32(src) + be32(dst)
            let c = inetChecksum(h)
            h[10] = UInt8(c >> 8)
            h[11] = UInt8(c & 0xff)
            out.append(h + chunk)
            offset += chunk.count
        }
        return out
    }

    /// Pseudo-header sum for TCP/UDP checksums.
    static func pseudo(_ src: UInt32, _ dst: UInt32, _ proto: UInt8, _ length: Int) -> UInt32 {
        var s: UInt32 = (src >> 16) + (src & 0xffff) + (dst >> 16) + (dst & 0xffff)
        s += UInt32(proto) + UInt32(length)
        return s
    }
}

struct UDPDatagram {
    var srcPort: UInt16
    var dstPort: UInt16
    var payload: [UInt8]

    init(srcPort: UInt16, dstPort: UInt16, payload: [UInt8]) {
        self.srcPort = srcPort
        self.dstPort = dstPort
        self.payload = payload
    }

    init?(_ p: [UInt8]) {
        let b = Bytes(data: p)
        guard let s = b.u16(0), let d = b.u16(2), let len = b.u16(4), Int(len) >= 8, Int(len) <= p.count else { return nil }
        srcPort = s
        dstPort = d
        payload = Array(p[8..<Int(len)])
    }

    func bytes(src: UInt32, dst: UInt32) -> [UInt8] {
        var out = be16(srcPort) + be16(dstPort) + be16(UInt16(8 + payload.count)) + [0, 0] + payload
        var c = inetChecksum(out, initial: IPv4Packet.pseudo(src, dst, 17, out.count))
        if c == 0 { c = 0xffff }
        out[6] = UInt8(c >> 8)
        out[7] = UInt8(c & 0xff)
        return out
    }
}

/// ICMP echo reply for a request (`type 8`), or nil.
func icmpEchoReply(_ p: [UInt8]) -> [UInt8]? {
    guard p.count >= 8, p[0] == 8, inetChecksum(p) == 0 else { return nil }
    var out = p
    out[0] = 0
    out[2] = 0
    out[3] = 0
    let c = inetChecksum(out)
    out[2] = UInt8(c >> 8)
    out[3] = UInt8(c & 0xff)
    return out
}

/// The question of a DNS query, and builders for the answers pratico gives.
struct DNSQuery {
    var id: UInt16
    var flags: UInt16
    var name: String  // lowercased, no trailing dot
    var qtype: UInt16
    var qclass: UInt16
    var questionEnd: Int  // offset just past the question

    init?(_ p: [UInt8]) {
        let b = Bytes(data: p)
        guard let id = b.u16(0), let flags = b.u16(2), flags & 0x8000 == 0, b.u16(4) == 1 else { return nil }
        var i = 12
        var labels: [String] = []
        var total = 0
        while true {
            guard let len = b.u8(i) else { return nil }
            if len == 0 { i += 1; break }
            guard len & 0xc0 == 0, let label = b.slice(i + 1, Int(len)) else { return nil }  // no compression in queries
            total += Int(len) + 1
            guard total <= 255 else { return nil }
            labels.append(String(decoding: label, as: UTF8.self).lowercased())
            i += 1 + Int(len)
        }
        guard let qt = b.u16(i), let qc = b.u16(i + 2) else { return nil }
        self.id = id
        self.flags = flags
        name = labels.joined(separator: ".")
        qtype = qt
        qclass = qc
        questionEnd = i + 4
    }

    /// Answers with A records (empty: no records, NOERROR) or NXDOMAIN.
    func answer(_ query: [UInt8], addresses: [UInt32]?, ttl: UInt32 = 0) -> [UInt8] {
        let rd = flags & 0x0100
        let rcode: UInt16 = addresses == nil ? 3 : 0
        let count = UInt16(addresses?.count ?? 0)
        var out = be16(id) + be16(0x8000 | 0x0400 | rd | 0x0080 | rcode) + be16(1) + be16(count) + be16(0) + be16(0)
        out += Array(query[12..<questionEnd])
        for a in addresses ?? [] {
            out += [0xc0, 12] + be16(1) + be16(1) + be32(ttl) + be16(4) + be32(a)
        }
        return out
    }
}
