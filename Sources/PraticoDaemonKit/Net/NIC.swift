import Containerization
import ContainerizationExtras
import Foundation
import PraticoCore
#if canImport(Virtualization)
import Virtualization
#else
import CPratico
import CloudHypervisor
#endif

/// One network endpoint of a VM: an address on one of its virtual NICs (cards), as the
/// daemon plans it and the shim builds it (part of `NICSlots`). Since 2026-11-15 a VM has
/// one card carrying an address per network (D-43); VMs from before have a card per
/// endpoint, and spare cards link-down with no switch port until `docker network connect`.
struct ShimNIC: Codable, Sendable, Equatable {
    /// Empty for a spare slot: no switch port, so no frame reaches or leaves it.
    var networkId: String
    var mac: String
    /// CIDR, e.g. 172.17.0.2/16. A spare slot keeps its last address (still reserved for
    /// it, as the guest cannot delete addresses) or a link-local placeholder.
    var address: String
    var gateway: String
    /// Where the shim's relay for this endpoint's card binds: endpoints on one card share it.
    var socket: String

    /// Virtualization.framework allows 4 network devices per VM (one-card-per-network VMs).
    static let slots = 4

    /// Containerization gives every NIC an address at boot; a /32 link-local one adds no route.
    private static let placeholderPrefix = "169.254.255."

    var isSpare: Bool { networkId.isEmpty }
    /// A spare that never held a real address.
    var hasPlaceholder: Bool { address.hasPrefix(Self.placeholderPrefix) }
    var ip: String { String(address.split(separator: "/")[0]) }

    static func spare(_ slot: Int, mac: MAC, socket: String) -> ShimNIC {
        ShimNIC(networkId: "", mac: mac.description, address: "\(placeholderPrefix)\(slot + 1)/32", gateway: "", socket: socket)
    }
}

/// A VM's network endpoints and which one is primary: it holds the default route, DNS,
/// and the published ports. Endpoints sharing a `socket` are addresses on one card;
/// `ethN` is the Nth card in order of first appearance. Empty for `--network none`.
struct NICSlots: Codable, Sendable, Equatable {
    var slots: [ShimNIC] = []
    var primary: Int?

    init(_ slots: [ShimNIC] = [], primary: Int? = nil) {
        self.slots = slots
        self.primary = primary
    }

    var primaryNIC: ShimNIC? { primary.map { slots[$0] } }

    /// The VM's cards, by socket, in order: card N is `ethN`.
    var cards: [String] {
        var seen: [String] = []
        for s in slots where !seen.contains(s.socket) { seen.append(s.socket) }
        return seen
    }

    /// The card endpoint `entry` lives on.
    func card(of entry: Int) -> Int { cards.firstIndex(of: slots[entry].socket)! }

    /// The MAC the guest's card has: its first endpoint's. Other endpoints on the card have
    /// their own, which the switch shows their networks instead (D-44).
    func cardMAC(of entry: Int) -> String { slots.first { $0.socket == slots[entry].socket }!.mac }

    /// The endpoint whose address a card boots with: the primary when it is on that card,
    /// else the card's first. The others are added once the guest is up.
    func bootEntry(card n: Int) -> Int {
        precondition(cards.indices.contains(n), "no card \(n)")
        let socket = cards[n]
        if let p = primary, slots[p].socket == socket { return p }
        return slots.firstIndex { $0.socket == socket }!
    }

    /// Endpoints on card `n` besides its boot one: addresses added once the guest is up.
    func extraEntries(card n: Int) -> [Int] {
        let boot = bootEntry(card: n)
        return slots.indices.filter { $0 != boot && card(of: $0) == n && !slots[$0].isSpare }
    }

    /// Every address card `n` holds once the guest is up.
    func addresses(card n: Int) -> [String] {
        ([bootEntry(card: n)] + extraEntries(card: n)).map { slots[$0].address }
    }

    /// Entry `entry` as a switch port of `container`'s.
    func port(_ entry: Int, container: String) -> NetPort? {
        let nic = slots[entry]
        guard let mac = MAC(nic.mac), let card = MAC(cardMAC(of: entry)), let ip = IPv4.parse(nic.ip) else { return nil }
        return NetPort(path: nic.socket, containerId: container, networkId: nic.networkId, mac: mac, ip: ip, card: card)
    }

    /// Whether another bound endpoint shares `entry`'s card (its link must stay up).
    func cardShared(_ entry: Int) -> Bool {
        slots.indices.contains { $0 != entry && slots[$0].socket == slots[entry].socket && !slots[$0].isSpare }
    }

