import Foundation
import PraticoCore

/// A Docker network (SPEC FR-23, D-27): a segment of pratico-net's switch. `bridge` and
/// `none` are built in; every other network gets its own subnet.
struct NetworkRecord: Codable, Sendable {
    var id: String
    var name: String
    /// The key a container's addresses are kept under. (Named for the CLI backend's
    /// networks; kept so stored records still decode.)
    var appleName: String
    var created: Date
    var driver: String
    var subnet: String
    var gateway: String
    var isInternal: Bool
    var attachable: Bool
    var labels: [String: String]
    var options: [String: String]

    var builtin: Bool { name == "bridge" || name == "none" }
}

/// A container's attachment to a network.
struct Endpoint: Codable, Sendable, Equatable {
    var aliases: [String]
    /// Set by the CLI backend's disconnect, which could not remove an interface; records
    /// it left still decode, and such an endpoint counts as disconnected.
    var detached: Bool

    init(aliases: [String] = [], detached: Bool = false) {
        self.aliases = aliases
        self.detached = detached
    }
}

/// A running container's address on one network.
struct NetworkAddress: Equatable {
    var ip: String
    var prefix: Int
    var gateway: String
    var mac: String
}

enum IPv4 {
    static func parse(_ s: String) -> UInt32? {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var v: UInt32 = 0
        for p in parts {
            guard let n = UInt8(p) else { return nil }
            v = v << 8 | UInt32(n)
        }
        return v
    }

    static func format(_ v: UInt32) -> String {
        (0..<4).map { String(v >> UInt32(24 - 8 * $0) & 0xff) }.joined(separator: ".")
    }

    static func mask(_ prefix: Int) -> UInt32 { prefix == 0 ? 0 : ~UInt32(0) << UInt32(32 - prefix) }

    /// Whether `ip` (dotted) is in `subnet`.
    static func contains(_ subnet: (base: UInt32, prefix: Int), _ ip: String) -> Bool {
        parse(ip).map { $0 & mask(subnet.prefix) == subnet.base } ?? false
    }

    static func cidr(_ s: String) -> (base: UInt32, prefix: Int)? {
        let (addr, len) = s.splitOnce("/")
        guard let ip = parse(addr), let prefix = Int(len ?? "32"), (0...32).contains(prefix) else { return nil }
        return (ip & mask(prefix), prefix)
    }

    static func overlaps(_ a: String, _ b: String) -> Bool {
        guard let x = cidr(a), let y = cidr(b) else { return false }
        let m = mask(min(x.prefix, y.prefix))
        return x.base & m == y.base & m
    }

    /// First /24 of 172.18.0.0/16 (Docker's range for user networks) that overlaps none of
    /// `used`.
    static func freeSubnet(avoiding used: [String]) -> String? {
        let start = parse("172.18.0.0")!
        for i in UInt32(0)..<256 {
            let s = "\(format(start + (i << 8)))/24"
            if !used.contains(where: { overlaps($0, s) }) { return s }
        }
        return nil
    }

    /// Subnets of the host's own interfaces, so a new network never shadows a LAN or VPN.
    static func hostSubnets() -> [String] {
        var out: [String] = []
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return out }
        defer { freeifaddrs(head) }
        var cur = head
        while let ifa = cur?.pointee {
            if let a = ifa.ifa_addr, a.pointee.sa_family == UInt8(AF_INET), let m = ifa.ifa_netmask {
                let ip = a.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
                let mask = m.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
                out.append("\(format(ip))/\(mask.nonzeroBitCount)")
            }
            cur = ifa.ifa_next
        }
        return out
    }
}

/// Docker networks on pratico-net: a user-space switch with DNS at every gateway (D-27).
final class NetworkService: @unchecked Sendable {
    let root: URL
    let events: EventBus
    weak var containers: ContainerService?

    private let lock = NSLock()
    private var records: [String: NetworkRecord] = [:]
    private var addresses: [String: [String: NetworkAddress]] = [:]  // container id → network key
    private var slots: [String: NICSlots] = [:]  // container id → its VM's NIC slots

    let netSwitch: NetSwitch

