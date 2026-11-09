import Foundation

/// pratico-net's way out of a network (SPEC D-27, runtime step 4b). Containers' UDP,
/// ping, and TCP leave through ordinary sockets on the Mac, so the Mac's routing, VPN,
/// and firewall apply, and no privileges or extra binaries are needed. Traffic to the
/// gateway address reaches the Mac itself (`host.docker.internal`).
///
/// All state lives on one serial queue: an event loop, no locks.
final class Uplink: @unchecked Sendable {
    struct FlowKey: Hashable {
        var path: String  // the container NIC
        var srcIP: UInt32
        var srcPort: UInt16
        var dstIP: UInt32
        var dstPort: UInt16
    }

    let queue = DispatchQueue(label: "pratico.uplink")
    unowned let sw: NetSwitch
    private var udp: [FlowKey: UDPFlow] = [:]
    private var tcp: [FlowKey: TCPConn] = [:]
    private var pings = 0
    private var timer: DispatchSourceTimer?

    static let maxFlowsPerNIC = 1024
    static let udpIdle: TimeInterval = 60
    static let maxPings = 64

    init(switch sw: NetSwitch) {
        self.sw = sw
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.1, repeating: 0.1)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    /// From the switch thread: a packet for somewhere beyond the network.
    func handle(_ ip: IPv4Packet, from port: NetPort, segment: NetSegment, pratico: [NetSegment]) {
        guard !segment.isInternal else { return }
        let toHost = ip.dst == segment.gateway
        // Another pratico network exists only here; the Mac's routing would send such
        // traffic to a real LAN. Broadcast, multicast, and loopback never leave either.
        if !toHost, pratico.contains(where: { $0.contains(ip.dst) }) { return }
        let first = ip.dst >> 24
        if first == 127 || first == 0 || first >= 224 { return }
        let target = toHost ? IPv4.parse("127.0.0.1")! : ip.dst
        queue.async { [self] in
            switch ip.proto {
            case 17: udpOut(ip, port, target)
            case 6: tcpIn(ip, port, target)
            case 1: ping(ip, port, target)
            default: break
            }
        }
    }

    private func flows(for path: String) -> Int {
        udp.keys.filter { $0.path == path }.count + tcp.keys.filter { $0.path == path }.count
    }

    // MARK: UDP

    final class UDPFlow {
        let fd: Int32
        let source: DispatchSourceRead
        var last = Date()
        init(fd: Int32, source: DispatchSourceRead) {
            self.fd = fd
            self.source = source
        }
    }

    private func udpOut(_ ip: IPv4Packet, _ port: NetPort, _ target: UInt32) {
        guard let d = UDPDatagram(ip.payload) else { return }
        let key = FlowKey(path: port.path, srcIP: ip.src, srcPort: d.srcPort, dstIP: ip.dst, dstPort: d.dstPort)
        if udp[key] == nil {
            guard flows(for: port.path) < Self.maxFlowsPerNIC, let fd = Self.connected(SOCK_DGRAM, target, d.dstPort) else { return }
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            let flow = UDPFlow(fd: fd, source: source)
            source.setEventHandler { [weak self] in
                var buf = [UInt8](repeating: 0, count: 65535)
                let n = recv(fd, &buf, buf.count, 0)
                guard n > 0, let self else { return }
                flow.last = Date()
                let reply = UDPDatagram(srcPort: key.dstPort, dstPort: key.srcPort, payload: Array(buf[0..<n]))
                sw.deliver(to: port, src: key.dstIP, proto: 17, reply.bytes(src: key.dstIP, dst: key.srcIP))
            }
            source.setCancelHandler { close(fd) }
            source.resume()
            udp[key] = flow
        }
        guard let flow = udp[key] else { return }
        flow.last = Date()
        _ = d.payload.withUnsafeBytes { Darwin.send(flow.fd, $0.baseAddress, $0.count, 0) }
    }

    // MARK: ICMP echo (unprivileged ICMP datagram sockets)

