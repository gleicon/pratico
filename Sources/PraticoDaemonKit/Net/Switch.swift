import Foundation

/// One endpoint of a running container: its address on one network, on the card whose
/// frames the shim relays over the datagram socket bound at `path`. Endpoints on one card
/// share the path (D-43); the switch tells them apart by their address.
struct NetPort: Sendable, Equatable {
    var path: String
    var containerId: String
    var networkId: String
    /// The endpoint's MAC as its network sees it, one per network as on Docker (D-44).
    var mac: MAC
    var ip: UInt32
    /// The guest card's own MAC, which every endpoint on the card sends from; the switch
    /// rewrites it to `mac` on the way out and back on the way in. Equal to `mac` for the
    /// card's first endpoint.
    var card: MAC
}

/// A network as the switch sees it: its gateway (pratico) and prefix.
struct NetSegment: Sendable {
    var gateway: UInt32
    var prefix: Int
    /// `docker network create --internal`: nothing leaves the network, not even DNS.
    var isInternal = false
    func contains(_ ip: UInt32) -> Bool { ip & IPv4.mask(prefix) == gateway & IPv4.mask(prefix) }
}

/// pratico-net's user-space switch (SPEC D-27). Each network is a broadcast domain; a
/// frame never crosses networks. A frame from a card belongs to the endpoint whose address
/// it is sent from, and goes only where that endpoint's network reaches: a container on two
/// networks cannot carry traffic between them, and may only send as its own MAC and
/// addresses (no spoofing, unlike a plain bridge). The gateway answers ARP, ping, and DNS.
///
/// It survives daemon restarts: shims send to `socketPath` connectionless, so a restarted
/// daemon rebinds it and traffic resumes once ports are registered again.
final class NetSwitch: @unchecked Sendable {
    let socketPath: String
    /// Names → addresses for the asker's networks; nil means "not a container name".
    var resolveName: (@Sendable (NetPort, String) -> [UInt32]?)?
    /// What containers reach beyond their networks, and whether they may (D-51); the
    /// daemon sets it up before the switch starts.
    var egress = EgressGuard(blockThreats: true)

    private var fd: Int32 = -1
    private let lock = NSLock()
    private var ports: [String: [NetPort]] = [:]  // by socket path: a card's endpoints
    private var segments: [String: NetSegment] = [:]  // by network ID
    private let lookups = DispatchSemaphore(value: 32)  // bounds concurrent host DNS lookups
    /// Made in `init`, never later: a `lazy var` is not thread-safe, and the first use can
    /// come from several threads at once (containers stopping together).
    private(set) var uplink: Uplink!
    static let maxFrame = 65536
    static let mtu = 1500

    init(socketPath: String) {
        self.socketPath = socketPath
        uplink = Uplink(switch: self)
    }