    init(root: URL, events: EventBus) {
        netSwitch = NetSwitch(socketPath: root.deletingLastPathComponent().appending(path: "run/net.sock").path)
        self.root = root
        self.events = events
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        load()
    }

    // MARK: Persistence

    private func file(_ id: String) -> URL { root.appending(path: "\(id).json") }

    private func load() {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        for name in (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [] where name.hasSuffix(".json") {
            guard let data = try? Data(contentsOf: root.appending(path: name)),
                let rec = try? dec.decode(NetworkRecord.self, from: data)
            else { continue }
            records[rec.id] = rec
        }
        var bridge = records.values.first { $0.name == "bridge" } ?? Self.builtin("bridge", "default")
        // Docker's default bridge addressing.
        bridge.subnet = "172.17.0.0/16"
        bridge.gateway = "172.17.0.1"
        records[bridge.id] = bridge
        save(bridge)
        if !records.values.contains(where: { $0.name == "none" }) {
            let none = Self.builtin("none", "none")
            records[none.id] = none
            save(none)
        }
    }

    private static func builtin(_ name: String, _ appleName: String) -> NetworkRecord {
        NetworkRecord(id: randomHexID(), name: name, appleName: appleName, created: Date(),
                      driver: name == "none" ? "null" : "bridge", subnet: "", gateway: "", isInternal: false,
                      attachable: false, labels: [:], options: [:])
    }

    private func save(_ rec: NetworkRecord) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(rec).write(to: file(rec.id), options: .atomic)
    }

    // MARK: Lookup

    var bridge: NetworkRecord {
        lock.lock()
        defer { lock.unlock() }
        return records.values.first { $0.name == "bridge" }!
    }

    func all() -> [NetworkRecord] {
        lock.lock()
        defer { lock.unlock() }
        return records.values.sorted { $0.name < $1.name }
    }

    /// Full ID, name, or unique ID prefix, as Docker resolves networks.
    func resolve(_ ref: String) throws -> NetworkRecord {
        lock.lock()
        defer { lock.unlock() }
        if let r = records[ref] { return r }
        if let r = records.values.first(where: { $0.name == ref }) { return r }
        let matches = records.values.filter { $0.id.hasPrefix(ref) }
        if matches.count == 1 { return matches[0] }
        if matches.count > 1 { throw APIError(400, "network \(ref) is ambiguous (\(matches.count) matches found based on ID prefix)") }
        throw APIError(404, "network \(ref) not found")
    }

    /// A container's endpoints; records from before networks existed are on `bridge`.
    func endpoints(_ rec: ContainerRecord) -> [String: Endpoint] {
        rec.endpoints ?? [bridge.id: Endpoint()]
    }

    func active(_ rec: ContainerRecord) -> [String: Endpoint] { endpoints(rec).filter { !$0.value.detached } }

    func members(_ net: NetworkRecord) -> [ContainerRecord] {
        (containers?.all() ?? []).filter { endpoints($0)[net.id] != nil }
    }

    // MARK: Create, remove