    private func ping(_ ip: IPv4Packet, _ port: NetPort, _ target: UInt32) {
        let p = ip.payload
        guard p.count >= 8, p[0] == 8, pings < Self.maxPings else { return }
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
        guard fd >= 0 else { return }
        var sa = Self.sockaddr4(target, 0)
        let sent = withUnsafePointer(to: &sa) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, p, p.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard sent == p.count else { close(fd); return }
        pings += 1
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        let done = Box(false)
        let finish: () -> Void = { [weak self] in
            guard !done.value else { return }
            done.value = true
            source.cancel()
            self?.pings -= 1
        }
        source.setEventHandler { [weak self] in
            var buf = [UInt8](repeating: 0, count: 65535)
            let n = recv(fd, &buf, buf.count, 0)
            guard n > 0, let self else { finish(); return }
            var reply = Array(buf[0..<n])
            if reply[0] >> 4 == 4 {  // macOS includes the IP header
                let ihl: Int = Int(reply[0] & 0x0f) * 4
                reply = ihl < reply.count ? Array(reply[ihl...]) : []
            }
            guard reply.count >= 8, reply[0] == 0 else { return }
            reply.replaceSubrange(4..<8, with: p[4..<8])  // the guest's identifier and sequence
            reply[2] = 0
            reply[3] = 0
            let c = inetChecksum(reply)
            reply[2] = UInt8(c >> 8)
            reply[3] = UInt8(c & 0xff)
            sw.deliver(to: port, src: ip.dst, proto: 1, reply)
            finish()
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        queue.asyncAfter(deadline: .now() + 5) { finish() }
    }

    // MARK: TCP

    private func tcpIn(_ ip: IPv4Packet, _ port: NetPort, _ target: UInt32) {
        guard let seg = TCPSegment(ip.payload, src: ip.src, dst: ip.dst) else { return }
        let key = FlowKey(path: port.path, srcIP: ip.src, srcPort: seg.srcPort, dstIP: ip.dst, dstPort: seg.dstPort)
        if let conn = tcp[key] {
            conn.segment(seg)
            if conn.state == .closed { tcp[key] = nil }
            return
        }
        guard seg.has(TCPSegment.syn), !seg.has(TCPSegment.ack) else {
            // Not part of a known connection: reset it, as a host would.
            if !seg.has(TCPSegment.rst) {
                let rst = seg.has(TCPSegment.ack)
                    ? TCPSegment(srcPort: seg.dstPort, dstPort: seg.srcPort, seq: seg.ack, ack: 0, flags: TCPSegment.rst, window: 0)
                    : TCPSegment(srcPort: seg.dstPort, dstPort: seg.srcPort, seq: 0,
                                 ack: seg.seq &+ UInt32(seg.payload.count) &+ (seg.has(TCPSegment.fin) ? 1 : 0),
                                 flags: TCPSegment.rst | TCPSegment.ack, window: 0)
                sw.deliver(to: port, src: ip.dst, proto: 6, rst.bytes(src: ip.dst, dst: ip.src))
            }
            return
        }
        guard flows(for: port.path) < Self.maxFlowsPerNIC else { return }
        let conn = TCPConn(key: key, port: port, syn: seg, uplink: self)
        tcp[key] = conn
        conn.connect(target)
    }

    fileprivate func remove(_ conn: TCPConn) { tcp[conn.key] = nil }

    private func tick() {
        let now = Date()
        for (k, f) in udp where now.timeIntervalSince(f.last) > Self.udpIdle {
            f.source.cancel()
            udp[k] = nil
        }
        for (k, c) in tcp {
            c.tick(now)
            if c.state == .closed { tcp[k] = nil }
        }
    }

    /// Everything a container NIC had open goes when the container stops.
    func drop(path: String) {
        queue.async { [self] in
            for (k, f) in udp where k.path == path {
                f.source.cancel()
                udp[k] = nil
            }
            for (k, c) in tcp where k.path == path {
                c.close(reset: false)
                tcp[k] = nil
            }
        }
    }

    fileprivate func send(_ seg: TCPSegment, for conn: TCPConn) {
        sw.deliver(to: conn.port, src: conn.key.dstIP, proto: 6, seg.bytes(src: conn.key.dstIP, dst: conn.key.srcIP))
    }

    // MARK: Sockets

    static func sockaddr4(_ ip: UInt32, _ port: UInt16) -> sockaddr_in {
        var sa = sockaddr_in()
        sa.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        sa.sin_family = sa_family_t(AF_INET)
        sa.sin_port = port.bigEndian
        sa.sin_addr = in_addr(s_addr: ip.bigEndian)
        return sa
    }

    /// A non-blocking socket; `connect` started (TCP) or done (UDP).
    static func connected(_ type: Int32, _ ip: UInt32, _ port: UInt16) -> Int32? {
        let fd = socket(AF_INET, type, 0)
        guard fd >= 0 else { return nil }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        if type == SOCK_STREAM { setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &on, socklen_t(MemoryLayout<Int32>.size)) }
        var sa = sockaddr4(ip, port)
        let r = withUnsafePointer(to: &sa) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard r == 0 || errno == EINPROGRESS else {
            close(fd)
            return nil
        }
        return fd
    }
}

/// One container TCP connection, terminated here and relayed to a socket on the Mac.
/// The guest sees an ordinary peer: the SYN-ACK goes out only once the Mac's connect
/// succeeds (so "connection refused" stays a refusal), flow control works both ways,
/// and lost segments are retransmitted.
final class TCPConn {
    enum State { case connecting, synAckSent, established, closed }

