import Foundation

/// A Docker network (SPEC FR-23, D-25). The built-in `bridge` is Apple's `default`
/// network and `none` is Apple's `none`; every other network is an Apple network pratico
/// creates with an explicit subnet and its own labels.
struct NetworkRecord: Codable, Sendable {
    var id: String
    var name: String
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
    /// Disconnected after the container had run: gone from Docker's view and from name
    /// resolution, but the interface stays until the container is recreated (D-25).
    var detached: Bool

    init(aliases: [String] = [], detached: Bool = false) {
        self.aliases = aliases
        self.detached = detached
    }
}

/// A running container's address on one Apple network.
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
    /// `used`. Apple 1.0.0 auto-allocates subnets that never get a host bridge, so pratico
    /// always picks one itself.
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

/// Docker networks over Apple networks, plus name resolution between their containers.
///
/// Apple's DNS resolves container names only for a domain made with `container system dns
/// create`, which needs an administrator. So pratico writes each running member's
/// `/etc/hosts` instead, whenever a network's membership changes (D-25).
final class NetworkService: @unchecked Sendable {
    let runtime: AppleContainer
    let root: URL
    let events: EventBus
    weak var containers: ContainerService?

    private let lock = NSLock()
    private var records: [String: NetworkRecord] = [:]
    private var addresses: [String: [String: NetworkAddress]] = [:]  // container id → Apple network
    private let hostsQueue = DispatchQueue(label: "pratico.hosts")
    private let anchorLock = NSLock()
    private var anchorRunning = false  // guarded by anchorLock

    /// `apple` false: the embedded runtime, where no Apple networks exist (pratico-net
    /// replaces them, docs/design/runtime.md).
    let apple: Bool
    /// pratico-net's switch (embedded runtime only).
    let netSwitch: NetSwitch?

