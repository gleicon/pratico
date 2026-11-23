import Foundation
import PraticoCore

/// `pratico-daemon install` on a Linux host (docs/design/remote.md, slice 4): the release's
/// files to `/usr/lib/pratico`, a hardened systemd unit run as the `pratico` user, its
/// account and the group whose members use the socket, and Ubuntu's AppArmor profile for
/// the shim. The plan is shown before anything changes; the system commands it runs are
/// exec'd from fixed paths, never through a shell (`--files-only` prints them instead).
public enum HostInstall {
    public static let prefix = "/usr/lib/pratico"
    public static let home = "/var/lib/pratico"
    public static let socket = "/run/pratico/docker.sock"
    /// Where the docker CLI looks by default, `docker system dial-stdio` included.
    public static let dockerSocket = "/run/docker.sock"
    static let unit = "/usr/lib/systemd/system/pratico.service"
    static let sysusers = "/usr/lib/sysusers.d/pratico.conf"
    static let members = "/etc/sysusers.d/pratico-members.conf"
    static let tmpfiles = "/usr/lib/tmpfiles.d/pratico.conf"
    static let apparmorProfile = "/etc/apparmor.d/pratico-shim"
    /// What a release carries, beside `pratico-daemon` itself.
    static let payload = ["pratico-daemon", "pratico-shim", "cloud-hypervisor", "virtiofsd", "runtime", "THIRD_PARTY_NOTICES"]

    /// `uname -m` of the hosts this build runs on: the release is one architecture.
    #if arch(x86_64)
    public static let buildMachine = "x86_64"
    #else
    public static let buildMachine = "aarch64"
    #endif

    /// What the host offers, read by `inspect()` on Linux; tests build it directly.
    public struct Host: Sendable, Equatable {
        public var isRoot: Bool
        public var machine: String
        public var hasSystemd: Bool
        /// The group that owns `/dev/kvm`, nil without `/dev/kvm`.
        public var kvmGroup: String?
        public var kvmGroupWritable: Bool
        public var apparmor: Bool
        /// What is at `/run/docker.sock`: nothing, pratico's link, or something else.
        public var dockerSocket: DockerSocket
        public var hasDockerCLI: Bool
        /// The user who ran `sudo`, added to the `pratico` group.
        public var sudoUser: String?
        public var source: String

        public enum DockerSocket: Sendable, Equatable { case absent, pratico, other }
    }

    public struct InstallError: Error, CustomStringConvertible {
        public let description: String
        init(_ d: String) { description = d }
    }

    public struct File: Sendable, Equatable {
        public let path: String
        public let contents: String
    }

    public struct Plan: Sendable {
        public var files: [File] = []
        public var commands: [[String]] = []
        public var notes: [String] = []
    }

    /// Refuses a host pratico cannot serve, before anything is written.
    public static func check(_ host: Host) throws {
        guard host.isRoot else { throw InstallError("run it as root: sudo \(host.source)/pratico-daemon install") }
        guard host.machine == buildMachine else {
            throw InstallError("this release is for \(buildMachine) hosts; this one is \(host.machine): use the release built for it")
        }
        guard host.hasSystemd else { throw InstallError("pratico runs as a systemd service: this host does not run systemd") }
        guard let group = host.kvmGroup else {
            throw InstallError("no /dev/kvm: pratico runs each container in a VM and needs KVM (bare metal, or a cloud with nested virtualization)")
        }
        guard host.kvmGroupWritable, group != "root" else {
            throw InstallError("/dev/kvm is not open to its group (\(group)): the pratico user could not use it")
        }
        guard host.source != prefix else { throw InstallError("run the install from the extracted release, not from \(prefix)") }
    }

    /// `hardening` nil: `--no-harden`, the host left as it is.
    public static func plan(_ host: Host, hardening: HostHardening.State? = nil, allow: [Int] = []) -> Plan {
        var p = Plan()
        p.files = [
            File(path: unit, contents: unitFile()),
            File(path: sysusers, contents: sysusersFile(kvmGroup: host.kvmGroup ?? "kvm")),
            File(path: tmpfiles, contents: tmpfilesFile(linkDockerSocket: host.dockerSocket != .other)),
        ]
        if let user = host.sudoUser, user != "root" {
            p.files.append(File(path: members, contents: "# Users of pratico's socket (pratico-daemon install).\nm \(user) pratico\n"))
        }
        if host.apparmor { p.files.append(File(path: apparmorProfile, contents: apparmorFile())) }
        p.commands = [["systemd-sysusers"], ["systemd-tmpfiles", "--create", tmpfiles]]
        if host.apparmor { p.commands.append(["apparmor_parser", "--replace", apparmorProfile]) }
        p.commands += [["systemctl", "daemon-reload"], ["systemctl", "enable", "pratico.service"], ["systemctl", "restart", "pratico.service"]]
        if let hardening {
            let h = HostHardening.plan(hardening, allow: allow)
            p.files += h.files.map { File(path: $0.path, contents: $0.contents) }
            p.commands += h.commands
            p.notes += h.notes
        }
        if host.dockerSocket == .other {
            p.notes.append("\(dockerSocket) belongs to another engine and is left alone: point the docker CLI at unix://\(socket) (a docker context)")
        }
        if !host.hasDockerCLI {
            p.notes.append("`docker -H ssh://` needs the docker CLI on this host (the CLI only, no engine)")
        }
        p.notes.append("members of the pratico group use the socket; a new group takes effect at the next login")
        return p
    }