    /// A new endpoint on card 0 (one-card VMs, D-43); `revert` removes it.
    mutating func add(networkId: String, mac: String, address: String, gateway: String) -> Binding? {
        guard let first = slots.first else { return nil }
        precondition(!slots.contains { $0.networkId == networkId && !$0.isSpare }, "network \(networkId) bound twice")
        precondition(primary.map(slots.indices.contains) ?? true, "primary out of range")
        slots.append(ShimNIC(networkId: networkId, mac: mac, address: address, gateway: gateway, socket: first.socket))
        let b = Binding(slot: slots.count - 1, previous: nil, previousPrimary: primary)
        if primary == nil { primary = b.slot }
        return b
    }

    /// The slot `docker network connect` binds on a network with subnet `subnet`: one that
    /// last held an address in it (the guest still holds it, and gets it back instead of
    /// holding two), else a never-used spare.
    func free(in subnet: (base: UInt32, prefix: Int)) -> (slot: Int, reused: Bool)? {
        if let i = slots.indices.first(where: { slots[$0].isSpare && !slots[$0].hasPlaceholder && IPv4.contains(subnet, slots[$0].ip) }) {
            return (i, true)
        }
        return slots.indices.first { slots[$0].isSpare && slots[$0].hasPlaceholder }.map { ($0, false) }
    }

    /// What `bind` changed, so `revert` undoes exactly that.
    struct Binding: Sendable {
        var slot: Int
        /// nil for an endpoint `add` appended.
        var previous: ShimNIC?
        var previousPrimary: Int?
    }

    /// Binds `slot` to a network; it becomes primary when no slot is.
    mutating func bind(_ slot: Int, networkId: String, address: String, gateway: String) -> Binding {
        let b = Binding(slot: slot, previous: slots[slot], previousPrimary: primary)
        slots[slot].networkId = networkId
        slots[slot].address = address
        slots[slot].gateway = gateway
        if primary == nil { primary = slot }
        return b
    }

    mutating func revert(_ b: Binding) {
        if let previous = b.previous { slots[b.slot] = previous } else { slots.remove(at: b.slot) }
        primary = b.previousPrimary
    }

    /// Unbinds the network's slot, which keeps its address (the guest cannot delete it).
    /// A primary slot hands over to the first slot still bound, the `successor`.
    mutating func unbind(_ networkId: String) -> (slot: Int, wasPrimary: Bool, successor: Int?)? {
        guard let i = slots.firstIndex(where: { $0.networkId == networkId }) else { return nil }
        slots[i].networkId = ""
        slots[i].gateway = ""
        guard primary == i else { return (i, false, nil) }
        primary = slots.firstIndex { !$0.isSpare }
        return (i, true, primary)
    }

    // Specs from before slots hold a plain array, whose first NIC is primary; specs from
    // before `primary` flag it on a NIC.
    init(from decoder: any Decoder) throws {
        guard let legacy = try? decoder.singleValueContainer().decode([ShimNIC].self) else {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            slots = try c.decode([ShimNIC].self, forKey: .slots)
            primary = try c.decodeIfPresent(Int.self, forKey: .primary)
            return
        }
        struct Flag: Decodable { var primary: Bool? }
        let flags = (try? decoder.singleValueContainer().decode([Flag].self)) ?? []
        slots = legacy
        primary = flags.contains { $0.primary != nil }
            ? flags.firstIndex { $0.primary == true }
            : legacy.firstIndex { !$0.isSpare }
    }
}

#if canImport(Virtualization)
/// A VM NIC whose frames go through a datagram socket pair: Virtualization.framework
/// holds one end, the shim's relay the other (SPEC D-27).
struct SwitchNIC: Interface, VZInterface {
    let ipv4Address: CIDRv4
    let ipv4Gateway: IPv4Address?
    let macAddress: MACAddress?
    let handle: FileHandle

    var mtu: UInt32 { 1500 }

    func device() throws -> VZVirtioNetworkDeviceConfiguration {
        let config = VZVirtioNetworkDeviceConfiguration()
        if let m = macAddress, let mac = VZMACAddress(string: m.description) { config.macAddress = mac }
        config.attachment = VZFileHandleNetworkDeviceAttachment(fileHandle: handle)
        return config
    }
}
#else
/// A VM NIC on a Linux host (docs/design/remote.md, decision 3): a TAP in the VM's own
/// network namespace, which cloud-hypervisor joins. Offloads are off, so every frame is a
/// plain Ethernet frame within the MTU, checksummed by the guest, as the switch expects.
struct SwitchNIC: Interface, CHInterface {
    let tapName: String
    let ipv4Address: CIDRv4
    let ipv4Gateway: IPv4Address?
    let macAddress: MACAddress?
    /// The VM's namespaces, shared by its cards.
    let namespaces: CHVirtualMachineManager.Namespaces

    var mtu: UInt32 { 1500 }

    func chNetConfig() throws -> CloudHypervisor.NetConfig {
        CloudHypervisor.NetConfig(tap: tapName, mac: macAddress?.description, mtu: Int(mtu),
                                  offloadTSO: false, offloadUFO: false, offloadCsum: false)
    }
}
#endif