    let key: Uplink.FlowKey
    let port: NetPort
    unowned let uplink: Uplink
    var state = State.connecting

    private var fd: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var writeSource: DispatchSourceWrite?
    private var readSuspended = true
    private var writeSuspended = true

    private let iss = UInt32.random(in: 0...UInt32.max)
    private var sndUna: UInt32
    private var sndNxt: UInt32
    private var rcvNxt: UInt32
    private var unacked: [UInt8] = []  // bytes from sndUna
    private var guestWindow: UInt32
    private let guestScale: UInt8
    private let ourScale: UInt8
    private let mss: Int
    private var toHost: [UInt8] = []
    private var guestFin = false
    private var hostEOF = false
    private var finSent = false
    private var rto: TimeInterval = 0.3
    private var lastProgress = Date()
    private var retries = 0
    private var lastActivity = Date()
    private let started = Date()

    static let receiveCapacity = 1 << 20

    init(key: Uplink.FlowKey, port: NetPort, syn: TCPSegment, uplink: Uplink) {
        self.key = key
        self.port = port
        self.uplink = uplink
        rcvNxt = syn.seq &+ 1
        sndUna = iss
        sndNxt = iss
        guestScale = syn.windowScale ?? 0
        ourScale = syn.windowScale == nil ? 0 : 5  // 1 MiB / 32 fits the 16-bit field
        mss = Int(min(syn.mss ?? 536, 1460))
        guestWindow = UInt32(syn.window)  // a SYN's window is never scaled
    }

