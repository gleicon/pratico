import Containerization
import ContainerizationExtras
import Foundation
import Virtualization

/// One NIC slot as the daemon plans it and the shim builds it (part of `NICSlots`).
/// A spare slot is link-down with no switch port until `docker network connect`.
struct ShimNIC: Codable, Sendable, Equatable {
    /// Empty for a spare slot: no switch port, so no frame reaches or leaves it.
    var networkId: String
    var mac: String
    /// CIDR, e.g. 172.17.0.2/16. A spare slot keeps its last address (still reserved for
    /// it, as the guest cannot delete addresses) or a link-local placeholder.
    var address: String
    var gateway: String
    /// Where the shim's relay binds; the switch knows the port by this path.
    var socket: String

    /// Virtualization.framework allows 4 network devices per VM.
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

/// A VM's NIC slots (`ethN` is slot N) and which one is primary: it holds the default
/// route, DNS, and the published ports. Virtualization.framework cannot hot-plug NICs,
/// so a VM boots with `ShimNIC.slots` of them; empty for `--network none`.
struct NICSlots: Codable, Sendable, Equatable {
    var slots: [ShimNIC] = []
    var primary: Int?

    init(_ slots: [ShimNIC] = [], primary: Int? = nil) {
        self.slots = slots
        self.primary = primary
    }

    var primaryNIC: ShimNIC? { primary.map { slots[$0] } }

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
        var previous: ShimNIC
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
        slots[b.slot] = b.previous
        if primary == b.slot { primary = b.previousPrimary }
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

/// Moves frames between the VM end of a NIC and the daemon's switch. Sends to the
/// switch are connectionless, so a daemon restart costs a few dropped frames, not the
/// network.
enum NICRelay {
    /// Builds the NIC for Containerization and starts relaying; `primary` gets the default route.
    static func start(_ nic: ShimNIC, switchSocket: String, primary: Bool) throws -> SwitchNIC {
        var pair: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_DGRAM, 0, &pair) == 0 else { throw APIError(500, "pratico-net: socketpair failed") }
        let vm = pair[0], local = pair[1]
        for fd in [vm, local] { bufferSizes(fd) }

        let relay = socket(AF_UNIX, SOCK_DGRAM, 0)
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
        return SwitchNIC(
            ipv4Address: try CIDRv4(nic.address),
            ipv4Gateway: primary ? try IPv4Address(nic.gateway) : nil,
            macAddress: try MACAddress(nic.mac),
            handle: FileHandle(fileDescriptor: vm, closeOnDealloc: false))
    }

    private static func bufferSizes(_ fd: Int32) {
        var snd: Int32 = 1 << 20
        var rcv: Int32 = 4 << 20
        setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &snd, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &rcv, socklen_t(MemoryLayout<Int32>.size))
    }
}
