import Foundation

/// A Linux container host's baseline hardening, chosen with the user (2026-11-23): kernel
/// settings, daily security updates, fail2ban, and a firewall that lets SSH in. Kept apart
/// from pratico's install so it can move to a project of its own: it reads the host, plans
/// files and commands, and never runs them; the caller shows the plan, asks, and applies it.
/// It never cuts off a service it does not know, and leaves an admin's firewall alone.
public enum HostHardening {
    public static let sysctlFile = "/etc/sysctl.d/90-pratico-hardening.conf"
    public static let autoUpgradesFile = "/etc/apt/apt.conf.d/21pratico-auto-upgrades"
    /// Written when the firewall was turned on here, so a revert turns off only that.
    public static let firewallMark = "/etc/pratico/firewall-enabled-by-pratico"
    public static let packages = ["unattended-upgrades", "ufw", "fail2ban"]

    /// The host as hardening sees it (`inspect()` on Linux; tests build it directly).
    public struct State: Sendable, Equatable {
        public struct Listener: Sendable, Hashable, Comparable {
            public var proto: String  // tcp | udp
            public var port: Int
            public var program: String
            public init(proto: String, port: Int, program: String) {
                self.proto = proto
                self.port = port
                self.program = program
            }
            public static func < (a: Listener, b: Listener) -> Bool { (a.proto, a.port) < (b.proto, b.port) }
        }
        /// Ports sshd answers on, whether sshd or systemd's ssh.socket holds them.
        public var sshPorts: [Int]
        /// Everything else listening beyond loopback: a firewall would cut these off.
        public var otherListeners: [Listener]
        public var missingPackages: [String]
        public var ufwActive: Bool
        public init(sshPorts: [Int], otherListeners: [Listener], missingPackages: [String], ufwActive: Bool) {
            self.sshPorts = sshPorts
            self.otherListeners = otherListeners
            self.missingPackages = missingPackages
            self.ufwActive = ufwActive
        }
    }

    public struct Plan: Sendable, Equatable {
        public var files: [(path: String, contents: String)] = []
        public var commands: [[String]] = []
        public var notes: [String] = []
        public static func == (a: Plan, b: Plan) -> Bool {
            a.files.map(\.path) == b.files.map(\.path) && a.commands == b.commands && a.notes == b.notes
        }
    }

    /// The firewall is left off, with a note, when something other than sshd listens
    /// beyond loopback and is not in `allow`.
    public static func plan(_ h: State, allow: [Int]) -> Plan {
        var p = Plan()
        p.files = [(sysctlFile, sysctlFileContents()), (autoUpgradesFile, autoUpgradesFileContents())]
        p.commands = [["sysctl", "--system"]]
        if !h.missingPackages.isEmpty {
            p.commands.append(["apt-get", "-q", "update"])
            p.commands.append(["apt-get", "-q", "install", "-y", "--no-install-recommends"] + h.missingPackages)
        }
        // Ubuntu's fail2ban enables its sshd jail (jail.d/defaults-debian.conf).
        p.commands.append(["systemctl", "enable", "--now", "fail2ban.service"])
        p.commands.append(["systemctl", "enable", "--now", "unattended-upgrades.service"])

        if h.ufwActive {
            p.notes.append("the firewall (ufw) is already on and is left as it is")
            return p
        }
        let cut = h.otherListeners.filter { !allow.contains($0.port) }
        guard cut.isEmpty else {
            let list = cut.sorted().map { "\($0.port)/\($0.proto) (\($0.program))" }.joined(separator: ", ")
            p.notes.append("the firewall stays off: \(list) would be cut off; allow them with --allow-port, or stop them, and install again")
            return p
        }
        p.commands.append(["ufw", "default", "deny", "incoming"])
        p.commands.append(["ufw", "default", "allow", "outgoing"])
        // allow, not limit: `docker -H ssh://` opens a connection per command (Compose,
        // several), past limit's 6 in 30 s; fail2ban bans addresses that fail to log in.
        for port in Set(h.sshPorts.isEmpty ? [22] : h.sshPorts).sorted() { p.commands.append(["ufw", "allow", "\(port)/tcp"]) }
        for port in Set(allow).sorted() { p.commands.append(["ufw", "allow", "\(port)"]) }
        p.commands.append(["ufw", "--force", "enable"])
        p.files.append((firewallMark, "# ufw was off before pratico-daemon install turned it on; uninstall turns it off.\n"))
        p.notes.append("the firewall allows only SSH in: ports containers publish need `sudo ufw allow PORT/tcp` to be reached from outside")
        return p
    }