    func create(_ body: JSON) throws -> NetworkRecord {
        guard let name = body["Name"]?.string, !name.isEmpty else { throw APIError(400, "network name is required") }
        // Container-name rules, but one character is allowed.
        guard Names.valid(name) || (name.count == 1 && (name.first!.isLetter || name.first!.isNumber)) else {
            throw APIError(400, "invalid network name \"\(name)\"")
        }
        if ["host", "bridge", "none", "default"].contains(name) {
            throw APIError(403, "\(name) is a pre-defined network and cannot be created")
        }
        if all().contains(where: { $0.name == name }) { throw APIError(409, "network with name \(name) already exists") }
        let driver = body["Driver"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? "bridge"
        guard driver == "bridge" else { throw APIError(400, "pratico: only the bridge network driver is supported, not \(driver)") }
        if body["EnableIPv6"]?.bool == true { throw APIError(400, "pratico: IPv6 networks are not supported") }

        // Host subnets stay excluded on pratico-net too: a container could not reach a LAN
        // or VPN that its own network shadows.
        let used = all().map(\.subnet).filter { !$0.isEmpty } + IPv4.hostSubnets()
        var subnet: String
        if let asked = body["IPAM"]?["Config"]?.array?.first?["Subnet"]?.string, !asked.isEmpty {
            guard let c = IPv4.cidr(asked), c.prefix <= 30 else { throw APIError(400, "invalid subnet \(asked)") }
            subnet = "\(IPv4.format(c.base))/\(c.prefix)"
            if let clash = used.first(where: { IPv4.overlaps($0, subnet) }) {
                throw APIError(403, "Pool overlaps with other one on this address space (\(clash))")
            }
        } else {
            guard let free = IPv4.freeSubnet(avoiding: used) else {
                throw APIError(403, "could not find an available, non-overlapping IPv4 address pool among the defaults to assign to the network")
            }
            subnet = free
        }

        let id = randomHexID()
        let labels: [String: String] = body["Labels"]?.object?.compactMapValues(\.string) ?? [:]
        let options: [String: String] = body["Options"]?.object?.compactMapValues(\.string) ?? [:]
        var rec = NetworkRecord(
            id: id, name: name, appleName: "pratico-\(id.prefix(12))", created: Date(), driver: driver,
            subnet: subnet, gateway: "", isInternal: body["Internal"]?.bool ?? false,
            attachable: body["Attachable"]?.bool ?? false, labels: labels, options: options)
        if let c = IPv4.cidr(subnet) { rec.gateway = IPv4.format(c.base + 1) }
        segment(rec)
        lock.lock()
        records[id] = rec
        lock.unlock()
        save(rec)
        emit(rec, "create")
        return rec
    }

    func remove(_ ref: String) throws {
        let rec = try resolve(ref)
        guard !rec.builtin else { throw APIError(403, "\(rec.name) is a pre-defined network and cannot be removed") }
        guard members(rec).isEmpty else {
            throw APIError(403, "error while removing network: network \(rec.name) id \(rec.id) has active endpoints")
        }
        lock.lock()
        records[rec.id] = nil
        lock.unlock()
        try? FileManager.default.removeItem(at: file(rec.id))
        emit(rec, "destroy")
    }

    func prune(filters: [String: [String]]) -> JSON {
        var deleted: [JSON] = []
        for rec in all() where !rec.builtin && matchesLabels(rec, filters["label"] ?? []) {
            if (try? remove(rec.id)) != nil { deleted.append(.string(rec.name)) }
        }
        return ["NetworksDeleted": .array(deleted)]
    }

    private func matchesLabels(_ rec: NetworkRecord, _ wanted: [String]) -> Bool {
        wanted.allSatisfy { v in
            let (k, val) = v.splitOnce("=")
            guard let have = rec.labels[k] else { return false }
            return val == nil || have == val
        }
    }

    func emit(_ rec: NetworkRecord, _ action: String, container: String? = nil) {
        var attrs = ["name": rec.name, "type": rec.driver]
        if let container { attrs["container"] = container }
        events.emit("network", action, id: rec.id, attributes: attrs)
    }

    // MARK: Container attachments

    /// The networks a new container joins, primary (`NetworkMode`) first.
    func attachments(host: JSON, networking: JSON?) throws -> [(NetworkRecord, Endpoint)] {
        let configs = networking?["EndpointsConfig"]?.object ?? [:]
        func endpoint(_ key: String) -> Endpoint { Endpoint(aliases: configs[key]?["Aliases"]?.strings ?? []) }
        let mode = host["NetworkMode"]?.string ?? ""
        var out: [(NetworkRecord, Endpoint)] = []
        switch mode {
        case "", "default", "bridge":
            out.append((bridge, endpoint(configs["default"] == nil ? "bridge" : "default")))
        case "host":
            throw APIError(400, "pratico: network mode host is not supported; each container is its own VM")
        case let m where m.hasPrefix("container:"):
            throw APIError(400, "pratico: sharing another container's network namespace is not supported")
        default:
            out.append((try resolve(mode), endpoint(mode)))
        }
        for (key, cfg) in configs.sorted(by: { $0.key < $1.key }) {
            let net = key == "default" ? bridge : try resolve(key)
            if out.contains(where: { $0.0.id == net.id }) { continue }
            out.append((net, Endpoint(aliases: cfg["Aliases"]?.strings ?? [])))
        }
        if out.count > 1, out.contains(where: { $0.0.name == "none" }) {
            throw APIError(400, "conflicting options: container cannot be connected to network none and other networks")
        }
        return out
    }

    func stopped(_ id: String) {
        lock.lock()
        addresses[id] = nil
        slots[id] = nil
        lock.unlock()
        netSwitch.unregister(container: id)
    }

    // MARK: pratico-net

    /// Starts the switch with every network's segment and its name resolver.
    func startSwitch() throws {
        try FileManager.default.createDirectory(atPath: (netSwitch.socketPath as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        netSwitch.resolveName = { [weak self] port, name in self?.resolve(port, name) }
        for rec in all() { segment(rec) }
        try netSwitch.start()
    }

    private func segment(_ rec: NetworkRecord) {
        guard !rec.builtin || rec.name == "bridge", let c = IPv4.cidr(rec.subnet),
            let gw = IPv4.parse(rec.gateway)
        else { return }
        netSwitch.setSegment(rec.id, NetSegment(gateway: gw, prefix: c.prefix, isInternal: rec.isInternal))
    }

    /// Plans the container's NIC slots: its networks (primary first), then spares for hot
    /// connect. `--network none` gets no NICs at all.
    func allocateNICs(_ rec: ContainerRecord, runDir: URL) throws -> NICSlots {
        let mode = rec.hostConfig["NetworkMode"]?.string ?? ""
        let nets = active(rec).keys.compactMap { try? resolve($0) }.filter { $0.name != "none" }
            .sorted { a, b in
                let pa = a.name == mode || a.id == mode, pb = b.name == mode || b.id == mode
                return pa != pb ? pa : a.name < b.name
            }
        guard !nets.isEmpty else { return NICSlots() }
        guard nets.count <= ShimNIC.slots else {
            throw APIError(400, "pratico: a container can be on at most \(ShimNIC.slots) networks (the Virtualization.framework limit); \(rec.name) has \(nets.count)")
        }
        func socket(_ slot: Int) -> String { runDir.appending(path: "\(rec.appleId).\(slot)").path }
        lock.lock()
        defer { lock.unlock() }
        var nics: [ShimNIC] = []
        for net in nets {
            guard let ip = freeAddress(net) else { continue }
            let mac = MAC.derive(rec.id + net.id)
            nics.append(ShimNIC(networkId: net.id, mac: mac.description, address: ip, gateway: net.gateway, socket: socket(nics.count)))
            record(rec.id, nics[nics.count - 1], on: net)
        }
        let primary = nics.isEmpty ? nil : 0
        while nics.count < ShimNIC.slots {
            nics.append(.spare(nics.count, mac: MAC.derive(rec.id + "slot\(nics.count)"), socket: socket(nics.count)))
        }
        slots[rec.id] = NICSlots(nics, primary: primary)
        return slots[rec.id]!
    }

    /// A free address on `net` as CIDR. Spare slots keep theirs reserved: the guest still
    /// holds it on a link-down interface. Callers hold `lock`.
    private func freeAddress(_ net: NetworkRecord) -> String? {
        guard let c = IPv4.cidr(net.subnet), let gw = IPv4.parse(net.gateway) else { return nil }
        var used = Set(addresses.values.compactMap { $0[net.appleName].flatMap { IPv4.parse($0.ip) } } + [gw])
        for nic in slots.values.flatMap(\.slots) where !nic.hasPlaceholder && IPv4.contains(c, nic.ip) {
            if let ip = IPv4.parse(nic.ip) { used.insert(ip) }
        }
        let size = UInt32(1) << UInt32(32 - c.prefix)
        guard let ip = (UInt32(1)..<(size - 1)).lazy.map({ c.base + $0 }).first(where: { !used.contains($0) }) else { return nil }
        return "\(IPv4.format(ip))/\(c.prefix)"
    }

    /// Callers hold `lock`.
    private func record(_ id: String, _ nic: ShimNIC, on net: NetworkRecord) {
        let prefix = Int(nic.address.split(separator: "/").last ?? "") ?? 0
        addresses[id, default: [:]][net.appleName] = NetworkAddress(ip: nic.ip, prefix: prefix, gateway: nic.gateway, mac: nic.mac)
    }

    /// The shim is up with these NICs (also after a daemon restart, from its spec).
    func attach(_ rec: ContainerRecord, _ nics: NICSlots) {
        lock.lock()
        slots[rec.id] = nics
        for nic in nics.slots where !nic.isSpare {
            guard let net = records[nic.networkId], let port = Self.port(rec.id, nic) else { continue }
            record(rec.id, nic, on: net)
            netSwitch.register(port)
        }
        lock.unlock()
    }

    private static func port(_ id: String, _ nic: ShimNIC) -> NetPort? {
        guard let mac = MAC(nic.mac), let ip = IPv4.parse(nic.ip) else { return nil }
        return NetPort(path: nic.socket, containerId: id, networkId: nic.networkId, mac: mac, ip: ip)
    }

    func nics(_ id: String) -> NICSlots {
        lock.withLock { slots[id] ?? NICSlots() }
    }

    /// Hot connect: binds a spare slot of the running container to `net`, has `guest`
    /// bring the VM's side up, then plugs the NIC into the switch. If the guest side
    /// fails, only this binding is undone. A container with no network yet makes `net`
    /// its primary one, and its published ports follow. Callers serialize changes to
    /// one container's networks.
    func hotConnect(_ rec: ContainerRecord, _ net: NetworkRecord, guest: (NICChange) throws -> Void) throws {
        let (binding, change) = try lock.withLock { () throws -> (NICSlots.Binding, NICChange) in
            guard var nics = slots[rec.id], !nics.slots.isEmpty else {
                throw APIError(409, "pratico: container \(rec.name) started without network slots; restart it to connect networks")
            }
            guard let c = IPv4.cidr(net.subnet) else { throw APIError(500, "network \(net.name) has no subnet") }
            guard let (slot, reused) = nics.free(in: c) else {
                throw APIError(409, "pratico: container \(rec.name) has no free network slot (\(ShimNIC.slots) per VM, the Virtualization.framework limit; a disconnected network keeps its slot until the container restarts)")
            }
            // A never-used slot's placeholder holds nothing on `net`.
            guard let address = reused ? nics.slots[slot].address : freeAddress(net) else {
                throw APIError(403, "no available IPv4 addresses on network \(net.name)")
            }
            let binding = nics.bind(slot, networkId: net.id, address: address, gateway: net.gateway)
            slots[rec.id] = nics
            record(rec.id, nics.slots[slot], on: net)
            return (binding, .up(slot: slot, address: address, gateway: nics.primary == slot ? net.gateway : nil))
        }
        do {
            try guest(change)
        } catch {
            lock.withLock {
                slots[rec.id]?.revert(binding)
                addresses[rec.id]?[net.appleName] = nil
            }
            throw error
        }
        let nics = nics(rec.id)
        guard nics.slots.indices.contains(binding.slot) else { return }  // stopped meanwhile
        if let port = Self.port(rec.id, nics.slots[binding.slot]) { netSwitch.register(port) }
        if nics.primary == binding.slot { retarget(rec) }
    }

    /// Hot disconnect: the switch forgets the NIC first, so no frame reaches or leaves it
    /// from here on, whatever the guest does, and its flows to the Mac and the internet
    /// end. Then `guest` brings the VM's side down; that is best effort, as a guest that
    /// ignores it only sees a dead link. The slot keeps its address reserved (see
    /// `freeAddress`). Losing the primary network moves the default route and the
    /// published ports to the next one; DNS keeps working, as every pratico gateway
    /// answers it.
    func hotDisconnect(_ rec: ContainerRecord, _ net: NetworkRecord, guest: (NICChange) -> Void) {
        let cut = lock.withLock { () -> (socket: String, changes: [NICChange], wasPrimary: Bool)? in
            guard var nics = slots[rec.id], let u = nics.unbind(net.id) else { return nil }
            slots[rec.id] = nics
            addresses[rec.id]?[net.appleName] = nil
            var changes: [NICChange] = [.down(slot: u.slot)]
            if let next = u.successor { changes.append(.route(slot: next, gateway: nics.slots[next].gateway)) }
            return (nics.slots[u.slot].socket, changes, u.wasPrimary)
        }
        guard let cut else { return }
        netSwitch.unregister(path: cut.socket)
        cut.changes.forEach(guest)
        if cut.wasPrimary { retarget(rec) }
    }

    /// Publishes the container's `PortBindings` on its primary NIC (Docker binds all
    /// interfaces unless a host IP is given, D-8). Returns the bound host ports per
    /// container port, or throws Docker's "port is already allocated" and unbinds all.
    func publish(_ rec: ContainerRecord, _ nics: NICSlots) throws -> [String: [(ip: String, port: String)]] {
        guard let nic = nics.primaryNIC, let port = Self.port(rec.id, nic), let gw = IPv4.parse(nic.gateway)
        else { return [:] }
        var out: [String: [(ip: String, port: String)]] = [:]
        for (key, list) in (rec.hostConfig["PortBindings"]?.object ?? [:]).sorted(by: { $0.key < $1.key }) {
            let (num, proto) = key.splitOnce("/")
            guard let containerPort = UInt16(num) else { continue }
            for b in list.array ?? [] {
                let hostIP = b["HostIp"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? "0.0.0.0"
                guard let hostAddr = IPv4.parse(hostIP) else { continue }  // IPv6 binds: not yet
                let asked = UInt16(b["HostPort"]?.string ?? "") ?? 0
                do {
                    let bound = try netSwitch.uplink.publish(container: rec.id, nic: port, gateway: gw, hostIP: hostAddr,
                                                             hostPort: asked, containerPort: containerPort, udp: proto == "udp")
                    out[key, default: []].append((hostIP, String(bound)))
                } catch {
                    netSwitch.uplink.unpublish(container: rec.id)
                    throw error
                }
            }
        }
        return out
    }

    /// Points the container's published ports at its primary NIC. With none, they stay
    /// bound (no other process can take them) and lead nowhere until the next one.
    private func retarget(_ rec: ContainerRecord) {
        guard let nic = nics(rec.id).primaryNIC, let port = Self.port(rec.id, nic),
            let gw = IPv4.parse(nic.gateway)
        else { return }
        netSwitch.uplink.retarget(container: rec.id, nic: port, gateway: gw)
    }

    func unpublish(_ id: String) { netSwitch.uplink.unpublish(container: id) }

    /// DNS for a container (SPEC D-27): Docker's names on user networks, plus pratico's
    /// `<name>.pratico.internal` on every network the asker shares, and the host names.
    func resolve(_ port: NetPort, _ query: String) -> [UInt32]? {
        let name = query.hasSuffix(".") ? String(query.dropLast()) : query
        guard let asker = try? resolve(port.networkId) else { return nil }
        if ["host.docker.internal", "host.pratico.internal", "gateway.docker.internal", "gateway.pratico.internal"].contains(name) {
            return asker.isInternal ? nil : IPv4.parse(asker.gateway).map { [$0] }  // the Mac is outside
        }
        let suffix = ".pratico.internal"
        let scoped = name.hasSuffix(suffix)
        let bare = scoped ? String(name.dropLast(suffix.count)) : name
        guard let containers, !bare.isEmpty else { return nil }
        guard let me = containers.all().first(where: { $0.id == port.containerId }) else { return nil }
        // Bare names: the asker's user networks, whichever NIC asked (Docker: none on
        // bridge). Scoped names: any network the asker is on.
        let mine = Set(active(me).keys)
        let nets = scoped ? mine : mine.filter { (try? resolve($0))?.name != "bridge" }
        guard !nets.isEmpty else { return nil }
        var out: [UInt32] = []
        for c in containers.all() where c.state.running {
            for (netId, ep) in active(c) where nets.contains(netId) {
                let names = [c.name, String(c.id.prefix(12))] + ep.aliases
                guard names.contains(where: { $0.lowercased() == bare }), let net = try? resolve(netId),
                    let a = address(c.id, on: net), let ip = IPv4.parse(a.ip), !out.contains(ip)
                else { continue }
                out.append(ip)
            }
        }
        return out.isEmpty ? nil : out
    }

    func address(_ containerId: String, on net: NetworkRecord) -> NetworkAddress? {
        lock.lock()
        defer { lock.unlock() }
        return addresses[containerId]?[net.appleName]
    }

    // MARK: Views

    func json(_ rec: NetworkRecord, withContainers: Bool) -> JSON {
        var members: [String: JSON] = [:]
        if withContainers {
            for c in self.members(rec) where c.state.running && active(c)[rec.id] != nil {
                let a = address(c.id, on: rec)
                members[c.id] = [
                    "Name": .string(c.name), "EndpointID": .string(Self.endpointID(rec, c)),
                    "MacAddress": .string(a?.mac ?? ""),
                    "IPv4Address": .string(a.map { "\($0.ip)/\($0.prefix)" } ?? ""), "IPv6Address": "",
                ]
            }
        }
        let ipam: [JSON] = rec.subnet.isEmpty ? [] : [["Subnet": .string(rec.subnet), "Gateway": .string(rec.gateway)]]
        return [
            "Name": .string(rec.name),
            "Id": .string(rec.id),
            "Created": .string(Timestamp.format(rec.created)),
            "Scope": "local",
            "Driver": .string(rec.driver),
            "EnableIPv4": .bool(rec.name != "none"),
            "EnableIPv6": false,
            "IPAM": ["Driver": "default", "Options": [:], "Config": .array(ipam)],
            "Internal": .bool(rec.isInternal),
            "Attachable": .bool(rec.attachable),
            "Ingress": false,
            "ConfigFrom": ["Network": ""],
            "ConfigOnly": false,
            "Containers": .object(members),
            "Options": JSON(rec.options),
            "Labels": JSON(rec.labels),
        ]
    }

    /// Deterministic, so inspect output is stable across calls.
    static func endpointID(_ net: NetworkRecord, _ c: ContainerRecord) -> String {
        String(c.id.prefix(32)) + String(net.id.prefix(32))
    }

    /// `NetworkSettings.Networks` of a container.
    func containerNetworks(_ rec: ContainerRecord) -> JSON {
        var out: [String: JSON] = [:]
        for (netId, ep) in active(rec) {
            guard let net = try? resolve(netId) else { continue }
            let a = rec.state.running ? address(rec.id, on: net) : nil
            out[net.name] = [
                "IPAMConfig": .null, "Links": .null, "Aliases": JSON(ep.aliases),
                "MacAddress": .string(a?.mac ?? ""), "DriverOpts": .null,
                "NetworkID": .string(net.id), "EndpointID": .string(a == nil ? "" : Self.endpointID(net, rec)),
                "Gateway": .string(a?.gateway ?? ""), "IPAddress": .string(a?.ip ?? ""),
                "IPPrefixLen": .int(Int64(a?.prefix ?? 0)),
                "IPv6Gateway": "", "GlobalIPv6Address": "", "GlobalIPv6PrefixLen": 0,
                "DNSNames": net.builtin ? .null : JSON([rec.name] + ep.aliases + [String(rec.id.prefix(12))]),
            ]
        }
        return .object(out)
    }

    func list(filters: [String: [String]]) -> [JSON] {
        all().filter { rec in
            for (key, values) in filters where !values.isEmpty {
                let ok = values.contains { v in
                    switch key {
                    case "name": return rec.name.contains(v)
                    case "id": return rec.id.hasPrefix(v)
                    case "label": return matchesLabels(rec, [v])
                    case "driver": return rec.driver == v
                    case "type": return v == (rec.builtin ? "builtin" : "custom")
                    case "dangling": return (v == "true" || v == "1") == (!rec.builtin && members(rec).isEmpty)
                    default: return true
                    }
                }
                if !ok { return false }
            }
            return true
        }.map { json($0, withContainers: false) }
    }
}