    func start() throws {
        unlink(socketPath)
        fd = socket(AF_UNIX, SOCK_DGRAM, 0)
        guard fd >= 0 else { throw APIError(500, "pratico-net: socket failed") }
        var size: Int32 = 4 << 20
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &size, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &size, socklen_t(MemoryLayout<Int32>.size))
        var addr = Self.address(socketPath)
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard ok == 0 else { throw APIError(500, "pratico-net: cannot bind \(socketPath): \(String(cString: strerror(errno)))") }
        chmod(socketPath, 0o600)
        Thread.detachNewThread { [self] in receiveLoop() }
    }

    // MARK: Registry

    func setSegment(_ networkId: String, _ s: NetSegment) {
        lock.lock()
        segments[networkId] = s
        lock.unlock()
    }

    /// Plugs an endpoint in, replacing the card's endpoint on the same network.
    func register(_ p: NetPort) {
        lock.lock()
        ports[p.path, default: []].removeAll { $0.networkId == p.networkId }
        ports[p.path, default: []].append(p)
        lock.unlock()
    }

    func unregister(container id: String) {
        lock.lock()
        let gone = ports.filter { $0.value.contains { $0.containerId == id } }.map(\.key)
        for path in gone { ports[path] = nil }
        lock.unlock()
        for path in gone { uplink.drop(path: path) }
    }

    /// The endpoint's frames are dropped from here on and its flows end; the card's other
    /// endpoints carry on.
    func unregister(path: String, networkId: String) {
        lock.lock()
        let gone = ports[path]?.filter { $0.networkId == networkId } ?? []
        ports[path]?.removeAll { $0.networkId == networkId }
        if ports[path]?.isEmpty == true { ports[path] = nil }
        lock.unlock()
        for p in gone { uplink.drop(path: path, ip: p.ip) }
    }

    /// The endpoint a frame from `path` speaks for: the one whose address it is sent from.
    private func endpoint(_ path: String, _ frame: [UInt8]) -> NetPort? {
        lock.lock()
        let card = ports[path] ?? []
        lock.unlock()
        guard let eth = Ethernet(frame) else { return nil }
        let source: UInt32?
        switch eth.type {
        case EtherType.arp.rawValue: source = ARP(eth.payload)?.senderIP
        case EtherType.ipv4.rawValue: source = IPv4Packet(eth.payload)?.src
        default: source = nil
        }
        guard let source else { return nil }
        return card.first { $0.ip == source }
    }

    // MARK: Forwarding

    private func receiveLoop() {
        var buf = [UInt8](repeating: 0, count: Self.maxFrame)
        while true {
            var from = sockaddr_un()
            var len = socklen_t(MemoryLayout<sockaddr_un>.size)
            let n = withUnsafeMutablePointer(to: &from) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buf, buf.count, 0, $0, &len) }
            }
            if n < 0 {
                if errno == EINTR { continue }
                return
            }
            let path = withUnsafeBytes(of: from.sun_path) { raw in
                String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
            }
            let frame = Array(buf[0..<n])
            // Unknown senders (not a pratico card) and addresses no endpoint holds are dropped.
            guard let port = endpoint(path, frame) else { continue }
            handle(frame, from: port)
        }
    }

    func handle(_ frame: [UInt8], from port: NetPort) {
        guard var eth = Ethernet(frame), eth.src == port.card else { return }  // spoofed MAC
        let frame = Self.rewrite(frame, from: port.card, to: port.mac, at: [6, Self.arpSender])
        eth.src = port.mac
        lock.lock()
        let segment = segments[port.networkId]
        lock.unlock()
        guard let segment else { return }
        switch eth.type {
        case EtherType.arp.rawValue:
            guard let arp = ARP(eth.payload), arp.senderMAC == port.card, arp.senderIP == port.ip else { return }
            if arp.op == 1 && arp.targetIP == segment.gateway {
                let reply = ARP(op: 2, senderMAC: .gateway, senderIP: segment.gateway, targetMAC: port.mac, targetIP: port.ip)
                send(Ethernet(dst: port.mac, src: .gateway, type: EtherType.arp.rawValue, payload: reply.bytes).bytes, to: port)
                return
            }
            forward(eth, frame, from: port) { $0.ip == arp.targetIP }
        case EtherType.ipv4.rawValue:
            guard let ip = IPv4Packet(eth.payload), ip.src == port.ip else { return }  // spoofed IP
            if eth.dst == .gateway {
                toGateway(ip, from: port, segment: segment)
            } else if eth.dst.isMulticast {
                // Broadcast and multicast for this network only: a directed broadcast to
                // another subnet would reach a peer's address on a network the sender is not on.
                guard segment.contains(ip.dst) || ip.dst >= 0xE000_0000 else { return }
                forward(eth, frame, from: port) { _ in true }
            } else {
                forward(eth, frame, from: port) { $0.ip == ip.dst }
            }
        default:
            return  // IPv6 and others are not routed yet
        }
    }

    /// Same-network delivery by destination MAC; broadcast and multicast flood the network.
    /// A VM's card carries an address per network (D-43), so the MAC alone does not say
    /// which network a frame is for: a peer gets it only when `addressedTo` holds for its
    /// endpoint on the sender's network, or a peer on n1 could reach its n2 address.
    private func forward(_ eth: Ethernet, _ frame: [UInt8], from port: NetPort,
                         addressedTo: (NetPort) -> Bool) {
        lock.lock()
        let peers = ports.values.joined().filter { $0.networkId == port.networkId && $0.path != port.path }
        lock.unlock()
        precondition(!port.networkId.isEmpty, "a frame from an unbound endpoint")
        for p in peers where (eth.dst.isMulticast || p.mac == eth.dst) && addressedTo(p) {
            send(frame, to: p)
        }
    }

    private func toGateway(_ ip: IPv4Packet, from port: NetPort, segment: NetSegment) {
        if ip.dst == segment.gateway && ip.proto == 1 {
            if let echo = icmpEchoReply(ip.payload) { reply(port, from: segment.gateway, proto: 1, echo) }
            return
        }
        lock.lock()
        let all = Array(segments.values)
        lock.unlock()
        // DNS at any pratico gateway is answered as the asker's network: a container keeps
        // the resolv.conf of its first network after hot-disconnecting from it.
        if ip.proto == 17, all.contains(where: { $0.gateway == ip.dst }), let udp = UDPDatagram(ip.payload), udp.dstPort == 53 {
            return dns(udp, from: port, segment: segment, server: ip.dst)
        }
        uplink.handle(ip, from: port, segment: segment, pratico: all)
    }

    // MARK: DNS

    /// `server` is the gateway address asked; the answer comes from it, or resolvers drop it.
    private func dns(_ udp: UDPDatagram, from port: NetPort, segment: NetSegment, server: UInt32) {
        guard let q = DNSQuery(udp.payload), q.qclass == 1 else { return }
        let respond: @Sendable ([UInt32]?) -> Void = { [self] addrs in
            let answer = UDPDatagram(srcPort: 53, dstPort: udp.srcPort, payload: q.answer(udp.payload, addresses: addrs))
            reply(port, from: server, proto: 17, answer.bytes(src: server, dst: port.ip))
        }
        if let local = resolveName?(port, q.name) {
            respond(q.qtype == 1 ? local : [])  // a container name has no AAAA/MX/…
            return
        }
        // Internal networks: no lookups on the Mac, which would let a container exfiltrate
        // through names it controls (Docker 26+ also stops forwarding there).
        guard !segment.isInternal else {
            respond(nil)
            return
        }
        let refuse: @Sendable (String) -> Void = { [self] why in
            egress.record(port.containerId, .init(time: Date(), proto: "dns", ip: server, port: 53, sourcePort: udp.srcPort, name: q.name, blocked: true, reason: why))
            respond(nil)  // no such name, as far as the container can tell
        }
        let resolve: @Sendable () -> Void = { [self] in
            guard q.qtype == 1 else {
                respond([])  // IPv6 and other types: no records yet (no IPv6 routing)
                return
            }
            // External names go through the Mac's resolver, so VPN and split DNS apply.
            guard lookups.wait(timeout: .now()) == .success else { return }  // busy: the client retries
            let name = q.name
            DispatchQueue.global().async { [self] in
                defer { lookups.signal() }
                let found = Self.hostLookup(name)
                if let found { egress.resolved(port.containerId, name, found) }  // names its connections
                respond(found)
            }
        }
        switch egress.checkName(port.containerId, q.name) {
        case .block(let why): refuse(why)
        case .allow: resolve()
        case .ask(let host):
            // Ask mode: the answer waits for the question's (the container's resolver waits
            // 30 s in ask mode), and nothing leaves the Mac for a name nobody allowed.
            egress.questions.ask(port.containerId, host, port: 53) { [egress] outcome in
                // Asked again after the answer: the feeds may have changed meanwhile.
                if case .refused(let why) = outcome { return refuse(why) }
                if case .block(let why) = egress.checkName(port.containerId, q.name) { return refuse(why) }
                resolve()
            }
        }
    }

    /// IPv4 addresses of `name` via getaddrinfo; nil for NXDOMAIN.
    static func hostLookup(_ name: String) -> [UInt32]? {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_STREAM
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(name, nil, &hints, &res) == 0 else { return nil }
        defer { freeaddrinfo(res) }
        var out: [UInt32] = []
        var cur = res
        while let a = cur?.pointee {
            if a.ai_family == AF_INET, let sa = a.ai_addr {
                let v = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
                if !out.contains(v) { out.append(v) }
            }
            cur = a.ai_next
        }
        return out
    }

    // MARK: Sending

    private func reply(_ port: NetPort, from src: UInt32, proto: UInt8, _ payload: [UInt8]) {
        deliver(to: port, src: src, proto: proto, payload)
    }

    /// An IPv4 packet from beyond the network to a container, fragmented to the MTU.
    func deliver(to port: NetPort, src: UInt32, proto: UInt8, _ payload: [UInt8]) {
        lock.lock()
        let plugged = ports[port.path]?.contains(port) == true
        lock.unlock()
        guard plugged else { return }  // unplugged (hot disconnect) or replugged elsewhere
        for packet in IPv4Packet.fragments(src: src, dst: port.ip, proto: proto, payload: payload, mtu: Self.mtu) {
            send(Ethernet(dst: port.mac, src: .gateway, type: EtherType.ipv4.rawValue, payload: packet).bytes, to: port)
        }
    }

    func send(_ frame: [UInt8], to port: NetPort) {
        let frame = Self.rewrite(frame, from: port.mac, to: port.card, at: [0, Self.arpTarget])
        var addr = Self.address(port.path)
        _ = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(fd, frame, frame.count, 0, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }

    /// Frame offsets of the ARP sender and target MACs (after the 14-byte Ethernet header).
    private static let arpSender = 22, arpTarget = 32

    /// Replaces the MAC `old` with `new` at each offset that holds it; ARP offsets only in
    /// an ARP frame. Translates between a card's MAC and its endpoints' (D-44).
    static func rewrite(_ frame: [UInt8], from old: MAC, to new: MAC, at offsets: [Int]) -> [UInt8] {
        precondition(offsets.allSatisfy { $0 >= 0 && ($0 < 14 || $0 >= arpSender) }, "MAC offsets outside Ethernet and ARP headers")
        guard old != new, frame.count >= 14 else { return frame }
        let isARP = frame[12] == 0x08 && frame[13] == 0x06
        var out = frame
        for o in offsets where (o < 14 || isARP) && o + 6 <= out.count && Array(out[o..<o + 6]) == old.bytes {
            out.replaceSubrange(o..<o + 6, with: new.bytes)
        }
        return out
    }

    static func address(_ path: String) -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            let n = min(path.utf8.count, buf.count - 1)
            buf.copyBytes(from: path.utf8.prefix(n))
            buf[n] = 0
        }
        return addr
    }
}