    /// What a revert removes. The packages stay: security tools a host keeps.
    public static let removals = [sysctlFile, autoUpgradesFile, firewallMark]

    /// Run before the files go: turns off a firewall this turned on.
    public static func revertCommands() -> [[String]] {
        FileManager.default.fileExists(atPath: firewallMark) ? [["ufw", "--force", "disable"]] : []
    }

    public static func sysctlFileContents() -> String {
        """
        # pratico (pratico-daemon install): a container host's kernel hardening, each value
        # Ubuntu's default or stricter (perf_event_paranoid is left at Ubuntu's 4). Removed
        # by pratico-daemon uninstall; the values hold until the next boot.
        kernel.kptr_restrict = 2
        kernel.dmesg_restrict = 1
        kernel.unprivileged_bpf_disabled = 1
        net.core.bpf_jit_harden = 2
        kernel.kexec_load_disabled = 1
        # Only with the Yama LSM; "-" skips it where the kernel has none.
        -kernel.yama.ptrace_scope = 1
        fs.protected_fifos = 2
        fs.protected_regular = 2
        fs.protected_symlinks = 1
        fs.protected_hardlinks = 1
        fs.suid_dumpable = 0
        net.ipv4.conf.all.rp_filter = 1
        net.ipv4.conf.default.rp_filter = 1
        net.ipv4.conf.all.accept_redirects = 0
        net.ipv4.conf.default.accept_redirects = 0
        net.ipv6.conf.all.accept_redirects = 0
        net.ipv6.conf.default.accept_redirects = 0
        net.ipv4.conf.all.send_redirects = 0
        net.ipv4.conf.all.accept_source_route = 0
        net.ipv6.conf.all.accept_source_route = 0
        net.ipv4.conf.all.log_martians = 1
        net.ipv4.tcp_syncookies = 1
        net.ipv4.icmp_echo_ignore_broadcasts = 1

        """
    }

    static func autoUpgradesFileContents() -> String {
        """
        // pratico (pratico-daemon install): security updates every day, as Ubuntu intends.
        APT::Periodic::Update-Package-Lists "1";
        APT::Periodic::Unattended-Upgrade "1";

        """
    }

    #if os(Linux)
    /// The host's listeners, sshd, packages and firewall.
    public static func inspect() -> State {
        let owners = socketOwners()
        var ssh = Set(sshSocketPorts())
        var others: [State.Listener] = []
        for proto in ["tcp", "udp"] {
            for (port, inode) in listeners(proto) {
                let program = owners[inode] ?? "unknown"
                if proto == "tcp" && (program == "sshd" || (program == "systemd" && ssh.contains(port))) {
                    ssh.insert(port)
                } else {
                    others.append(.init(proto: proto, port: port, program: program))
                }
            }
        }
        let installed = installedPackages()
        let ufw = (try? String(contentsOfFile: "/etc/ufw/ufw.conf", encoding: .utf8))?.split(whereSeparator: \.isNewline)
            .contains { $0.trimmingCharacters(in: .whitespaces) == "ENABLED=yes" } ?? false
        // A service on both IPv4 and IPv6 is one listener.
        return State(sshPorts: ssh.sorted(), otherListeners: Set(others).sorted(),
                              missingPackages: packages.filter { !installed.contains($0) },
                              ufwActive: ufw && installed.contains("ufw"))
    }