    public static func unitFile() -> String {
        """
        # pratico (pratico-daemon install): the Docker API on \(socket), one VM per container.
        [Unit]
        Description=pratico, one VM per container
        Documentation=https://github.com/gleicon/pratico
        After=network-online.target
        Wants=network-online.target

        [Service]
        User=pratico
        Group=pratico
        ExecStart=\(prefix)/pratico-daemon --home \(home) --socket \(socket)
        Environment=PRATICO_RUNTIME_ASSETS=\(prefix)/runtime
        StateDirectory=pratico
        StateDirectoryMode=0700
        RuntimeDirectory=pratico
        RuntimeDirectoryMode=0750
        # Containers outlive the daemon, as on the Mac: a restart or an upgrade adopts them.
        KillMode=process
        Restart=on-failure
        LimitNOFILE=65536:524288
        NoNewPrivileges=yes
        ProtectSystem=full
        # Not ProtectKernelTunables, ProtectKernelLogs or ProtectHostname: each mounts over
        # part of /proc, and a user namespace may mount a /proc of its own (virtiofsd's
        # sandbox does) only where /proc is whole; Tunables also makes /proc/sys read-only
        # in the VMs' network namespaces, where the shim turns IPv6 off. A user without root
        # cannot write the host's tunables, read its kernel log, or set its hostname anyway.
        ProtectKernelModules=yes
        ProtectControlGroups=yes
        ProtectClock=yes
        LockPersonality=yes
        RestrictRealtime=yes
        RestrictSUIDSGID=yes
        # A user and a network namespace per VM, and virtiofsd's sandbox (mount, pid, and
        # network namespaces in it); nothing else.
        RestrictNamespaces=user net mnt pid
        RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_PACKET AF_NETLINK
        DevicePolicy=closed
        DeviceAllow=/dev/kvm rw
        DeviceAllow=/dev/net/tun rw

        [Install]
        WantedBy=multi-user.target

        """
    }

    static func sysusersFile(kvmGroup: String) -> String {
        """
        # pratico's service account (pratico-daemon install); members of group pratico use its socket.
        u pratico - "pratico container VMs" \(home) /usr/sbin/nologin
        m pratico \(kvmGroup)

        """
    }

    static func tmpfilesFile(linkDockerSocket: Bool) -> String {
        var s = "# pratico (pratico-daemon install).\n"
        if linkDockerSocket {
            s += "# The docker CLI's default socket, when no other engine has it.\nL \(dockerSocket) - - - - \(socket)\n"
        }
        return s
    }

    static func apparmorFile() -> String {
        """
        # pratico-shim makes a user and a network namespace per VM (docs/design/remote.md,
        # decision 3); Ubuntu lets only programs with a profile make user namespaces.
        abi <abi/4.0>,
        include <tunables/global>

        profile pratico-shim \(prefix)/pratico-shim flags=(unconfined) {
          userns,

          include if exists <local/pratico-shim>
        }

        """
    }

    /// What `uninstall` removes; `/var/lib/pratico` (images, volumes) only with `purge`.
    public static func removals(host: Host, purge: Bool) -> [String] {
        var paths = [unit, sysusers, members, tmpfiles, apparmorProfile, prefix] + HostHardening.removals
        if host.dockerSocket == .pratico { paths.append(dockerSocket) }
        if purge { paths.append(home) }
        return paths
    }

    /// The plan as it is shown before anything changes.
    public static func describe(_ p: Plan) -> String {
        var lines = ["pratico will install to \(prefix) and write:"]
        lines += p.files.map { "  \($0.path)" }
        lines.append("then run:")
        lines += p.commands.map { "  " + $0.joined(separator: " ") }
        lines += p.notes.map { "note: \($0)" }
        return lines.joined(separator: "\n")
    }
}
