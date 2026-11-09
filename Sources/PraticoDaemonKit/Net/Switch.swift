import Foundation

/// One NIC of a running container, attached to one network. The shim relays the NIC's
/// frames between its VM and the switch over a datagram socket bound at `path`.
struct NetPort: Sendable, Equatable {
    var path: String
    var containerId: String
    var networkId: String
    var mac: MAC
    var ip: UInt32
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
/// frame never crosses networks. A port may only send as its own MAC and IP (no spoofing,
/// unlike a plain bridge). The gateway address answers ARP, ping, and DNS.
///
/// It survives daemon restarts: shims send to `socketPath` connectionless, so a restarted
/// daemon rebinds it and traffic resumes once ports are registered again.
final class NetSwitch: @unchecked Sendable {
    let socketPath: String
    /// Names → addresses for the asker's networks; nil means "not a container name".
    var resolveName: (@Sendable (NetPort, String) -> [UInt32]?)?

    private var fd: Int32 = -1
    private let lock = NSLock()
    private var ports: [String: NetPort] = [:]  // by socket path
    private var segments: [String: NetSegment] = [:]  // by network ID
    private let lookups = DispatchSemaphore(value: 32)  // bounds concurrent host DNS lookups
    private(set) lazy var uplink = Uplink(switch: self)
    static let maxFrame = 65536
    static let mtu = 1500

    init(socketPath: String) { self.socketPath = socketPath }

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

    func register(_ p: NetPort) {
        lock.lock()
        ports[p.path] = p
        lock.unlock()
    }

    func unregister(container id: String) {
        lock.lock()
        let gone = ports.values.filter { $0.containerId == id }.map(\.path)
        ports = ports.filter { $0.value.containerId != id }
        lock.unlock()
        for path in gone { uplink.drop(path: path) }
    }

    func unregister(path: String) {
        lock.lock()
        ports[path] = nil
        lock.unlock()
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
            lock.lock()
            let port = ports[path]
            lock.unlock()
            guard let port else { continue }  // unknown sender: not a pratico NIC
            handle(Array(buf[0..<n]), from: port)
        }
    }

    func handle(_ frame: [UInt8], from port: NetPort) {
        guard let eth = Ethernet(frame), eth.src == port.mac else { return }  // spoofed MAC
        lock.lock()
        let segment = segments[port.networkId]
        lock.unlock()
        guard let segment else { return }
        switch eth.type {
        case EtherType.arp.rawValue:
            guard let arp = ARP(eth.payload), arp.senderMAC == port.mac, arp.senderIP == port.ip else { return }
            if arp.op == 1 && arp.targetIP == segment.gateway {
                let reply = ARP(op: 2, senderMAC: .gateway, senderIP: segment.gateway, targetMAC: port.mac, targetIP: port.ip)
                send(Ethernet(dst: port.mac, src: .gateway, type: EtherType.arp.rawValue, payload: reply.bytes).bytes, to: port)
                return
            }
            forward(eth, frame, from: port)
        case EtherType.ipv4.rawValue:
            guard let ip = IPv4Packet(eth.payload), ip.src == port.ip else { return }  // spoofed IP
            if eth.dst == .gateway {
                toGateway(ip, from: port, segment: segment)
            } else {
                forward(eth, frame, from: port)
            }
        default:
            return  // IPv6 and others are not routed yet
        }
    }

    /// Same-network delivery by destination MAC; broadcast and multicast flood the network.
    private func forward(_ eth: Ethernet, _ frame: [UInt8], from port: NetPort) {
        lock.lock()
        let peers = ports.values.filter { $0.networkId == port.networkId && $0.path != port.path }
        lock.unlock()
        if eth.dst.isMulticast {
            for p in peers { send(frame, to: p) }
        } else if let p = peers.first(where: { $0.mac == eth.dst }) {
            send(frame, to: p)
        }
    }

    private func toGateway(_ ip: IPv4Packet, from port: NetPort, segment: NetSegment) {
        if ip.dst == segment.gateway && ip.proto == 1 {
            if let echo = icmpEchoReply(ip.payload) { reply(port, from: segment.gateway, proto: 1, echo) }
            return
        }
        if ip.dst == segment.gateway && ip.proto == 17, let udp = UDPDatagram(ip.payload), udp.dstPort == 53 {
            return dns(udp, from: port, segment: segment)
        }
        lock.lock()
        let all = Array(segments.values)
        lock.unlock()
        uplink.handle(ip, from: port, segment: segment, pratico: all)
    }

    // MARK: DNS

    private func dns(_ udp: UDPDatagram, from port: NetPort, segment: NetSegment) {
        guard let q = DNSQuery(udp.payload), q.qclass == 1 else { return }
        let respond: @Sendable ([UInt32]?) -> Void = { [self] addrs in
            let answer = UDPDatagram(srcPort: 53, dstPort: udp.srcPort, payload: q.answer(udp.payload, addresses: addrs))
            reply(port, from: segment.gateway, proto: 17, answer.bytes(src: segment.gateway, dst: port.ip))
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
        guard q.qtype == 1 else {
            respond([])  // IPv6 and other types: no records yet (no IPv6 routing)
            return
        }
        // External names go through the Mac's resolver, so VPN and split DNS apply.
        guard lookups.wait(timeout: .now()) == .success else { return }  // busy: the client retries
        let name = q.name
        DispatchQueue.global().async { [self] in
            defer { lookups.signal() }
            respond(Self.hostLookup(name))
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
        for packet in IPv4Packet.fragments(src: src, dst: port.ip, proto: proto, payload: payload, mtu: Self.mtu) {
            send(Ethernet(dst: port.mac, src: .gateway, type: EtherType.ipv4.rawValue, payload: packet).bytes, to: port)
        }
    }

    func send(_ frame: [UInt8], to port: NetPort) {
        var addr = Self.address(port.path)
        _ = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(fd, frame, frame.count, 0, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
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
