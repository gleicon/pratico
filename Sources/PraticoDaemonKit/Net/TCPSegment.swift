import Foundation

/// A TCP segment (RFC 9293) as pratico-net's uplink reads and writes it.
struct TCPSegment {
    static let fin: UInt8 = 0x01, syn: UInt8 = 0x02, rst: UInt8 = 0x04, psh: UInt8 = 0x08, ack: UInt8 = 0x10

    var srcPort: UInt16
    var dstPort: UInt16
    var seq: UInt32
    var ack: UInt32
    var flags: UInt8
    var window: UInt16
    var payload: [UInt8]
    /// From the options of a SYN.
    var mss: UInt16?
    var windowScale: UInt8?

    init(srcPort: UInt16, dstPort: UInt16, seq: UInt32, ack: UInt32, flags: UInt8, window: UInt16,
         payload: [UInt8] = [], mss: UInt16? = nil, windowScale: UInt8? = nil)
    {
        self.srcPort = srcPort
        self.dstPort = dstPort
        self.seq = seq
        self.ack = ack
        self.flags = flags
        self.window = window
        self.payload = payload
        self.mss = mss
        self.windowScale = windowScale
    }

    /// Parses and verifies the checksum against the IP addresses.
    init?(_ p: [UInt8], src: UInt32, dst: UInt32) {
        let b = Bytes(data: p)
        guard let sp = b.u16(0), let dp = b.u16(2), let seq = b.u32(4), let ack = b.u32(8), let off = b.u8(12),
            let flags = b.u8(13), let win = b.u16(14)
        else { return nil }
        let headerLen = Int(off >> 4) * 4
        guard headerLen >= 20, headerLen <= p.count,
            inetChecksum(p, initial: IPv4Packet.pseudo(src, dst, 6, p.count)) == 0
        else { return nil }
        srcPort = sp
        dstPort = dp
        self.seq = seq
        self.ack = ack
        self.flags = flags
        window = win
        payload = Array(p[headerLen...])
        var i = 20
        while i < headerLen {
            guard let kind = b.u8(i) else { break }
            if kind == 0 { break }
            if kind == 1 { i += 1; continue }
            guard let len = b.u8(i + 1), len >= 2, i + Int(len) <= headerLen else { break }
            if kind == 2, len == 4 { mss = b.u16(i + 2) }
            if kind == 3, len == 3 { windowScale = min(b.u8(i + 2) ?? 0, 14) }
            i += Int(len)
        }
    }

    func has(_ f: UInt8) -> Bool { flags & f != 0 }

    func bytes(src: UInt32, dst: UInt32) -> [UInt8] {
        var options: [UInt8] = []
        if let mss { options += [2, 4] + be16(mss) }
        if let windowScale { options += [1, 3, 3, windowScale] }  // NOP pads to 4 bytes
        let headerLen = 20 + options.count
        var out = be16(srcPort) + be16(dstPort) + be32(seq) + be32(ack)
            + [UInt8(headerLen / 4) << 4, flags] + be16(window) + [0, 0, 0, 0] + options + payload
        let c = inetChecksum(out, initial: IPv4Packet.pseudo(src, dst, 6, out.count))
        out[16] = UInt8(c >> 8)
        out[17] = UInt8(c & 0xff)
        return out
    }
}

/// Sequence-number comparisons modulo 2³².
func seqLT(_ a: UInt32, _ b: UInt32) -> Bool { Int32(bitPattern: a &- b) < 0 }
func seqLE(_ a: UInt32, _ b: UInt32) -> Bool { Int32(bitPattern: a &- b) <= 0 }