/// Moves frames between the VM end of a NIC and the daemon's switch. Sends to the
/// switch are connectionless, so a daemon restart costs a few dropped frames, not the
/// network.
enum NICRelay {
    /// Builds the VM's NICs for Containerization, one per card, and starts relaying; the
    /// card marked primary gets the default route.
    static func start(_ cards: [(nic: ShimNIC, primary: Bool)], switchSocket: String) throws -> [SwitchNIC] {
        precondition(cards.count <= ShimNIC.slots, "\(cards.count) cards, at most \(ShimNIC.slots)")
        #if canImport(Virtualization)
        return try cards.map { card in
            var pair: [Int32] = [-1, -1]
            guard socketpair(AF_UNIX, Posix.datagram, 0, &pair) == 0 else { throw APIError(500, "pratico-net: socketpair failed") }
            let vm = pair[0], local = pair[1]
            for fd in [vm, local] { bufferSizes(fd) }
            try relay(local, nic: card.nic, switchSocket: switchSocket)
            return SwitchNIC(
                ipv4Address: try CIDRv4(card.nic.address),
                ipv4Gateway: card.primary ? try IPv4Address(card.nic.gateway) : nil,
                macAddress: try MACAddress(card.nic.mac),
                handle: FileHandle(fileDescriptor: vm, closeOnDealloc: false))
        }
        #else
        guard !cards.isEmpty else { return [] }
        let names = cards.indices.map { "tap\($0)" }
        var user: Int32 = -1, net: Int32 = -1, step: Int32 = 0
        var packets = [Int32](repeating: -1, count: cards.count)
        let made = withCStrings(names) { pratico_vm_netns($0, Int32(names.count), &user, &net, &packets, &step) }
        guard made == 0 else {
            throw APIError(500, "pratico-net: cannot make the VM's network namespace (step \(step)): \(String(cString: strerror(errno)))")
        }
        let namespaces = CHVirtualMachineManager.Namespaces(user: user, net: net)
        return try zip(cards, zip(names, packets)).map { card, tap in
            bufferSizes(tap.1)
            try relay(tap.1, nic: card.nic, switchSocket: switchSocket)
            return SwitchNIC(
                tapName: tap.0,
                ipv4Address: try CIDRv4(card.nic.address),
                ipv4Gateway: card.primary ? try IPv4Address(card.nic.gateway) : nil,
                macAddress: try MACAddress(card.nic.mac),
                namespaces: namespaces)
        }
        #endif
    }

    #if !canImport(Virtualization)
    private static func withCStrings<R>(_ strings: [String], _ body: (UnsafePointer<UnsafePointer<CChar>?>) -> R) -> R {
        let copies = strings.map { strdup($0) }
        defer { copies.forEach { free($0) } }
        let pointers = copies.map { UnsafePointer($0) }
        return pointers.withUnsafeBufferPointer { body($0.baseAddress!) }
    }
    #endif

    /// Relays frames between `local`, the VM's end of a card (one frame per datagram or
    /// packet), and the switch, through a socket bound at the card's `nic.socket`.
    private static func relay(_ local: Int32, nic: ShimNIC, switchSocket: String) throws {
        let relay = socket(AF_UNIX, Posix.datagram, 0)
        guard relay >= 0 else { throw APIError(500, "pratico-net: socket failed") }
        bufferSizes(relay)
        unlink(nic.socket)
        var addr = NetSwitch.address(nic.socket)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(relay, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0 else { throw APIError(500, "pratico-net: cannot bind \(nic.socket)") }
        chmod(nic.socket, 0o600)

        // VM → switch
        Thread.detachNewThread {
            var buf = [UInt8](repeating: 0, count: NetSwitch.maxFrame)
            var to = NetSwitch.address(switchSocket)
            while true {
                let n = recv(local, &buf, buf.count, 0)
                if n < 0 { if errno == EINTR { continue }; return }
                _ = withUnsafePointer(to: &to) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(relay, buf, n, 0, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                    }
                }
            }
        }
        // switch → VM (only the switch's socket may write here)
        Thread.detachNewThread {
            var buf = [UInt8](repeating: 0, count: NetSwitch.maxFrame)
            while true {
                var from = sockaddr_un()
                var len = socklen_t(MemoryLayout<sockaddr_un>.size)
                let n = withUnsafeMutablePointer(to: &from) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(relay, &buf, buf.count, 0, $0, &len) }
                }
                if n < 0 { if errno == EINTR { continue }; return }
                let sender = withUnsafeBytes(of: from.sun_path) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }
                guard sender == switchSocket else { continue }
                _ = send(local, buf, n, 0)
            }
        }
    }

    private static func bufferSizes(_ fd: Int32) {
        var snd: Int32 = 1 << 20
        var rcv: Int32 = 4 << 20
        setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &snd, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &rcv, socklen_t(MemoryLayout<Int32>.size))
    }
}