    /// Sockets listening beyond loopback, from /proc/net: (port, socket inode). UDP counts
    /// as listening when unconnected; the DHCP clients (68, and 546 for DHCPv6) are the
    /// host's own, and ufw's default rules let their replies in.
    static func listeners(_ proto: String) -> [(Int, String)] {
        var out: [(Int, String)] = []
        for file in ["/proc/net/\(proto)", "/proc/net/\(proto)6"] {
            guard let text = try? String(contentsOfFile: file, encoding: .utf8) else { continue }
            for line in text.split(whereSeparator: \.isNewline).dropFirst() {
                let f = line.split(separator: " ", omittingEmptySubsequences: true)
                guard f.count > 9 else { continue }
                let local = f[1].split(separator: ":"), state = f[3]
                guard local.count == 2, let port = Int(local[1], radix: 16) else { continue }
                let listening = proto == "tcp" ? state == "0A" : (state == "07" && f[2].hasSuffix(":0000"))
                guard listening, !(proto == "udp" && dhcpClientPorts.contains(port)), !isLoopback(String(local[0])) else { continue }
                out.append((port, String(f[9])))
            }
        }
        return out
    }

    /// 127.0.0.0/8 and ::1 as /proc/net writes them (hex, host byte order per 32-bit word).
    static let dhcpClientPorts: Set<Int> = [68, 546]

    static func isLoopback(_ hex: String) -> Bool {
        if hex.count == 8 { return hex.hasSuffix("7F") }
        return hex == "00000000000000000000000001000000" || (hex.hasPrefix("0000000000000000FFFF0000") && hex.hasSuffix("7F"))
    }

    /// Socket inode to the program holding it, from every process's descriptors (root reads all).
    static func socketOwners() -> [String: String] {
        var owners: [String: String] = [:]
        let pids = (try? FileManager.default.contentsOfDirectory(atPath: "/proc"))?.filter { Int($0) != nil } ?? []
        for pid in pids {
            guard let comm = try? String(contentsOfFile: "/proc/\(pid)/comm", encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
                  let fds = try? FileManager.default.contentsOfDirectory(atPath: "/proc/\(pid)/fd") else { continue }
            for fd in fds {
                guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/\(pid)/fd/\(fd)"),
                      target.hasPrefix("socket:[") else { continue }
                owners[String(target.dropFirst(8).dropLast())] = owners[String(target.dropFirst(8).dropLast())] ?? comm
            }
        }
        return owners
    }

    /// Ubuntu 24.04 starts sshd from ssh.socket, which systemd holds: its ListenStream ports.
    static func sshSocketPorts() -> [Int] {
        let files = ["/usr/lib/systemd/system/ssh.socket", "/etc/systemd/system/ssh.socket"]
            + ((try? FileManager.default.contentsOfDirectory(atPath: "/etc/systemd/system/ssh.socket.d"))?.map { "/etc/systemd/system/ssh.socket.d/\($0)" } ?? [])
        var ports: [Int] = []
        for file in files {
            guard let text = try? String(contentsOfFile: file, encoding: .utf8) else { continue }
            for line in text.split(whereSeparator: \.isNewline) where line.hasPrefix("ListenStream=") {
                let value = line.dropFirst("ListenStream=".count)
                if value.isEmpty { ports.removeAll(); continue }  // a drop-in resets the list
                if let port = Int(value.split(separator: ":").last ?? "") { ports.append(port) }
            }
        }
        return ports
    }

    /// Installed packages, from dpkg's status file.
    static func installedPackages() -> Set<String> {
        guard let text = try? String(contentsOfFile: "/var/lib/dpkg/status", encoding: .utf8) else { return [] }
        var installed: Set<String> = []
        for stanza in text.components(separatedBy: "\n\n") {
            let lines = stanza.split(whereSeparator: \.isNewline)
            guard let name = lines.first(where: { $0.hasPrefix("Package: ") })?.dropFirst(9),
                  lines.contains(where: { $0 == "Status: install ok installed" }) else { continue }
            installed.insert(String(name))
        }
        return installed
    }
    #endif
}
