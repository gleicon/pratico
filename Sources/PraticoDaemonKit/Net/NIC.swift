import Containerization
import ContainerizationExtras
import Foundation
import Virtualization

/// One NIC slot as the daemon plans it and the shim builds it (part of `ShimSpec`).
/// Virtualization.framework cannot hot-plug NICs, so a VM boots with `slots` of them;
/// the spare ones are link-down with no switch port until `docker network connect`.
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
    /// Holds the default route and the published ports; nil in specs from before slots,
    /// where the first NIC does.
    var primary: Bool?

    /// Virtualization.framework allows 4 network devices per VM.
    static let slots = 4

    var isSpare: Bool { networkId.isEmpty }

    /// The NIC holding the default route, DNS, and published ports, if any.
    static func primary(_ nics: [ShimNIC]) -> ShimNIC? {
        nics.first { $0.primary == true } ?? nics.first.flatMap { $0.primary == nil && !$0.isSpare ? $0 : nil }
    }
    var hasPlaceholder: Bool { address.hasPrefix("169.254.255.") }
    var ip: String { String(address.split(separator: "/")[0]) }

    /// Containerization gives every NIC an address at boot; a /32 link-local one adds no route.
    static func spare(_ slot: Int, mac: MAC, socket: String) -> ShimNIC {
        ShimNIC(networkId: "", mac: mac.description, address: "169.254.255.\(slot + 1)/32", gateway: "", socket: socket)
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