    func connect(_ target: UInt32) {
        guard let fd = Uplink.connected(SOCK_STREAM, target, key.dstPort) else { return refuse() }
        self.fd = fd
        let w = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: uplink.queue)
        w.setEventHandler { [weak self] in self?.writable() }
        writeSource = w
        writeSuspended = false
        w.resume()
        let r = DispatchSource.makeReadSource(fileDescriptor: fd, queue: uplink.queue)
        r.setEventHandler { [weak self] in self?.readable() }
        r.setCancelHandler { Darwin.close(fd) }
        readSource = r  // resumed once established
    }

    private var window: UInt16 {
        let free = max(Self.receiveCapacity - toHost.count, 0) >> Int(ourScale)
        return UInt16(min(free, 65535))
    }

    private func seg(_ flags: UInt8, seq: UInt32? = nil, payload: [UInt8] = []) -> TCPSegment {
        TCPSegment(srcPort: key.dstPort, dstPort: key.srcPort, seq: seq ?? sndNxt, ack: rcvNxt,
                   flags: flags, window: window, payload: payload)
    }

    // MARK: Host side

    private func writable() {
        if state == .connecting {
            var err: Int32 = 0
            var len = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
            guard err == 0 else { return refuse() }
            pauseWrites()
            state = .synAckSent
            sndNxt = iss &+ 1
            synAck()
            return
        }
        flushToHost()
    }

    private func synAck() {
        var s = TCPSegment(srcPort: key.dstPort, dstPort: key.srcPort, seq: iss, ack: rcvNxt,
                           flags: TCPSegment.syn | TCPSegment.ack, window: UInt16(min(Self.receiveCapacity, 65535)))
        s.mss = 1460
        if guestScale > 0 || ourScale > 0 { s.windowScale = ourScale }
        uplink.send(s, for: self)
        lastProgress = Date()
    }

    private func readable() {
        let inFlight = Int(sndNxt &- sndUna) - (finSent ? 1 : 0)
        let room = Int(guestWindow) - inFlight
        guard room > 0 else { return pauseReads() }
        var buf = [UInt8](repeating: 0, count: min(room, 256 * 1024))
        let n = read(fd, &buf, buf.count)
        if n > 0 {
            sendData(Array(buf[0..<n]))
        } else if n == 0 {
            hostEOF = true
            pauseReads()
            if !finSent {
                uplink.send(seg(TCPSegment.fin | TCPSegment.ack), for: self)
                sndNxt = sndNxt &+ 1
                finSent = true
            }
        } else if errno != EAGAIN && errno != EINTR {
            close(reset: true)
        }
    }

    private func sendData(_ data: [UInt8]) {
        if unacked.isEmpty { lastProgress = Date() }
        unacked += data
        var i = 0
        while i < data.count {
            let chunk = Array(data[i..<min(i + mss, data.count)])
            i += chunk.count
            uplink.send(seg(TCPSegment.ack | (i == data.count ? TCPSegment.psh : 0), payload: chunk), for: self)
            sndNxt = sndNxt &+ UInt32(chunk.count)
        }
    }

    private func flushToHost() {
        let wasFull = toHost.count >= Self.receiveCapacity / 2
        while !toHost.isEmpty {
            let n = toHost.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            if n > 0 {
                toHost.removeFirst(n)
            } else if n < 0 && (errno == EAGAIN || errno == EINTR) {
                resumeWrites()
                return
            } else {
                return close(reset: true)
            }
        }
        pauseWrites()
        if guestFin { shutdown(fd, SHUT_WR) }
        if wasFull { uplink.send(seg(TCPSegment.ack), for: self) }  // window update
    }

    // MARK: Guest side

    func segment(_ s: TCPSegment) {
        lastActivity = Date()
        if s.has(TCPSegment.rst) { return close(reset: false) }
        if s.has(TCPSegment.syn) {
            if state == .synAckSent { synAck() }  // our SYN-ACK was lost
            return
        }
        guard state != .connecting else { return }
        if s.has(TCPSegment.ack) {
            if state == .synAckSent && s.ack == iss &+ 1 {
                state = .established
                sndUna = s.ack
                resumeReads()
            } else if seqLT(sndUna, s.ack) && seqLE(s.ack, sndNxt) {
                let acked = Int(s.ack &- sndUna)
                unacked.removeFirst(min(acked, unacked.count))
                sndUna = s.ack
                lastProgress = Date()
                retries = 0
                rto = 0.3
            }
            guestWindow = UInt32(s.window) << UInt32(guestScale)
            if !hostEOF && state == .established { resumeReads() }
        }
        guard state == .established else { return }
        if !s.payload.isEmpty {
            if s.seq == rcvNxt && toHost.count + s.payload.count <= Self.receiveCapacity {
                toHost += s.payload
                rcvNxt = rcvNxt &+ UInt32(s.payload.count)
                flushToHost()
            }
            uplink.send(seg(TCPSegment.ack), for: self)  // ack, or a duplicate ack for out-of-order data
        }
        if s.has(TCPSegment.fin) && s.seq &+ UInt32(s.payload.count) == rcvNxt && !guestFin {
            rcvNxt = rcvNxt &+ 1
            guestFin = true
            uplink.send(seg(TCPSegment.ack), for: self)
            if toHost.isEmpty { shutdown(fd, SHUT_WR) }
        }
        if guestFin && finSent && sndUna == sndNxt { close(reset: false) }
    }

    func tick(_ now: Date) {
        switch state {
        case .connecting:
            if now.timeIntervalSince(started) > 30 { refuse() }
        case .synAckSent:
            if now.timeIntervalSince(lastProgress) > rto { retransmit(now) }
        case .established:
            if sndUna != sndNxt && now.timeIntervalSince(lastProgress) > rto { retransmit(now) }
            if now.timeIntervalSince(lastActivity) > 2 * 3600 { close(reset: true) }  // abandoned
        case .closed:
            break
        }
    }

    /// Go-back-N from the oldest unacknowledged byte, with exponential backoff.
    private func retransmit(_ now: Date) {
        retries += 1
        guard retries <= 12 else { return close(reset: true) }
        rto = min(rto * 2, 5)
        lastProgress = now
        if state == .synAckSent { return synAck() }
        var seq = sndUna
        var i = 0
        let limit = min(unacked.count, max(Int(guestWindow), mss))
        while i < limit {
            let chunk = Array(unacked[i..<min(i + mss, limit)])
            uplink.send(seg(TCPSegment.ack, seq: seq, payload: chunk), for: self)
            seq = seq &+ UInt32(chunk.count)
            i += chunk.count
        }
        if finSent && i == unacked.count { uplink.send(seg(TCPSegment.fin | TCPSegment.ack, seq: seq), for: self) }
    }

    private func refuse() {
        uplink.send(TCPSegment(srcPort: key.dstPort, dstPort: key.srcPort, seq: 0, ack: rcvNxt,
                               flags: TCPSegment.rst | TCPSegment.ack, window: 0), for: self)
        close(reset: false)
        uplink.remove(self)
    }

    func close(reset: Bool) {
        guard state != .closed else { return }
        if reset && state != .connecting { uplink.send(seg(TCPSegment.rst | TCPSegment.ack), for: self) }
        state = .closed
        if let w = writeSource {
            if writeSuspended { w.resume() }
            w.cancel()
        }
        if let r = readSource {
            if readSuspended { r.resume() }
            r.cancel()  // closes the socket
        } else if fd >= 0 {
            Darwin.close(fd)
        }
        readSource = nil
        writeSource = nil
    }

    private func pauseReads() {
        if !readSuspended, let r = readSource { r.suspend(); readSuspended = true }
    }

    private func resumeReads() {
        if readSuspended, let r = readSource, !hostEOF { r.resume(); readSuspended = false }
    }

    private func pauseWrites() {
        if !writeSuspended, let w = writeSource { w.suspend(); writeSuspended = true }
    }

    private func resumeWrites() {
        if writeSuspended, let w = writeSource { w.resume(); writeSuspended = false }
    }
}
