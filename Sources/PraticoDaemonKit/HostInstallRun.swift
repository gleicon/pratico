#if os(Linux)
import Foundation
import PraticoCore

/// The half of `HostInstall` that reads and changes the host.
extension HostInstall {
    public struct Options: Sendable {
        public var yes = false
        public var filesOnly = false
        public var purge = false
        /// Leave the host's kernel settings, updates, and firewall as they are.
        public var noHarden = false
        /// Ports the firewall lets in besides SSH (services already on the host).
        public var allowPorts: [Int] = []
        public init() {}
    }

    public static func inspect(source: String) -> Host {
        let fm = FileManager.default
        var name = utsname()
        uname(&name)
        let machine = withUnsafeBytes(of: &name.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        var kvm = stat()
        let hasKVM = stat("/dev/kvm", &kvm) == 0 && (kvm.st_mode & S_IFMT) == S_IFCHR
        let kvmGroup = hasKVM ? getgrgid(kvm.st_gid).map { String(cString: $0.pointee.gr_name) } : nil
        var link = stat()
        let socketState: Host.DockerSocket
        if lstat(dockerSocket, &link) != 0 {
            socketState = .absent
        } else if (try? fm.destinationOfSymbolicLink(atPath: dockerSocket)) == socket {
            socketState = .pratico
        } else {
            socketState = .other
        }
        let sudoUser = ProcessInfo.processInfo.environment["SUDO_USER"].flatMap { getpwnam($0) == nil ? nil : $0 }
        return Host(isRoot: geteuid() == 0, machine: machine, hasSystemd: fm.fileExists(atPath: "/run/systemd/system"),
                    kvmGroup: kvmGroup, kvmGroupWritable: hasKVM && kvm.st_mode & 0o060 == 0o060,
                    apparmor: fm.fileExists(atPath: "/sys/kernel/security/apparmor"), dockerSocket: socketState,
                    hasDockerCLI: ["/usr/bin/docker", "/usr/local/bin/docker"].contains {
                        fm.isExecutableFile(atPath: $0) && (try? fm.destinationOfSymbolicLink(atPath: $0)) != "\(prefix)/pratico-daemon"
                    },
                    sudoUser: sudoUser, source: source)
    }

    /// `pratico-daemon install`, from the extracted release at `source`.
    public static func install(source: String, options: Options) throws {
        let host = inspect(source: source)
        try check(host)
        for name in payload where !FileManager.default.fileExists(atPath: "\(source)/\(name)") {
            throw InstallError("\(source)/\(name) is missing: extract the whole release")
        }
        let p = plan(host, hardening: options.noHarden ? nil : HostHardening.inspect(), allow: options.allowPorts)
        print(describe(p))
        if !options.filesOnly {
            print("The pratico service starts now; an existing one restarts, keeping its containers.")
        }
        try confirm(options)
        try copyPayload(from: source)
        for file in p.files { try write(file) }
        for link in p.links {
            let fm = FileManager.default
            if let existing = try? fm.destinationOfSymbolicLink(atPath: link.path) {
                guard existing == link.target else { throw InstallError("\(link.path) links to \(existing): not pratico's, left alone") }
                try fm.removeItem(atPath: link.path)  // an earlier install's
            } else if fm.fileExists(atPath: link.path) {
                throw InstallError("\(link.path) exists and is not pratico's: left alone")
            }
            try fm.createSymbolicLink(atPath: link.path, withDestinationPath: link.target)
        }
        if options.filesOnly {
            print("Files written. To finish:")
            for c in p.commands { print("  sudo " + c.joined(separator: " ")) }
            return
        }
        for c in p.commands { try run(c) }
        try awaitSocket()
        print("pratico is serving on unix://\(socket)")
        p.notes.forEach { print("note: \($0)") }
    }

    /// `pratico-daemon uninstall`: stops pratico's containers and removes what install wrote.
    public static func uninstall(options: Options) throws {
        let host = inspect(source: "")
        guard host.isRoot else { throw InstallError("run it as root: sudo \(prefix)/pratico-daemon uninstall") }
        var paths = removals(host: host, purge: options.purge).filter { FileManager.default.fileExists(atPath: $0) }
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: dialStdioLink)) == "\(prefix)/pratico-daemon" { paths.append(dialStdioLink) }
        let stop = ["systemctl", "kill", "--kill-whom=all", "--signal=SIGTERM", "pratico.service"]
        var commands: [[String]] = [["systemctl", "disable", "--now", "pratico.service"]]
        commands += HostHardening.revertCommands()
        if host.apparmor && FileManager.default.fileExists(atPath: apparmorProfile) {
            commands.append(["apparmor_parser", "--remove", apparmorProfile])
        }
        print("pratico will stop its running containers (\(stop.joined(separator: " ")), SIGKILL after \(Int(stopPatience)) s), then run:")
        commands.forEach { print("  " + $0.joined(separator: " ")) }
        print("and remove:")
        paths.forEach { print("  \($0)") }
        if !options.purge { print("\(home) (images, volumes, logs) is kept: --purge removes it too.") }
        print("The pratico user and group are kept (userdel pratico removes them), and so are the")
        print("security packages install added (\(HostHardening.packages.joined(separator: ", "))). Kernel settings")
        print("from \(HostHardening.sysctlFile) hold until the next boot.")
        try confirm(options)
        try? run(stop)  // a service already stopped is not a failure
        if !awaitUnitEmpty() { try? run(["systemctl", "kill", "--kill-whom=all", "--signal=SIGKILL", "pratico.service"]) }
        for c in commands { try? run(c) }
        for path in paths { try FileManager.default.removeItem(atPath: path) }
        try run(["systemctl", "daemon-reload"])
        print("pratico is uninstalled.")
    }

    /// How long the containers get to stop on SIGTERM (a `docker stop`) before SIGKILL.
    static let stopPatience: TimeInterval = 30

    /// True once no process is left in the service's cgroup: the daemon, its shims, and
    /// their VMs. Read from /proc, wherever the cgroup tree is mounted.
    static func awaitUnitEmpty() -> Bool {
        let deadline = Date().addingTimeInterval(stopPatience)
        while Date() < deadline {
            if unitProcesses() == 0 { return true }
            usleep(200_000)
        }
        return false
    }

    static func unitProcesses() -> Int {
        let pids = (try? FileManager.default.contentsOfDirectory(atPath: "/proc"))?.filter { Int($0) != nil } ?? []
        return pids.filter { pid in
            (try? String(contentsOfFile: "/proc/\(pid)/cgroup", encoding: .utf8))?.contains("/pratico.service\n") == true
        }.count
    }

    /// Asks once; `--yes` answers for scripts. Without a terminal there is no one to ask.
    static func confirm(_ options: Options) throws {
        if options.yes { return }
        guard isatty(STDIN_FILENO) == 1 else { throw InstallError("no terminal to confirm on: run it again with --yes") }
        print("Proceed? [y/N] ", terminator: "")
        fflush(nil)
        guard let answer = readLine(), ["y", "yes"].contains(answer.lowercased()) else { throw InstallError("nothing changed") }
    }

    /// The release to `/usr/lib/pratico` by rename: a running service keeps its binaries
    /// until it restarts, and a failed copy leaves the old install whole.
    static func copyPayload(from source: String) throws {
        let fm = FileManager.default
        let staging = prefix + ".new", previous = prefix + ".old"
        try? fm.removeItem(atPath: staging)
        try? fm.removeItem(atPath: previous)
        try fm.createDirectory(atPath: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        for name in payload { try fm.copyItem(atPath: "\(source)/\(name)", toPath: "\(staging)/\(name)") }
        try ownByRoot(staging)
        if fm.fileExists(atPath: prefix) { try fm.moveItem(atPath: prefix, toPath: previous) }
        try fm.moveItem(atPath: staging, toPath: prefix)
        try? fm.removeItem(atPath: previous)
    }

    /// The release is extracted by a user, and `copyItem` keeps owners: left so, that user
    /// could replace what the service runs. Every entry becomes root's, 0755 for directories
    /// and executables, 0644 otherwise; a symbolic link (which could point the install at a
    /// directory the user writes) is refused.
    static func ownByRoot(_ dir: String) throws {
        let fm = FileManager.default
        let entries = try fm.subpathsOfDirectory(atPath: dir).map { "\(dir)/\($0)" } + [dir]
        for path in entries {
            var st = stat()
            guard lstat(path, &st) == 0 else { throw InstallError("cannot read \(path): errno \(errno)") }
            let kind = st.st_mode & S_IFMT
            guard kind == S_IFDIR || kind == S_IFREG else {
                throw InstallError("\(path) is not a plain file or directory: extract the release again")
            }
            let mode: mode_t = kind == S_IFDIR || st.st_mode & 0o111 != 0 ? 0o755 : 0o644
            guard lchown(path, 0, 0) == 0, chmod(path, mode) == 0 else {
                throw InstallError("cannot make \(path) root's: errno \(errno)")
            }
        }
    }

    static func write(_ file: File) throws {
        let url = URL(filePath: file.path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(file.contents.utf8).write(to: url, options: .atomic)
        chmod(file.path, 0o644)
    }

    /// Exec'd from a fixed directory, never through a shell, its output the user's.
    static func run(_ command: [String]) throws {
        let fm = FileManager.default
        guard let name = command.first,
              let path = ["/usr/bin", "/bin", "/usr/sbin", "/sbin"].map({ "\($0)/\(name)" }).first(where: { fm.isExecutableFile(atPath: $0) })
        else { throw InstallError("\(command.first ?? "") is not installed") }
        print("+ " + command.joined(separator: " "))
        fflush(nil)  // before the command's own output, also when stdout is not a terminal
        let p = Process()
        p.executableURL = URL(filePath: path)
        p.arguments = Array(command.dropFirst())
        // No package stops the install to ask a question.
        if name == "apt-get" { p.environment = ProcessInfo.processInfo.environment.merging(["DEBIAN_FRONTEND": "noninteractive"]) { $1 } }
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw InstallError("\(command.joined(separator: " ")) failed (exit \(p.terminationStatus)); see journalctl -u pratico")
        }
    }

    /// The service answers `/_ping` within 30 s, or the install says where to look.
    static func awaitSocket() throws {
        let url = URL(filePath: socket)
        for _ in 0..<300 {
            if DaemonProbe.get("/_ping", socket: url)?.status == 200 { return }
            usleep(100_000)
        }
        throw InstallError("pratico did not answer on \(socket) within 30 s: see journalctl -u pratico")
    }
}
#endif
