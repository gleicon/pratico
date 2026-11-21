import Foundation
import PraticoCore

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
    /// Flows whose first packet waits for an ask-mode answer; later packets are dropped.
    private var held: Set<FlowKey> = []
    private var pings: [String: Int] = [:]  // by NIC
    private var timer: DispatchSourceTimer?
    private var listeners: [String: [Listener]] = [:]  // by container ID
    private var inboundUDP: [FlowKey: InboundUDP] = [:]  // container → client replies

    // Each flow holds a socket: bounded per NIC and overall, well under the descriptor
    // limit the daemon raises at start (`Uplink.raiseDescriptorLimit`).
    static let maxFlowsPerNIC = 256
    static let maxFlows = 4096
    static let udpIdle: TimeInterval = 60
    static let maxPingsPerNIC = 16

    /// launchd agents start with a soft limit of 256 descriptors.
    static func raiseDescriptorLimit() {
        var lim = rlimit()
        #if canImport(Darwin)
        guard getrlimit(RLIMIT_NOFILE, &lim) == 0 else { return }
        lim.rlim_cur = min(lim.rlim_max, rlim_t(OPEN_MAX))  // macOS refuses more than OPEN_MAX
        setrlimit(RLIMIT_NOFILE, &lim)
        #else
        let resource = __rlimit_resource_t(RLIMIT_NOFILE.rawValue)
        guard getrlimit(resource, &lim) == 0 else { return }
        lim.rlim_cur = lim.rlim_max
        setrlimit(resource, &lim)
        #endif
    }

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

    /// Whether a NIC may open one more flow.
    private func admits(_ path: String) -> Bool {
        guard udp.count + tcp.count + inboundUDP.count < Self.maxFlows else { return false }
        return udp.keys.filter { $0.path == path }.count + tcp.keys.filter { $0.path == path }.count
            + inboundUDP.keys.filter { $0.path == path }.count < Self.maxFlowsPerNIC
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
        if let back = inboundUDP[key] {  // a reply to a published UDP port's client
            guard back.listener.live else { inboundUDP[key] = nil; return }
            back.last = Date()
            var to = back.client
            _ = d.payload.withUnsafeBytes { buf in
                withUnsafePointer(to: &to) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(back.listener.fd, buf.baseAddress, buf.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
            return
        }
        if udp[key] == nil {
            guard admits(port.path),
                egressAllows(key, port, target: target, dnsQuery: d.dstPort == 53 ? DNSQuery(d.payload) : nil, again: { [self] in udpOut(ip, port, target) }),
                let fd = Self.connected(Posix.datagram, target, d.dstPort)
            else { return }
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
        // Each query to an outside DNS server, not only a flow's first: a later one could ask
        // for a listed name, or carry data out in names (DNS tunnelling).
        if d.dstPort == 53, let q = DNSQuery(d.payload) {
            switch sw.egress.checkName(port.containerId, q.name) {
            case .allow: break
            case .block(let why):
                sw.egress.record(port.containerId, .init(time: Date(), proto: "dns", ip: key.dstIP, port: 53, sourcePort: key.srcPort, name: q.name, blocked: true, reason: why))
                return
            case .ask(let host):
                hold(host, key, port, proto: "dns", name: q.name, again: { [self] in udpOut(ip, port, target) })
                return
            }
        }
        flow.last = Date()
        _ = d.payload.withUnsafeBytes { Posix.send(flow.fd, $0.baseAddress, $0.count) }
    }

    // MARK: ICMP echo (unprivileged ICMP datagram sockets)

    private func ping(_ ip: IPv4Packet, _ port: NetPort, _ target: UInt32) {
        let p = ip.payload
        guard p.count >= 8, p[0] == 8, pings[port.path, default: 0] < Self.maxPingsPerNIC else { return }
        // ICMP carries data too: the guard sees each echo, as it sees each flow.
        let key = FlowKey(path: port.path, srcIP: ip.src, srcPort: 0, dstIP: ip.dst, dstPort: 0)
        guard egressAllows(key, port, target: target, dnsQuery: nil, proto: "icmp", again: { [self] in ping(ip, port, target) }) else { return }
        let fd = socket(AF_INET, Posix.datagram, Posix.icmp)
        guard fd >= 0 else { return }
        var sa = Self.sockaddr4(target, 0)
        let sent = withUnsafePointer(to: &sa) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, p, p.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard sent == p.count else { close(fd); return }
        pings[port.path, default: 0] += 1
        // Used only on `queue`, the uplink's serial queue.
        nonisolated(unsafe) let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        let done = Box(false)
        let finish: @Sendable () -> Void = { [weak self] in
            guard !done.value else { return }
            done.value = true
            source.cancel()
            self?.pings[port.path, default: 1] -= 1
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
        if let conn = tcp[key] {  // also replies on published-port connections (dst = gateway)
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
        guard admits(port.path) else { return }
        let reset: @Sendable () -> Void = { [sw] in
            let rst = TCPSegment(srcPort: seg.dstPort, dstPort: seg.srcPort, seq: 0, ack: seg.seq &+ 1, flags: TCPSegment.rst | TCPSegment.ack, window: 0)
            sw.deliver(to: port, src: ip.dst, proto: 6, rst.bytes(src: ip.dst, dst: ip.src))
        }
        // Held in ask mode: the SYN is handled again once answered (the guest's own
        // retransmissions join the same question), or the guest is reset.
        guard egressAllows(key, port, target: target, dnsQuery: nil, tcp: true, again: { [self] in tcpIn(ip, port, target) }, refused: reset) else {
            if !isHeld(key) { reset() }
            return
        }
        let conn = TCPConn(key: key, port: port, syn: seg, uplink: self)
        tcp[key] = conn
        conn.connect(target)
    }

    fileprivate func remove(_ conn: TCPConn) { tcp[conn.key] = nil }

    /// A new flow's destination against the egress guard (D-51): refused ones are recorded
    /// here; a TCP flow it allows is recorded by its connection, once its first bytes name
    /// it. A query to an outside DNS server is checked by the name it asks for.
    private func egressAllows(_ key: FlowKey, _ port: NetPort, target: UInt32, dnsQuery: DNSQuery?, tcp: Bool = false, proto: String = "udp",
                              again: @escaping @Sendable () -> Void, refused: @escaping @Sendable () -> Void = {}) -> Bool {
        let guardian = sw.egress
        let isMac = target == IPv4.parse("127.0.0.1")
        var verdict = guardian.checkAddress(port.containerId, key.dstIP, port: key.dstPort, isMac: isMac)
        if verdict == .allow, let q = dnsQuery, !isMac { verdict = guardian.checkName(port.containerId, q.name) }
        let name = dnsQuery?.name ?? guardian.name(port.containerId, key.dstIP)
        if case .ask(let destination) = verdict {
            hold(destination, key, port, proto: tcp ? "tcp" : proto, name: name, again: again, refused: refused)
            return false
        }
        if case .block(let why) = verdict {
            guardian.record(port.containerId, .init(time: Date(), proto: tcp ? "tcp" : proto, ip: key.dstIP, port: key.dstPort, sourcePort: key.srcPort, name: name, blocked: true, reason: why))
            return false
        }
        if !tcp { guardian.record(port.containerId, .init(time: Date(), proto: proto, ip: key.dstIP, port: key.dstPort, sourcePort: key.srcPort, name: name, blocked: false, reason: nil)) }
        return true
    }

    /// Ask mode: the packet waits for the answer to `destination`'s question. Allowed, it
    /// is handled again (the answer now stands); refused, the flow is recorded so and
    /// `refused` runs. Later packets of the flow (retransmissions) are dropped meanwhile.
    private func hold(_ destination: String, _ key: FlowKey, _ port: NetPort, proto: String, name: String?,
                      again: @escaping @Sendable () -> Void, refused: @escaping @Sendable () -> Void = {}) {
        guard !held.contains(key) else { return }
        guard held.count < Self.maxFlows else {
            // Not held: the caller refuses it as it refuses a block.
            return sw.egress.record(port.containerId, .init(time: Date(), proto: proto, ip: key.dstIP, port: key.dstPort, sourcePort: key.srcPort, name: name, blocked: true, reason: "too many flows waiting for an answer"))
        }
        held.insert(key)
        sw.egress.questions.ask(port.containerId, destination, port: key.dstPort) { [weak self] outcome in
            self?.queue.async { [weak self] in
                guard let self else { return }
                held.remove(key)
                switch outcome {
                case .allowed: again()
                case .refused(let why):
                    sw.egress.record(port.containerId, .init(time: Date(), proto: proto, ip: key.dstIP, port: key.dstPort, sourcePort: key.srcPort, name: name, blocked: true, reason: why))
                    refused()
                }
            }
        }
    }

    private func isHeld(_ key: FlowKey) -> Bool { held.contains(key) }

    private func tick() {
        let now = Date()
        for (k, f) in inboundUDP where now.timeIntervalSince(f.last) > Self.udpIdle { inboundUDP[k] = nil }
        for (k, f) in udp where now.timeIntervalSince(f.last) > Self.udpIdle {
            f.source.cancel()
            udp[k] = nil
        }
        for (k, c) in tcp {
            c.tick(now)
            if c.state == .closed { tcp[k] = nil }
        }
    }

    /// Everything a card had open goes when the container stops; with `ip`, only what that
    /// endpoint had (a network disconnected while the card's other networks stay).
    func drop(path: String, ip: UInt32? = nil) {
        queue.async { [self] in
            let mine = { (k: FlowKey) in k.path == path && (ip == nil || k.srcIP == ip) }
            for (k, f) in udp where mine(k) {
                f.source.cancel()
                udp[k] = nil
            }
            for (k, c) in tcp where mine(k) {
                c.close(reset: false)
                tcp[k] = nil
            }
            inboundUDP = inboundUDP.filter { !mine($0.key) }
        }
    }

    // MARK: Published ports

    final class Listener {
        let fd: Int32
        let source: DispatchSourceRead
        var live = true  // false once cancelled: its fd number may belong to another socket
        /// Where new connections go: the container's primary NIC, which hot disconnect can move.
        var nic: NetPort
        var gateway: UInt32
        init(fd: Int32, source: DispatchSourceRead, nic: NetPort, gateway: UInt32) {
            self.fd = fd
            self.source = source
            self.nic = nic
            self.gateway = gateway
        }
    }

    final class InboundUDP {
        let listener: Listener
        let client: sockaddr_in
        var last = Date()
        init(listener: Listener, client: sockaddr_in) {
            self.listener = listener
            self.client = client
        }
    }

    /// One published port. Binds now, so a taken port fails the container's start, as
    /// Docker does; returns the bound host port (`hostPort` 0 picks a free one).
    func publish(container id: String, nic: NetPort, gateway: UInt32, hostIP: UInt32, hostPort: UInt16,
                 containerPort: UInt16, udp isUDP: Bool) throws -> UInt16
    {
        try queue.sync {
            let fd = socket(AF_INET, isUDP ? Posix.datagram : Posix.stream, 0)
            guard fd >= 0 else { throw APIError(500, "cannot open a socket for port \(hostPort)") }
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            var sa = Self.sockaddr4(hostIP, hostPort)
            let bound = withUnsafePointer(to: &sa) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            guard bound == 0, isUDP || listen(fd, 128) == 0 else {
                let reason = errno == EADDRINUSE ? "port is already allocated" : String(cString: strerror(errno))
                close(fd)
                throw APIError(500, "Bind for \(IPv4.format(hostIP)):\(hostPort) failed: \(reason)")
            }
            var actual = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            _ = withUnsafeMutablePointer(to: &actual) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
            }
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            let listener = Listener(fd: fd, source: source, nic: nic, gateway: gateway)
            source.setEventHandler { [weak self, unowned listener] in
                guard let self, listener.live else { return }
                if isUDP {
                    self.inboundDatagram(listener, containerPort: containerPort)
                } else {
                    self.accept(listener, containerPort: containerPort)
                }
            }
            source.setCancelHandler { close(fd) }
            source.resume()
            listeners[id, default: []].append(listener)
            return UInt16(bigEndian: actual.sin_port)
        }
    }

    /// The container's published ports now lead to `nic` (its new primary NIC). The host
    /// listeners stay bound, so no other process can take the ports meanwhile.
    func retarget(container id: String, nic: NetPort, gateway: UInt32) {
        queue.sync {
            for l in listeners[id] ?? [] {
                l.nic = nic
                l.gateway = gateway
            }
        }
    }

    func unpublish(container id: String) {
        queue.async { [self] in
            let gone = listeners.removeValue(forKey: id) ?? []
            for l in gone {
                l.live = false
                l.source.cancel()
            }
            inboundUDP = inboundUDP.filter { _, f in !gone.contains { $0 === f.listener } }
        }
    }

    private func ephemeral(_ path: String) -> UInt16 {
        while true {
            let p = UInt16.random(in: 32768...60999)
            if !tcp.keys.contains(where: { $0.path == path && $0.dstPort == p })
                && !inboundUDP.keys.contains(where: { $0.path == path && $0.dstPort == p })
            { return p }
        }
    }

    private func accept(_ l: Listener, containerPort: UInt16) {
        let nic = l.nic, gateway = l.gateway
        while true {
            let fd = Posix.accept(l.fd)
            guard fd >= 0 else { return }
            guard admits(nic.path) else { close(fd); continue }
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            var on: Int32 = 1
            Posix.noSigpipe(fd)
            setsockopt(fd, Posix.tcp, Int32(TCP_NODELAY), &on, socklen_t(MemoryLayout<Int32>.size))
            let key = FlowKey(path: nic.path, srcIP: nic.ip, srcPort: containerPort, dstIP: gateway, dstPort: ephemeral(nic.path))
            tcp[key] = TCPConn(inbound: key, port: nic, fd: fd, uplink: self)
        }
    }

    private func inboundDatagram(_ l: Listener, containerPort: UInt16) {
        let listener = l.fd, nic = l.nic, gateway = l.gateway
        var buf = [UInt8](repeating: 0, count: 65535)
        var client = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let n = withUnsafeMutablePointer(to: &client) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(listener, &buf, buf.count, 0, $0, &len) }
        }
        guard n > 0 else { return }
        let existing = inboundUDP.first {
            $0.key.path == nic.path && $0.value.listener === l
                && $0.value.client.sin_addr.s_addr == client.sin_addr.s_addr && $0.value.client.sin_port == client.sin_port
        }
        let key: FlowKey
        if let existing {
            key = existing.key
            existing.value.last = Date()
        } else {
            guard admits(nic.path) else { return }
            key = FlowKey(path: nic.path, srcIP: nic.ip, srcPort: containerPort, dstIP: gateway, dstPort: ephemeral(nic.path))
            inboundUDP[key] = InboundUDP(listener: l, client: client)
        }
        let d = UDPDatagram(srcPort: key.dstPort, dstPort: containerPort, payload: Array(buf[0..<n]))
        sw.deliver(to: nic, src: gateway, proto: 17, d.bytes(src: gateway, dst: nic.ip))
    }

    fileprivate func send(_ seg: TCPSegment, for conn: TCPConn) {
        sw.deliver(to: conn.port, src: conn.key.dstIP, proto: 6, seg.bytes(src: conn.key.dstIP, dst: conn.key.srcIP))
    }

    // MARK: Sockets

    static func sockaddr4(_ ip: UInt32, _ port: UInt16) -> sockaddr_in {
        var sa = sockaddr_in()
        #if canImport(Darwin)
        sa.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
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
        Posix.noSigpipe(fd)
        if type == Posix.stream { setsockopt(fd, Posix.tcp, Int32(TCP_NODELAY), &on, socklen_t(MemoryLayout<Int32>.size)) }
        var sa = sockaddr4(ip, port)
        let r = withUnsafePointer(to: &sa) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Posix.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
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
    enum State { case connecting, synSent, synAckSent, established, closed }

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
    private var guestScale: UInt8
    private var ourScale: UInt8
    private var mss: Int
    private var toHost: [UInt8] = []
    private var guestFin = false
    private var hostEOF = false
    private var finSent = false
    private var rto: TimeInterval = 0.3
    private var lastProgress = Date()
    private var retries = 0
    private var lastActivity = Date()
    private let started = Date()
    /// A connection the container opened holds its first bytes until they name it (SNI,
    /// Host) and the egress guard has its say (D-51); published ports' are not inspected.
    private var inspecting = true
    /// Ask mode: the first bytes named a host nobody has allowed yet; they wait for the answer.
    private var awaiting = false
    /// Plain HTTP from a container with an allowlist: every later request on the connection
    /// (keep-alive) is checked as the first was. `tail` holds the end of the last segment,
    /// so a header split across two is still seen.
    private var watchHTTP = false
    private var http = HTTPStream()

    static let receiveCapacity = 1 << 20
    /// Bytes in flight to the guest, whatever window it advertises.
    static let sendCapacity = 4 << 20

    /// The guest picks its MSS: 0 or tiny values would loop or flood, so 64…1460.
    static func clampMSS(_ v: UInt16?) -> Int {
        guard let v, v > 0 else { return 536 }
        return Int(min(max(v, 64), 1460))
    }

    init(key: Uplink.FlowKey, port: NetPort, syn: TCPSegment, uplink: Uplink) {
        self.key = key
        self.port = port
        self.uplink = uplink
        rcvNxt = syn.seq &+ 1
        sndUna = iss
        sndNxt = iss
        guestScale = syn.windowScale ?? 0
        ourScale = syn.windowScale == nil ? 0 : 5  // 1 MiB / 32 fits the 16-bit field
        mss = Self.clampMSS(syn.mss)
        guestWindow = UInt32(syn.window)  // a SYN's window is never scaled
    }

    /// A published port: `fd` is the accepted client; pratico opens the connection to the
    /// container from the gateway (`key.dstIP:key.dstPort`).
    init(inbound key: Uplink.FlowKey, port: NetPort, fd: Int32, uplink: Uplink) {
        self.key = key
        self.port = port
        self.uplink = uplink
        self.fd = fd
        inspecting = false
        rcvNxt = 0
        sndUna = iss
        sndNxt = iss &+ 1
        guestScale = 0
        ourScale = 5
        mss = 536
        guestWindow = 0
        state = .synSent
        let r = DispatchSource.makeReadSource(fileDescriptor: fd, queue: uplink.queue)
        r.setEventHandler { [weak self] in self?.readable() }
        r.setCancelHandler { Posix.close(fd) }
        readSource = r  // resumed once established
        let w = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: uplink.queue)
        w.setEventHandler { [weak self] in self?.writable() }
        writeSource = w  // suspended until there is data the client cannot take yet
        syn()
    }

    private func syn() {
        let s = TCPSegment(srcPort: key.dstPort, dstPort: key.srcPort, seq: iss, ack: 0, flags: TCPSegment.syn,
                           window: 65535, mss: 1460, windowScale: ourScale)
        uplink.send(s, for: self)
        lastProgress = Date()
    }

    func connect(_ target: UInt32) {
        guard let fd = Uplink.connected(Posix.stream, target, key.dstPort) else { return refuse() }
        self.fd = fd
        let w = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: uplink.queue)
        w.setEventHandler { [weak self] in self?.writable() }
        writeSource = w
        writeSuspended = false
        w.resume()
        let r = DispatchSource.makeReadSource(fileDescriptor: fd, queue: uplink.queue)
        r.setEventHandler { [weak self] in self?.readable() }
        r.setCancelHandler { Posix.close(fd) }
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
        let room = min(Int(guestWindow), Self.sendCapacity) - inFlight
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
        precondition(mss > 0)
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
        if guestFin { shutdown(fd, Posix.shutWrite) }
        if wasFull { uplink.send(seg(TCPSegment.ack), for: self) }  // window update
    }

    /// The first bytes' verdict: true once they may go on to the host. Until then they
    /// wait in `toHost`; a refused connection is reset and nothing reaches the host.
    private func inspect(final: Bool = false) -> Bool {
        guard !awaiting else { return false }
        let guardian = uplink.sw.egress
        let container = port.containerId
        let resolved = guardian.name(container, key.dstIP)
        var carried: String?
        var unnamed = false
        switch FirstBytes.inspect(toHost) {
        case .needMore where toHost.count < FirstBytes.maxInspect && !final: return false
        case .name(let n): carried = n
        case .unnamed, .needMore: unnamed = true
        case .none: break
        }
        inspecting = false
        var verdict = carried.map { guardian.checkCarried(container, $0) } ?? .allow
        // With an allowlist, TLS or HTTP that names nothing readable (a ClientHello split
        // across records, no SNI, two Host headers) is refused: the address alone could be a
        // CDN's, shared with sites the list does not name (domain fronting).
        if unnamed, guardian.hasAllowlist(container) {
            verdict = .block("TLS or HTTP to \(resolved ?? IPv4.format(key.dstIP)) without a name pratico can read; this container's egress allowlist needs one")
        }
        if case .ask(let host) = verdict {
            awaiting = true
            // The connection lives on the uplink's queue: the answer goes back there.
            let me = Weak(self), queue = uplink.queue, name = carried
            guardian.questions.ask(container, host, port: key.dstPort) { outcome in
                queue.async { me.value?.answered(outcome, carried: name) }
            }
            return false
        }
        if case .block(let why) = verdict {
            refuse(why, name: carried)
            return false
        }
        return admit(carried: carried, resolved: resolved)
    }

    /// The answer to the question the first bytes raised: they go on, or the connection is reset.
    private func answered(_ outcome: EgressQuestions.Outcome, carried: String?) {
        guard awaiting, state != .closed else { return }
        awaiting = false
        if case .refused(let why) = outcome { return refuse(why, name: carried) }
        if let carried, case .block(let why) = uplink.sw.egress.checkCarried(port.containerId, carried) { return refuse(why, name: carried) }
        if admit(carried: carried, resolved: uplink.sw.egress.name(port.containerId, key.dstIP)) { flushToHost() }
    }

    private func refuse(_ why: String, name: String?) {
        uplink.sw.egress.record(port.containerId, .init(time: Date(), proto: "tcp", ip: key.dstIP, port: key.dstPort, sourcePort: key.srcPort, name: name, blocked: true, reason: why))
        toHost.removeAll()
        close(reset: true)
    }

    /// The first bytes may go: the flow is recorded, and with an allowlist plain HTTP is
    /// watched for later requests.
    private func admit(carried: String?, resolved: String?) -> Bool {
        let guardian = uplink.sw.egress
        let container = port.containerId
        guardian.record(container, .init(time: Date(), proto: "tcp", ip: key.dstIP, port: key.dstPort, sourcePort: key.srcPort, name: carried ?? resolved, blocked: false, reason: nil))
        watchHTTP = carried != nil && toHost.first != 0x16 && guardian.hasAllowlist(container)
        // Requests pipelined behind the first, in these same bytes, are checked before any goes.
        if watchHTTP {
            http = HTTPStream()
            return keepAliveAllowed(toHost)
        }
        return true
    }

    /// A later request's hosts on a plain-HTTP connection with an allowlist; false (and the
    /// connection reset) when one is not on it.
    private func keepAliveAllowed(_ payload: [UInt8]) -> Bool {
        let guardian = uplink.sw.egress
        let hosts = http.feed(payload)
        for host in hosts ?? ["(unreadable)"] {
            var verdict = guardian.checkCarried(port.containerId, host)
            // Ask mode: a new host mid-connection is not held; a new connection asks.
            if case .ask(let h) = verdict { verdict = .block("\(h) on a kept-alive connection to another host; ask mode asks on a new connection") }
            if hosts == nil { verdict = .block("an HTTP line pratico cannot read (folded, or past \(FirstBytes.maxLine) bytes); this container's egress allowlist needs every request named") }
            guard case .block(let why) = verdict else { continue }
            guardian.record(port.containerId, .init(time: Date(), proto: "tcp", ip: key.dstIP, port: key.dstPort, sourcePort: key.srcPort, name: host, blocked: true, reason: why))
            toHost.removeAll()
            close(reset: true)
            return false
        }
        return true
    }

    // MARK: Guest side

    func segment(_ s: TCPSegment) {
        lastActivity = Date()
        if s.has(TCPSegment.rst) { return close(reset: false) }
        if state == .synSent {
            guard s.has(TCPSegment.syn), s.has(TCPSegment.ack), s.ack == iss &+ 1 else { return }
            rcvNxt = s.seq &+ 1
            guestScale = s.windowScale ?? 0
            if s.windowScale == nil { ourScale = 0 }  // scaling only when both sides offer it
            mss = Self.clampMSS(s.mss)
            guestWindow = UInt32(s.window)
            sndUna = s.ack
            state = .established
            uplink.send(seg(TCPSegment.ack), for: self)
            resumeReads()
            return
        }
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
                if watchHTTP && !keepAliveAllowed(s.payload) { return }
                if !inspecting || inspect() { flushToHost() }
                if state == .closed { return }
            }
            uplink.send(seg(TCPSegment.ack), for: self)  // ack, or a duplicate ack for out-of-order data
        }
        if s.has(TCPSegment.fin) && s.seq &+ UInt32(s.payload.count) == rcvNxt && !guestFin {
            rcvNxt = rcvNxt &+ 1
            guestFin = true
            uplink.send(seg(TCPSegment.ack), for: self)
            // A client that stops before its first bytes name it: decide on what came.
            if inspecting {
                guard inspect(final: true) else { return }
                flushToHost()
            }
            if toHost.isEmpty { shutdown(fd, Posix.shutWrite) }
        }
        if guestFin && finSent && sndUna == sndNxt { close(reset: false) }
    }

    func tick(_ now: Date) {
        switch state {
        case .connecting:
            if now.timeIntervalSince(started) > 30 { refuse() }
        case .synAckSent, .synSent:
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
        if state == .synSent { return retries > 6 ? close(reset: false) : syn() }
        var seq = sndUna
        var i = 0
        let limit = min(unacked.count, max(min(Int(guestWindow), Self.sendCapacity), mss))
        precondition(mss > 0)
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
        if inspecting && state == .established {  // closed before sending anything: still a flow
            inspecting = false
            let g = uplink.sw.egress
            g.record(port.containerId, .init(time: Date(), proto: "tcp", ip: key.dstIP, port: key.dstPort, sourcePort: key.srcPort,
                                              name: g.name(port.containerId, key.dstIP), blocked: false, reason: nil))
        }
        if reset && state != .connecting && state != .synSent { uplink.send(seg(TCPSegment.rst | TCPSegment.ack), for: self) }
        state = .closed
        if let w = writeSource {
            if writeSuspended { w.resume() }
            w.cancel()
        }
        if let r = readSource {
            if readSuspended { r.resume() }
            r.cancel()  // closes the socket
        } else if fd >= 0 {
            Posix.close(fd)
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

/// A weak reference handed across queues; read only on the queue that owns the object.
private struct Weak<T: AnyObject>: @unchecked Sendable {
    weak var value: T?
    init(_ value: T) { self.value = value }
}