    init(runtime: AppleContainer, root: URL, events: EventBus, apple: Bool = true) {
        self.runtime = runtime
        self.apple = apple
        netSwitch = apple ? nil : NetSwitch(socketPath: root.deletingLastPathComponent().appending(path: "run/net.sock").path)
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
        let apple = !self.apple ? [:] : Dictionary(
            (runtime.runJSON(["network", "list", "--format", "json"])?.array ?? []).compactMap { n in
                n["id"]?.string.map { ($0, n) }
            }, uniquingKeysWith: { a, _ in a })
        var bridge = records.values.first { $0.name == "bridge" } ?? Self.builtin("bridge", "default")
        if self.apple {
            bridge.subnet = apple["default"]?["status"]?["ipv4Subnet"]?.string ?? bridge.subnet
            bridge.gateway = apple["default"]?["status"]?["ipv4Gateway"]?.string ?? bridge.gateway
        } else {
            // pratico-net: Docker's default bridge addressing.
            bridge.subnet = "172.17.0.0/16"
            bridge.gateway = "172.17.0.1"
        }
        records[bridge.id] = bridge
        save(bridge)
        if !records.values.contains(where: { $0.name == "none" }) {
            let none = Self.builtin("none", "none")
            records[none.id] = none
            save(none)
        }
        // A custom network deleted behind pratico's back comes back with its subnet.
        for rec in records.values where self.apple && !rec.builtin && apple[rec.appleName] == nil {
            _ = runtime.run(Self.appleCreateArgs(rec))
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

    static func appleCreateArgs(_ rec: NetworkRecord) -> [String] {
        ["network", "create", "--subnet", rec.subnet,
         "--label", "\(PraticoLabel.managed)=1", "--label", "\(PraticoLabel.id)=\(rec.id)"]
            + (rec.isInternal ? ["--internal"] : []) + [rec.appleName]
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
        if apple {
            let r = runtime.run(Self.appleCreateArgs(rec))
            guard r.ok else { throw APIError(500, "cannot create network: \(r.errorText)") }
            rec.gateway = runtime.runJSON(["network", "inspect", rec.appleName])?.array?.first?["status"]?["ipv4Gateway"]?.string ?? ""
        } else if let c = IPv4.cidr(subnet) {
            rec.gateway = IPv4.format(c.base + 1)
        }
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
        if apple {
            let r = runtime.run(["network", "delete", rec.appleName])
            // Already gone from the Apple side counts as removed.
            guard r.ok || runtime.runJSON(["network", "inspect", rec.appleName]) == nil else {
                throw APIError(500, "cannot remove network \(rec.name): \(r.errorText)")
            }
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

    /// Records the running container's addresses, one per Apple network.
    func started(_ rec: ContainerRecord) {
        var found: [String: NetworkAddress] = [:]
        for n in runtime.container(rec.appleId)?["status"]?["networks"]?.array ?? [] {
            guard let net = n["network"]?.string, let cidr = n["ipv4Address"]?.string else { continue }
            let (ip, len) = cidr.splitOnce("/")
            found[net] = NetworkAddress(ip: ip, prefix: Int(len ?? "") ?? 24, gateway: n["ipv4Gateway"]?.string ?? "",
                                        mac: n["macAddress"]?.string ?? "")
        }
        lock.lock()
        addresses[rec.id] = found
        lock.unlock()
    }

    func stopped(_ id: String) {
        lock.lock()
        addresses[id] = nil
        lock.unlock()
        netSwitch?.unregister(container: id)
    }

    // MARK: pratico-net (embedded runtime)

    /// Starts the switch with every network's segment and its name resolver.
    func startSwitch() throws {
        guard let netSwitch else { return }
        try FileManager.default.createDirectory(atPath: (netSwitch.socketPath as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        netSwitch.resolveName = { [weak self] port, name in self?.resolve(port, name) }
        for rec in all() { segment(rec) }
        try netSwitch.start()
    }

    private func segment(_ rec: NetworkRecord) {
        guard let netSwitch, !rec.builtin || rec.name == "bridge", let c = IPv4.cidr(rec.subnet),
            let gw = IPv4.parse(rec.gateway)
        else { return }
        netSwitch.setSegment(rec.id, NetSegment(gateway: gw, prefix: c.prefix, isInternal: rec.isInternal))
    }

    /// Plans the container's NICs (primary network first) and takes an address on each.
    func allocateNICs(_ rec: ContainerRecord, runDir: URL) -> [ShimNIC] {
        guard netSwitch != nil else { return [] }
        let mode = rec.hostConfig["NetworkMode"]?.string ?? ""
        let nets = active(rec).keys.compactMap { try? resolve($0) }.filter { $0.name != "none" }
            .sorted { a, b in
                let pa = a.name == mode || a.id == mode, pb = b.name == mode || b.id == mode
                return pa != pb ? pa : a.name < b.name
            }
        var nics: [ShimNIC] = []
        lock.lock()
        defer { lock.unlock() }
        for (i, net) in nets.enumerated() {
            guard let c = IPv4.cidr(net.subnet), let gw = IPv4.parse(net.gateway) else { continue }
            let used = Set(addresses.values.compactMap { $0[net.appleName].flatMap { IPv4.parse($0.ip) } } + [gw])
            let size = UInt32(1) << UInt32(32 - c.prefix)
            guard let ip = (UInt32(1)..<(size - 1)).lazy.map({ c.base + $0 }).first(where: { !used.contains($0) }) else { continue }
            let mac = MAC.derive(rec.id + net.id)
            let nic = ShimNIC(networkId: net.id, mac: mac.description, address: "\(IPv4.format(ip))/\(c.prefix)",
                              gateway: net.gateway, socket: runDir.appending(path: "\(rec.appleId).\(i)").path)
            addresses[rec.id, default: [:]][net.appleName] = NetworkAddress(ip: IPv4.format(ip), prefix: c.prefix,
                                                                            gateway: net.gateway, mac: mac.description)
            nics.append(nic)
        }
        return nics
    }

    /// The shim is up with these NICs (also after a daemon restart, from its spec).
    func attach(_ rec: ContainerRecord, _ nics: [ShimNIC]) {
        guard let netSwitch else { return }
        lock.lock()
        for nic in nics {
            guard let net = records[nic.networkId], let mac = MAC(nic.mac), let c = IPv4.cidr(nic.address) else { continue }
            let ip = IPv4.parse(String(nic.address.split(separator: "/")[0])) ?? c.base
            addresses[rec.id, default: [:]][net.appleName] = NetworkAddress(ip: IPv4.format(ip), prefix: c.prefix,
                                                                            gateway: nic.gateway, mac: nic.mac)
            netSwitch.register(NetPort(path: nic.socket, containerId: rec.id, networkId: net.id, mac: mac, ip: ip))
        }
        lock.unlock()
    }

    /// Publishes the container's `PortBindings` on its primary NIC (Docker binds all
    /// interfaces unless a host IP is given, D-8). Returns the bound host ports per
    /// container port, or throws Docker's "port is already allocated" and unbinds all.
    func publish(_ rec: ContainerRecord, _ nics: [ShimNIC]) throws -> [String: [(ip: String, port: String)]] {
        guard let netSwitch, let nic = nics.first, let mac = MAC(nic.mac),
            let ip = IPv4.parse(String(nic.address.split(separator: "/")[0])), let gw = IPv4.parse(nic.gateway)
        else { return [:] }
        let port = NetPort(path: nic.socket, containerId: rec.id, networkId: nic.networkId, mac: mac, ip: ip)
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

    func unpublish(_ id: String) { netSwitch?.uplink.unpublish(container: id) }

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
        guard scoped || asker.name != "bridge" else { return nil }  // Docker: no names on bridge
        guard let containers, !bare.isEmpty else { return nil }
        guard let me = containers.all().first(where: { $0.id == port.containerId }) else { return nil }
        // Bare names: the asker's network only. Scoped names: any network the asker is on.
        let nets = scoped ? Set(active(me).keys) : [asker.id]
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

    // MARK: Default-network anchor

    static let anchorName = "pratico-anchor"
    static let anchorImage = "registry.k8s.io/pause:3.10"

    /// Works around an Apple 1.0.0 vmnet bug. Apple's `default` network always takes
    /// `bridge100`. A custom network that activates (its first member starts) while
    /// `default` is idle takes the free `bridge100`, and loses its host bridge, so all
    /// connectivity, once `default` comes back. So when a custom network is about to
    /// activate with `default` idle, a pause container holds `default` up until the
    /// caller's `dropAnchor`. Returns true when the caller must call it (D-25).
    func raiseDefaultIfNeeded(_ rec: ContainerRecord) -> Bool {
        let gateway = bridge.gateway
        func hostHas(_ ip: String) -> Bool { IPv4.hostSubnets().contains { $0.hasPrefix(ip + "/") } }
        let activating = active(rec).keys.compactMap { try? resolve($0) }.contains { !$0.builtin && !hostHas($0.gateway) }
        guard activating, !gateway.isEmpty else { return false }
        anchorLock.lock()  // held until dropAnchor, so concurrent starts share one anchor safely
        guard !hostHas(gateway) else { return true }
        _ = runtime.run(["delete", "--force", Self.anchorName])
        if runtime.image(Self.anchorImage) == nil {
            _ = runtime.run(["image", "pull", "--platform", "linux/arm64", Self.anchorImage], timeout: 120)
        }
        let r = runtime.run(["run", "-d", "--name", Self.anchorName, "-m", "200M", "-c", "1",
                             "-l", "dev.pratico.anchor=1", Self.anchorImage], timeout: 60)
        guard r.ok else {
            FileHandle.standardError.write(Data("pratico: cannot start the default-network anchor: \(r.errorText)\n".utf8))
            return true
        }
        anchorRunning = true
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline && !hostHas(gateway) { Thread.sleep(forTimeInterval: 0.1) }
        return true
    }

    func dropAnchor() {
        if anchorRunning { _ = runtime.run(["delete", "--force", Self.anchorName]) }
        anchorRunning = false
        anchorLock.unlock()
    }

    // MARK: Name resolution

    /// Rewrites `/etc/hosts` in every running, unpaused member of these networks.
    /// `wait` blocks until done, so a started container's peers resolve it on return.
    func sync(_ networkIds: Set<String>, wait: Bool) {
        guard apple else { return }  // pratico-net answers names over DNS instead
        let work: @Sendable () -> Void = { [self] in
            guard let containers else { return }
            let custom = Set(networkIds.filter { id in (try? resolve(id)).map { !$0.builtin } ?? false })
            guard !custom.isEmpty else { return }
            let running = containers.all().filter { $0.state.running }
            for rec in running where !containers.isPaused(rec.id) {
                guard !custom.isDisjoint(with: active(rec).keys) else { continue }
                let r = runtime.run(["exec", "-i", "-u", "0", rec.appleId, "sh", "-c", "cat > /etc/hosts"],
                                    input: Data(hosts(for: rec, among: running).utf8), timeout: 10)
                if !r.ok { FileHandle.standardError.write(Data("pratico: /etc/hosts of \(rec.name): \(r.errorText)\n".utf8)) }
            }
        }
        if wait { hostsQueue.sync(execute: work) } else { hostsQueue.async(execute: work) }
    }

    /// The container's own lines, then every active member of its custom networks.
    func hosts(for rec: ContainerRecord, among running: [ContainerRecord]) -> String {
        var peers: [(ip: String, names: [String])] = []
        var own = ""
        for (netId, _) in active(rec).sorted(by: { $0.key < $1.key }) {
            guard let net = try? resolve(netId), !net.builtin else { continue }
            if own.isEmpty { own = address(rec.id, on: net)?.ip ?? "" }
            for peer in running {
                guard let ep = active(peer)[netId], let addr = address(peer.id, on: net) else { continue }
                peers.append((addr.ip, [peer.name] + ep.aliases + [String(peer.id.prefix(12))]))
            }
        }
        return Self.hostsFile(hostname: rec.config["Hostname"]?.string ?? rec.appleId, ownIP: own, peers: peers)
    }

    static func hostsFile(hostname: String, ownIP: String, peers: [(ip: String, names: [String])]) -> String {
        var lines = ["127.0.0.1\tlocalhost", "::1\tlocalhost ip6-localhost ip6-loopback"]
        if !ownIP.isEmpty { lines.append("\(ownIP)\t\(hostname)") }
        lines.append("# pratico: containers on shared networks")
        var seen = Set<String>()
        for p in peers {
            let names = p.names.filter { !$0.isEmpty && seen.insert("\(p.ip) \($0)").inserted }
            if !names.isEmpty { lines.append("\(p.ip)\t\(names.joined(separator: " "))") }
        }
        return lines.joined(separator: "\n") + "\n"
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
