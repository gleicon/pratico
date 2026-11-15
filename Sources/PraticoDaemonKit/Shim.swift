import Containerization
import ContainerizationOCI
import ContainerizationExtras
import ContainerizationOS
import Foundation

/// What a shim runs, written by the daemon to `containers/<id>/spec.json`
/// (docs/design/runtime.md). Paths are absolute.
struct ShimSpec: Codable, Sendable {
    var id: String  // VM/container name (the Docker short ID)
    var kernel: String
    var initfs: String
    var rootfs: String
    var arguments: [String]
    var environment: [String]
    var workingDirectory: String
    var user: String
    var tty: Bool
    /// Docker `OpenStdin`: the process reads what attached clients send to `/stdin`.
    var openStdin: Bool
    var hostname: String
    var cpus: Int
    var memoryMiB: Int
    var mounts: [ShimMount]
    /// pratico-net NIC slots; empty for `--network none`.
    var nics = NICSlots()
    var switchSocket: String = ""
    /// Everything else the container asked for (D-45), resolved by the daemon. Absent in
    /// specs of shims from before it.
    var options: RunOptions?
}

/// A change to a running VM's NIC slot: the body of the shim's `POST /nic`. Traffic is
/// cut or allowed at the daemon's switch; this is the guest's view of it.
enum NICChange: Codable, Sendable, Equatable {
    /// Adds `address` to `ethN` unless it holds it already, brings the link up and, with a
    /// gateway, takes the default route.
    case up(slot: Int, address: String, gateway: String?)
    case down(slot: Int)
    /// Moves the default route to `ethN`.
    case route(slot: Int, gateway: String)

    var slot: Int {
        switch self {
        case .up(let slot, _, _), .down(let slot), .route(let slot, _): slot
        }
    }
}

struct ShimMount: Codable, Sendable, Equatable {
    var source: String
    var destination: String
    var readOnly: Bool
    /// A host Unix socket, relayed into the guest rather than shared.
    var socket = false
    /// A tmpfs in the guest's memory, with these mount options; nothing on the Mac.
    var tmpfs: [String]? = nil

    init(source: String, destination: String, readOnly: Bool, socket: Bool = false, tmpfs: [String]? = nil) {
        self.source = source
        self.destination = destination
        self.readOnly = readOnly
        self.socket = socket
        self.tmpfs = tmpfs
    }

    /// Specs written before socket mounts have no `socket`.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        source = try c.decode(String.self, forKey: .source)
        destination = try c.decode(String.self, forKey: .destination)
        readOnly = try c.decode(Bool.self, forKey: .readOnly)
        socket = try c.decodeIfPresent(Bool.self, forKey: .socket) ?? false
        tmpfs = try c.decodeIfPresent([String].self, forKey: .tmpfs)
    }
}

/// Files a shim keeps in its container directory (`<home>/containers/<id>`).
struct ShimFiles: Sendable {
    let dir: URL
    var spec: URL { dir.appending(path: "spec.json") }
    /// `<home>/run/<short id>.sock`: a path in the container directory would exceed the
    /// 104-byte Unix socket limit.
    var socket: URL {
        dir.deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "run/\(dir.lastPathComponent.prefix(12)).sock")
    }
    var state: URL { dir.appending(path: "state.json") }  // {"pid", "status": "starting|created|running|paused"}
    var exit: URL { dir.appending(path: "exit.json") }  // {"exitCode", "finishedAt"}; written last
    var log: URL { dir.appending(path: "log") }
    var shimLog: URL { dir.appending(path: "shim.log") }
}

// MARK: - Shim side

/// Runs one container's VM for its whole life, independent of the daemon: it boots the
/// VM, writes the container's output to the log, serves `shim.sock`, and records the exit
/// code in `exit.json` before exiting. A daemon restart does not touch it.
public enum ShimHost {
    /// The pipe `ShimClient.spawn` waits on: one byte once the container is created.
    static let readyFD: Int32 = 3

    public static func run(directory: String) async -> Int32 {
        let files = ShimFiles(dir: URL(filePath: directory, directoryHint: .isDirectory))
        func fail(_ message: String) -> Int32 {
            FileHandle.standardError.write(Data("pratico-shim: \(message)\n".utf8))
            writeExit(files, code: 127, error: message)
            return 1
        }
        guard let data = try? Data(contentsOf: files.spec), let spec = try? JSONDecoder().decode(ShimSpec.self, from: data) else {
            return fail("cannot read \(files.spec.path)")
        }
        writeJSON(["pid": .int(Int64(getpid())), "status": "starting"], to: files.state)
        var trace = Trace("shim \(spec.id)")

        let log = LogStore(path: files.log, maxBytes: spec.options?.logBytes ?? LogStore.defaultCap)
        let stdin = spec.openStdin ? StdinStream() : nil
        let interfaces: [SwitchNIC]
        do { interfaces = try relays(spec) } catch { return fail("cannot set up networking: \(error)") }
        trace.mark("nic relays")
        let container: LinuxContainer
        do {
            container = try await boot(spec, files: files, log: log, stdin: stdin, interfaces: interfaces, trace: &trace)
        } catch {
            log.finish()
            return fail("cannot start: \(error)")
        }
        // The VM is up; the process waits for the daemon's `POST /start`, so its ports are
        // bound and it reads as running before its first instruction, as in Docker.
        trace.mark("extra addresses, spare NICs down")
        writeJSON(["pid": .int(Int64(getpid())), "status": "created"], to: files.state)

        let term = stopOnSIGTERM(container, spec)
        let control = ShimControl(container: container, files: files, spec: spec, stdin: stdin)
        let server = HTTPServer(path: files.socket.path) { req, conn in control.handle(req, conn) }
        do {
            try FileManager.default.createDirectory(at: files.socket.deletingLastPathComponent(), withIntermediateDirectories: true)
            try server.start()
        } catch {
            // No control socket, no way for the daemon to start or stop it.
            log.finish()
            try? await container.stop()
            return fail("cannot serve \(files.socket.path): \(error)")
        }
        // Created and listening: wake the daemon's `spawn` (no-op for a shim it did not start).
        var one: UInt8 = 1
        _ = write(Self.readyFD, &one, 1)
        close(Self.readyFD)
        // A daemon that died before saying go leaves no VM behind.
        let go = await withCheckedContinuation { done in
            DispatchQueue.global().async { done.resume(returning: control.awaitStart()) }
        }
        trace.mark("waited for /start")
        if !go || control.startError.value != nil {
            log.finish()
            server.stop()
            try? await container.stop()
            return fail("cannot start: \(control.startError.value ?? "the daemon did not start the process")")
        }
        writeJSON(["pid": .int(Int64(getpid())), "status": "running"], to: files.state)

        let code: Int32
        do { code = try await container.wait().exitCode } catch { code = 137 }
        log.finish()
        try? await container.stop()
        server.stop()
        term.cancel()
        writeExit(files, code: code, error: "")
        return 0
    }

    /// One relay per card, which boots with its boot endpoint's address (D-43) and the
    /// card's own MAC (the switch shows the others, D-44).
    private static func relays(_ spec: ShimSpec) throws -> [SwitchNIC] {
        let relays = try spec.nics.cards.indices.map { n in
            let entry = spec.nics.bootEntry(card: n)
            var boot = spec.nics.slots[entry]
            boot.mac = spec.nics.cardMAC(of: entry)
            return try NICRelay.start(boot, switchSocket: spec.switchSocket, primary: entry == spec.nics.primary)
        }
        precondition(relays.count == spec.nics.cards.count, "a relay per card")
        return relays
    }

    /// Boots the VM and creates the container in it, its process not yet started.
    private static func boot(_ spec: ShimSpec, files: ShimFiles, log: LogStore, stdin: StdinStream?,
                             interfaces: [SwitchNIC], trace: inout Trace) async throws -> LinuxContainer {
        let vmm = VZVirtualMachineManager(
            kernel: Kernel(path: URL(filePath: spec.kernel), platform: .linuxArm),
            initialFilesystem: .block(format: "ext4", source: spec.initfs, destination: "/", options: ["ro"]))
        let rootfs = Mount.block(format: "ext4", source: spec.rootfs, destination: "/", options: spec.options?.readonlyRootfs == true ? ["ro"] : [])
        let resources = VMResources(cpus: spec.cpus, memoryInBytes: UInt64(spec.memoryMiB).mib() + VMResources.guestMemoryOverhead)
        let container = try LinuxContainer(spec.id, rootfs: rootfs, vmm: vmm, vm: resources) { config in
            try configure(&config, spec, files: files, log: log, stdin: stdin, interfaces: interfaces)
        }
        trace.mark("container configured")
        try await container.create()
        trace.mark("VM booted, container created")
        try await addCardAddresses(container, spec.nics)
        return container
    }

    /// The container's configuration from its spec: process, output, networking, DNS and
    /// hosts, run options, and mounts.
    private static func configure(_ config: inout LinuxContainer.Configuration, _ spec: ShimSpec, files: ShimFiles, log: LogStore,
                                  stdin: StdinStream?, interfaces: [SwitchNIC]) throws {
        precondition(spec.cpus >= 1 && spec.memoryMiB >= 64, "VM size below the minimum: \(spec.cpus) vCPUs, \(spec.memoryMiB) MiB")
        precondition(interfaces.count == spec.nics.cards.count, "a relay per card")
        config.cpus = spec.cpus
        config.memoryInBytes = UInt64(spec.memoryMiB).mib()
        config.hostname = spec.hostname
        // With PRATICO_TRACE, the guest kernel's console goes to boot.log beside shim.log.
        if Trace.on { config.bootLog = .file(path: files.dir.appending(path: "boot.log"), append: false) }
        config.process.arguments = spec.arguments
        config.process.environmentVariables = spec.environment
        config.process.workingDirectory = spec.workingDirectory.isEmpty ? "/" : spec.workingDirectory
        config.process.user = Self.user(spec.user)
        config.process.terminal = spec.tty
        config.process.stdout = LogWriter(log: log, stream: 1)
        // A terminal has one output stream; Containerization rejects a separate stderr.
        config.process.stderr = spec.tty ? nil : LogWriter(log: log, stream: 2)
        config.process.stdin = stdin
        config.interfaces = interfaces
        let primary = spec.nics.primaryNIC
        // pratico-net answers DNS at every gateway: container names, then the Mac's resolver.
        if let dns = Self.dns(spec, gateway: primary?.gateway) { config.dns = dns }
        let extra = spec.options?.extraHosts ?? []
        if primary != nil || !extra.isEmpty {
            var hosts = Hosts.default
            if let primary { hosts.entries.append(Hosts.Entry(ipAddress: primary.ip, hostnames: [spec.hostname])) }
            for e in extra { hosts.entries.append(Hosts.Entry(ipAddress: e.address, hostnames: [e.name])) }
            config.hosts = hosts
        }
        if let o = spec.options { try Self.apply(o, to: &config) }
        for m in spec.mounts {
            if m.socket {
                config.sockets.append(UnixSocketConfiguration(source: URL(filePath: m.source), destination: URL(filePath: m.destination), direction: .into))
            } else if let options = m.tmpfs {
                config.mounts.append(.any(type: "tmpfs", source: "tmpfs", destination: m.destination, options: options))
            } else {
                config.mounts.append(.share(source: m.source, destination: m.destination, options: m.readOnly ? ["ro"] : []))
            }
        }
    }

    /// A card's other networks are more addresses on it, added once the guest is up; spare
    /// cards (VMs from before D-43) stay link-down until the daemon connects them.
    private static func addCardAddresses(_ container: LinuxContainer, _ nics: NICSlots) async throws {
        let spares = nics.cards.indices.filter { nics.slots[nics.bootEntry(card: $0)].isSpare }
        guard nics.slots.count > nics.cards.count || !spares.isEmpty else { return }
        try await container.withVirtualMachineInstance { vm in
            let agent = try await vm.dialAgent()
            for n in nics.cards.indices {
                for i in nics.extraEntries(card: n) {
                    try await agent.addressAdd(name: "eth\(n)", address: InterfaceAddress(ipv4Address: try CIDRv4(nics.slots[i].address)))
                }
            }
            for n in spares { try await agent.down(name: "eth\(n)") }
            try await agent.close()
        }
    }

    /// SIGTERM to the shim (logout, shutdown, `kill`) stops the container as `docker stop`
    /// does, with its stop signal and timeout, so the normal exit path still records its code.
    private static func stopOnSIGTERM(_ container: LinuxContainer, _ spec: ShimSpec) -> DispatchSourceSignal {
        let stopSignal = Int32(Signals.number(spec.options?.stopSignal ?? "TERM") ?? 15)
        let stopTimeout = Double(spec.options?.stopTimeout ?? 10)
        signal(SIGTERM, SIG_IGN)
        let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
        term.setEventHandler {
            Task { try? await container.kill(Signal(rawValue: stopSignal)) }
            Self.killAfter(container, seconds: stopTimeout)
        }
        term.resume()
        return term
    }

    /// SIGKILL once the stop grace period is over; a negative one (`--stop-timeout -1`)
    /// waits for the process however long it takes, as on Docker.
    static func killAfter(_ container: LinuxContainer, seconds: Double) {
        guard seconds >= 0 else { return }
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
            Task { try? await container.kill(Signal(rawValue: 9)) }
        }
    }

    /// `--user` as given (`name`, `uid`, `name:group`, `uid:gid`): vminitd resolves it
    /// against the image's `/etc/passwd` and `/etc/group`.
    static func user(_ s: String) -> ContainerizationOCI.User {
        var u = ContainerizationOCI.User()
        u.username = s
        return u
    }

    /// The resolver: `--dns` and friends, else the primary network's gateway. nil with no
    /// network and no `--dns`.
    static func dns(_ spec: ShimSpec, gateway: String?) -> DNS? {
        let r = spec.options?.dns
        let servers = r.map(\.servers).flatMap { $0.isEmpty ? nil : $0 } ?? gateway.map { [$0] }
        guard let servers else { return nil }
        return DNS(nameservers: servers, searchDomains: r?.search ?? [], options: r?.options ?? [])
    }

    /// What a process in the container may do: the container's capabilities (every one
    /// with `privileged`, as `docker exec --privileged`), `no_new_privs`, rlimits, and
    /// groups. Execs and healthchecks get the same as the container's own process, as on
    /// Docker; without this an exec in a `--cap-drop ALL` container had the default set.
    static func secure(_ process: inout LinuxProcessConfiguration, _ o: RunOptions?, privileged: Bool) throws {
        if privileged {
            process.capabilities = .allCapabilities
        } else if let caps = o?.capabilities {
            process.capabilities = LinuxCapabilities(capabilities: try caps.map { try CapabilityName(rawValue: $0) })
        }
        guard let o else { return }
        process.noNewPrivileges = o.noNewPrivileges
        process.rlimits = try o.ulimits.map { LinuxRLimit(kind: try LinuxRLimit.Kind($0.kind), hard: $0.hard, soft: $0.soft) }
        process.user.additionalGids = o.groups.map { g in
            guard let gid = UInt32(g) else { preconditionFailure("group \(g) reached the shim unresolved") }
            return gid
        }
    }

    /// The container side of the run options (D-45): cgroup, sysctls, init, `/proc`
    /// masking, `/dev/shm`, and its process's security.
    static func apply(_ o: RunOptions, to config: inout LinuxContainer.Configuration) throws {
        config.unified = o.cgroup
        config.sysctl = o.sysctls
        config.useInit = o.useInit
        if o.unmaskedPaths {
            config.maskedPaths = []
            config.readonlyPaths = []
        }
        try secure(&config.process, o, privileged: false)
        if let shm = o.shmBytes, let i = config.mounts.firstIndex(where: { $0.destination == "/dev/shm" }) {
            config.mounts[i].options = config.mounts[i].options.filter { !$0.hasPrefix("size=") } + ["size=\(shm / 1024)k"]
        }
    }

    static func writeExit(_ files: ShimFiles, code: Int32, error: String) {
        writeJSON(["exitCode": .int(Int64(code)), "finishedAt": .string(Timestamp.format(Date())), "error": .string(error)],
                  to: files.exit)
    }

    static func writeJSON(_ value: JSON, to url: URL) {
        try? value.encoded().write(to: url, options: .atomic)
    }
}

/// The shim's control API on `shim.sock`, spoken only by the daemon.
final class ShimControl: Sendable {
    let container: LinuxContainer
    let files: ShimFiles
    let spec: ShimSpec
    let stdin: StdinStream?
    let execs = ExecTable()
    let addresses: GuestAddresses

    init(container: LinuxContainer, files: ShimFiles, spec: ShimSpec, stdin: StdinStream?) {
        self.container = container
        self.files = files
        self.spec = spec
        self.stdin = stdin
        // What each card holds: its boot address and the extra ones added after create.
        addresses = GuestAddresses(spec.nics.cards.indices.map(spec.nics.addresses(card:)))
    }

    /// Whether a host path stays inside `dir` once `.`/`..` and symlinks are resolved (the
    /// last component may not exist yet, so its parent is resolved).
    static func inside(_ path: String, _ dir: URL) -> Bool {
        let url = URL(filePath: path).standardizedFileURL
        guard !["", ".", ".."].contains(url.lastPathComponent) else { return false }
        let parent = url.deletingLastPathComponent().resolvingSymlinksInPath().path
        let root = dir.resolvingSymlinksInPath().path
        return parent == root || parent.hasPrefix(root + "/")
    }

    /// `state.json` tells a restarted daemon whether the VM is paused.
    private func record(_ status: String) {
        ShimHost.writeJSON(["pid": .int(Int64(getpid())), "status": .string(status)], to: files.state)
    }

    /// Signaled once `POST /start` ran the process, or failed to (`startError`).
    let started = DispatchSemaphore(value: 0)
    let startError = Box<String?>(nil)
    private let startLock = NSLock()
    private nonisolated(unsafe) var startOnce = false  // under startLock
    static let startPatience: TimeInterval = 120

    /// Blocks until `POST /start` came, up to `startPatience`; false if it never did.
    func awaitStart() -> Bool { started.wait(timeout: .now() + Self.startPatience) == .success }

    func handle(_ req: Request, _ conn: Connection) -> Disposition {
        let route = req.path.split(separator: "/").first.map(String.init) ?? ""
        do {
            if let done = try routeLifecycle(req.method, route, req, conn) ?? routeFiles(req.method, route, req, conn) ?? routeExecs(req.method, route, req, conn) {
                return done
            }
            conn.error(404, "shim: unknown \(req.method) \(req.path)")
        } catch let e as APIError {
            conn.error(e.status, "shim: \(e.message)")
        } catch {
            conn.error(500, "shim: \(error)")
        }
        return .close  // one request per connection; the client reads to EOF
    }

    /// The process and the VM: start, signals, stop, stdin, terminal size, NICs, pause.
    private func routeLifecycle(_ method: String, _ route: String, _ req: Request, _ conn: Connection) throws -> Disposition? {
        let c = container
        switch (method, route) {
        case ("POST", "start"):
            let first = startLock.withLock { () -> Bool in
                defer { startOnce = true }
                return !startOnce
            }
            guard first else { throw APIError(409, "already started") }
            defer { started.signal() }
            var trace = Trace("shim /start")
            defer { trace.mark("process started") }
            do { try blocking { try await c.start() } } catch {
                startError.value = "\(error)"
                throw APIError(500, "\(error)")
            }
        case ("POST", "kill"):
            let sig = Int32(req.query["signal"] ?? "") ?? 9
            try blocking { try await c.kill(Signal(rawValue: sig)) }
        case ("POST", "stop"):
            // The stop signal, then SIGKILL after the grace period, as `docker stop`.
            let grace = Double(req.query["t"] ?? "") ?? 10
            let signal = Int32(req.query["signal"] ?? "") ?? 15
            try blocking { try await c.kill(Signal(rawValue: signal)) }
            ShimHost.killAfter(c, seconds: grace)
        case ("POST", "stdin"):
            // Raw bytes into the process's stdin until the client closes its side.
            guard let stdin else { throw APIError(409, "container was created without OpenStdin") }
            conn.hijack(contentType: "application/octet-stream")
            Thread.detachNewThread {
                while let data = conn.readRaw() { stdin.feed(data) }
                stdin.finish()
                conn.close()
            }
            return .detached
        case ("POST", "resize"):
            let w = UInt16(req.query["w"] ?? "") ?? 0
            let h = UInt16(req.query["h"] ?? "") ?? 0
            if w > 0 && h > 0 { try blocking { try await c.resize(to: Terminal.Size(width: w, height: h)) } }
        case ("POST", "nic"):
            guard let change = try? JSONDecoder().decode(NICChange.self, from: req.body) else { throw APIError(400, "not a NIC change") }
            try nic(change)
        case ("POST", "sync"):
            // Flushes the guest's page cache to its disk image, so the Mac reads what it wrote.
            try blocking {
                try await c.withVirtualMachineInstance { vm in
                    let agent = try await vm.dialAgent()
                    defer { Task { try? await agent.close() } }
                    try await agent.sync()
                }
            }
        case ("POST", "pause"):
            try blocking { try await c.withVirtualMachineInstance { try await $0.pause() } }
            record("paused")
        case ("POST", "resume"):
            try blocking { try await c.withVirtualMachineInstance { try await $0.resume() } }
            record("running")
        default:
            return nil
        }
        conn.respond(204)
        return .close
    }

    /// Files between the guest and paths inside this container's directory, and stats.
    private func routeFiles(_ method: String, _ route: String, _ req: Request, _ conn: Connection) throws -> Disposition? {
        let c = container
        switch (method, route) {
        case ("POST", "copy-out"):
            // Guest path → host path the daemon chose inside this container's directory.
            guard let src = req.query["src"], let dst = req.query["dst"], Self.inside(dst, files.dir) else {
                throw APIError(400, "copy-out needs src and a dst in the container directory")
            }
            try blocking { try await c.copyOut(from: URL(filePath: src), to: URL(filePath: dst)) }
        case ("POST", "copy-in"):
            guard let src = req.query["src"], Self.inside(src, files.dir), let dst = req.query["dst"] else {
                throw APIError(400, "copy-in needs a src in the container directory and dst")
            }
            let mode = UInt32(req.query["mode"] ?? "", radix: 8) ?? 0o644
            try blocking { try await c.copyIn(from: URL(filePath: src), to: URL(filePath: dst), mode: mode) }
        case ("GET", "stats"):
            let st = try blocking { try await c.statistics() }
            conn.json(200, Self.statsRecord(st))
            return .close
        default:
            return nil
        }
        conn.respond(204)
        return .close
    }

    /// `docker exec` and healthchecks.
    private func routeExecs(_ method: String, _ route: String, _ req: Request, _ conn: Connection) throws -> Disposition? {
        switch (method, route) {
        case ("POST", "exec"):
            conn.json(200, try run(JSON.parse(req.body) ?? [:]))
        case ("POST", "exec-stream"):
            try stream(JSON.parse(req.body) ?? [:], conn)
            return .detached
        case ("GET", "exec-status"):
            let id = req.query["id"] ?? ""
            guard let entry = execs.get(id) else { throw APIError(404, "no exec \(id)") }
            conn.json(200, ["running": .bool(entry.exitCode == nil), "exitCode": entry.exitCode.map { .int(Int64($0)) } ?? .null])
        case ("POST", "exec-resize"):
            let w = UInt16(req.query["w"] ?? "") ?? 0
            let h = UInt16(req.query["h"] ?? "") ?? 0
            if let p = execs.get(req.query["id"] ?? "")?.process, w > 0, h > 0 {
                try blocking { try await p.resize(to: Terminal.Size(width: w, height: h)) }
            }
            conn.respond(204)
        default:
            return nil
        }
        return .close
    }
}

/// The addresses each slot's guest interface holds. The agent cannot delete one, and
/// adding one twice fails, so the shim remembers them.
final class GuestAddresses: @unchecked Sendable {
    private let lock = NSLock()
    private var held: [Set<String>]

    init(_ boot: [[String]]) { held = boot.map(Set.init) }

    /// True when `address` is new on `slot` (the caller adds it).
    func claim(_ slot: Int, _ address: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return held[slot].insert(address).inserted
    }

    func release(_ slot: Int, _ address: String) {
        lock.lock()
        held[slot].remove(address)
        lock.unlock()
    }
}

extension ShimControl {
    /// Hot connect and disconnect (`docker network connect`), as the guest sees them.
    func nic(_ change: NICChange) throws {
        let slot = change.slot
        guard spec.nics.cards.indices.contains(slot) else { throw APIError(400, "shim: no NIC \(slot)") }
        let name = "eth\(slot)"
        let addresses = addresses
        let rootfs = "/run/container/\(spec.id)/rootfs"
        let spec = spec
        try blocking { [container] in
            try await container.withVirtualMachineInstance { vm in
                let agent = try await vm.dialAgent()
                defer { Task { try? await agent.close() } }
                // `gateway` becomes the default route and the DNS server. Bouncing the link
                // drops the old default route (vminitd has no route delete) and keeps the
                // addresses and their subnet routes; the new default takes its source from
                // the gateway's subnet. resolv.conf must follow (unless `--dns` set it): the
                // container's old address stays on the card, and the switch drops what it sends.
                func primary(_ gateway: String) async throws {
                    try await agent.down(name: name)
                    try await agent.up(name: name, mtu: 1500)
                    try await agent.routeAddDefault(name: name, route: DefaultRoute(ipv4Gateway: try IPv4Address(gateway)))
                    if let dns = ShimHost.dns(spec, gateway: gateway) { try await agent.configureDNS(config: dns, location: rootfs) }
                }
                switch change {
                case .up(_, let address, let gateway):
                    let cidr = try CIDRv4(address)
                    if addresses.claim(slot, address) {
                        do { try await agent.addressAdd(name: name, address: InterfaceAddress(ipv4Address: cidr)) } catch {
                            addresses.release(slot, address)
                            throw error
                        }
                    }
                    if let gateway { try await primary(gateway) } else { try await agent.up(name: name, mtu: 1500) }
                case .down:
                    try await agent.down(name: name)
                case .route(_, let gateway):
                    try await primary(gateway)
                }
            }
        }
    }

    /// One-shot exec with captured output, for healthchecks and `docker top`:
    /// `{"args": [...], "timeout": seconds, "limit": bytes}` → `{"exitCode", "output"}`;
    /// -1 on timeout.
    func run(_ body: JSON) throws -> JSON {
        let args = body["args"]?.strings ?? []
        guard !args.isEmpty else { throw APIError(400, "shim: exec needs args") }
        let timeout = Int64(body["timeout"]?.int ?? 30)
        let c = container
        let spec = spec
        // Docker keeps 4 KiB of probe output; `docker top` asks for more, up to 1 MiB.
        let limit = Int(body["limit"]?.int ?? 4096)
        guard (1...(1 << 20)).contains(limit) else { throw APIError(400, "shim: exec output limit \(limit) out of range") }
        let output = CollectingWriter(limit: limit)
        let id = "exec-\(randomHexID().prefix(12))"
        let code: Int32 = try blocking {
            let p = try await c.exec(id) { cfg in
                cfg.arguments = args
                cfg.environmentVariables = spec.environment
                cfg.workingDirectory = spec.workingDirectory.isEmpty ? "/" : spec.workingDirectory
                cfg.user = ShimHost.user(spec.user)
                try ShimHost.secure(&cfg, spec.options, privileged: false)
                cfg.stdout = output
                cfg.stderr = output
            }
            try await p.start()
            defer { Task { try? await p.delete() } }
            do {
                return try await p.wait(timeoutInSeconds: timeout).exitCode
            } catch {
                try? await p.kill(Signal(rawValue: 9))
                return -1
            }
        }
        let text = code == -1 ? "Health check exceeded timeout (\(timeout)s)" : String(decoding: output.data, as: UTF8.self)
        return ["exitCode": .int(Int64(code)), "output": .string(text)]
    }
}

extension ShimControl {
    /// Agent statistics under the keys Apple's `container stats` uses, so the daemon's
    /// sampler and Docker encoder serve both runtimes.
    static func statsRecord(_ s: ContainerStatistics) -> JSON {
        let rx = s.networks?.reduce(UInt64(0)) { $0 + $1.receivedBytes } ?? 0
        let tx = s.networks?.reduce(UInt64(0)) { $0 + $1.transmittedBytes } ?? 0
        let rd = s.blockIO?.devices.reduce(UInt64(0)) { $0 + $1.readBytes } ?? 0
        let wr = s.blockIO?.devices.reduce(UInt64(0)) { $0 + $1.writeBytes } ?? 0
        func n(_ v: UInt64?) -> JSON { .int(Int64(clamping: v ?? 0)) }
        return [
            "cpuUsageUsec": n(s.cpu?.usageUsec), "numProcesses": n(s.process?.current),
            "memoryUsageBytes": n(s.memory?.usageBytes), "memoryLimitBytes": n(s.memory?.limitBytes),
            "networkRxBytes": n(rx), "networkTxBytes": n(tx), "blockReadBytes": n(rd), "blockWriteBytes": n(wr),
        ]
    }
}

/// Running and finished execs, by Docker exec ID.
final class ExecTable: @unchecked Sendable {
    struct Entry {
        var process: LinuxProcess?
        var exitCode: Int32?
    }
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    func get(_ id: String) -> Entry? {
        lock.lock()
        defer { lock.unlock() }
        return entries[id]
    }

    func set(_ id: String, _ change: (inout Entry) -> Void) {
        lock.lock()
        var e = entries[id] ?? Entry()
        change(&e)
        entries[id] = e
        lock.unlock()
    }
}

/// Exec output straight onto a hijacked connection, framed as Docker frames it.
struct ConnWriter: Writer {
    let conn: Connection
    let stream: UInt8
    let raw: Bool
    func write(_ data: Data) throws { _ = conn.write(raw ? data : StdCopy.frame(stream: stream, data)) }
    func close() throws {}
}

/// Discards output a client did not attach to.
struct NullWriter: Writer {
    func write(_ data: Data) throws {}
    func close() throws {}
}

extension ShimControl {
    /// `docker exec` streamed: `{"id", "args", "env", "workdir", "user", "tty", "stdin",
    /// "stdout", "stderr", "height", "width"}`. The connection carries Docker's raw (TTY)
    /// or multiplexed stream, takes stdin until the client half-closes, and closes when the
    /// process exits; its code is then at `/exec-status`.
    func stream(_ body: JSON, _ conn: Connection) throws {
        guard let id = body["id"]?.string, let args = body["args"]?.strings, !args.isEmpty else {
            throw APIError(400, "shim: exec needs id and args")
        }
        let tty = body["tty"]?.bool ?? false
        let wantStdout = body["stdout"]?.bool ?? true
        let wantStderr = body["stderr"]?.bool ?? true
        let input = (body["stdin"]?.bool ?? false) ? StdinStream() : nil
        let env = spec.environment + (body["env"]?.strings ?? [])
        let workdir = body["workdir"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? (spec.workingDirectory.isEmpty ? "/" : spec.workingDirectory)
        let user = body["user"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? spec.user
        let privileged = body["privileged"]?.bool ?? false
        let options = spec.options
        let c = container
        let process = try blocking {
            try await c.exec(id) { cfg in
                cfg.arguments = args
                cfg.environmentVariables = env
                cfg.workingDirectory = workdir
                cfg.user = ShimHost.user(user)
                try ShimHost.secure(&cfg, options, privileged: privileged)
                cfg.terminal = tty
                cfg.stdin = input
                let out: any Writer = wantStdout ? ConnWriter(conn: conn, stream: 1, raw: tty) : NullWriter()
                let err: any Writer = wantStderr ? ConnWriter(conn: conn, stream: 2, raw: false) : NullWriter()
                cfg.stdout = out
                cfg.stderr = tty ? nil : err
            }
        }
        conn.hijack(contentType: tty ? "application/vnd.docker.raw-stream" : "application/vnd.docker.multiplexed-stream")
        execs.set(id) { $0.process = process }
        do {
            try blocking { try await process.start() }
        } catch {
            // The stream is already switched: report in it, with Docker's code for a
            // command that cannot run.
            let missing = "\(error)".contains("failed to find target executable")
            let detail = missing ? "exec: \"\(args[0])\": executable file not found in $PATH" : "\(error)"
            let msg = Data("OCI runtime exec failed: exec failed: unable to start container process: \(detail): unknown\n".utf8)
            _ = conn.write(tty ? msg : StdCopy.frame(stream: 2, msg))
            execs.set(id) {
                $0.exitCode = 127
                $0.process = nil
            }
            try? blocking { try await process.delete() }
            conn.close()
            return
        }
        if tty, let h = body["height"]?.int, let w = body["width"]?.int, h > 0, w > 0 {
            try? blocking { try await process.resize(to: Terminal.Size(width: UInt16(clamping: w), height: UInt16(clamping: h))) }
        }
        if let input {
            Thread.detachNewThread {
                while let data = conn.readRaw() { input.feed(data) }
                input.finish()
            }
        }
        let execs = execs
        Thread.detachNewThread {
            let code = (try? blocking { try await process.wait().exitCode }) ?? 137
            try? blocking { try await process.delete() }
            execs.set(id) {
                $0.exitCode = code
                $0.process = nil
            }
            conn.close()
        }
    }
}

/// What attached clients type, as the process's stdin.
final class StdinStream: ReaderStream, @unchecked Sendable {
    private let stream_: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation

    init() { (stream_, continuation) = AsyncStream.makeStream(of: Data.self) }

    func stream() -> AsyncStream<Data> { stream_ }
    func feed(_ data: Data) { continuation.yield(data) }
    func finish() { continuation.finish() }
}

/// Container output into the log, line-framed by `LogStore`.
struct LogWriter: Writer {
    let log: LogStore
    let stream: UInt8
    func write(_ data: Data) throws { log.append(stream: stream, data) }
    func close() throws {}
}

// MARK: - Daemon side

/// The daemon's handle on shims: spawn, control, and exit tracking (docs/design/runtime.md).
struct ShimClient: Sendable {
    let binary: String

    /// `pratico-shim` next to the daemon (both live in `Contents/MacOS`).
    static func locate() -> String? {
        let candidates = [ProcessInfo.processInfo.environment["PRATICO_SHIM_BIN"],
                          Bundle.main.executableURL?.deletingLastPathComponent().appending(path: "pratico-shim").path]
        return candidates.compactMap { $0 }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Starts a shim in its own session, so it outlives the daemon, and waits until the
    /// container runs or has already exited.
    func spawn(_ files: ShimFiles) throws -> pid_t {
        for f in [files.exit, files.state, files.socket] { try? FileManager.default.removeItem(at: f) }
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        // CLOEXEC_DEFAULT: the shim gets only the descriptors below. Without it, it would
        // inherit the daemon's API connections and published-port listeners, which then
        // outlive a daemon restart.
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, files.shimLog.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        posix_spawn_file_actions_adddup2(&actions, 1, 2)
        // fd 3: the shim writes a byte once the container is created (`ShimHost.readyFD`),
        // and the pipe ends when it exits; either wakes the wait below, without polling.
        var ready: [Int32] = [-1, -1]
        guard pipe(&ready) == 0 else { throw APIError(500, "cannot create a pipe for pratico-shim") }
        defer { close(ready[0]) }
        posix_spawn_file_actions_adddup2(&actions, ready[1], ShimHost.readyFD)
        let argv = [binary, files.dir.path]
        var cargs = argv.map { strdup($0) } + [nil]
        defer { cargs.forEach { free($0) } }
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, binary, &actions, &attr, &cargs, environ)
        close(ready[1])
        guard rc == 0 else { throw APIError(500, "cannot start pratico-shim: \(String(cString: strerror(rc)))") }

        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline {
            var p = pollfd(fd: ready[0], events: Int16(POLLIN), revents: 0)
            _ = poll(&p, 1, Int32(max(deadline.timeIntervalSinceNow, 0) * 1000))
            if FileManager.default.fileExists(atPath: files.exit.path) { break }
            if ["created", "running", "paused"].contains(Self.read(files.state)?["status"]?.string),
                FileManager.default.fileExists(atPath: files.socket.path)
            { break }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return pid
    }

    /// Calls once when the shim process ends (also for shims from an earlier daemon).
    func onExit(_ pid: pid_t, _ handler: @escaping @Sendable () -> Void) {
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .global())
        let fired = Box(false)
        source.setEventHandler {
            guard !fired.value else { return }
            fired.value = true
            source.cancel()
            handler()
        }
        source.resume()
        if kill(pid, 0) != 0 && errno == ESRCH, !fired.value {  // exited before the source armed
            fired.value = true
            source.cancel()
            handler()
        }
    }

    /// The live shim's pid, if any.
    static func livePid(_ files: ShimFiles) -> pid_t? {
        guard let pid = read(files.state)?["pid"]?.int.map({ pid_t($0) }), pid > 0, kill(pid, 0) == 0,
            !FileManager.default.fileExists(atPath: files.exit.path)
        else { return nil }
        return pid
    }

    static func exitStatus(_ files: ShimFiles) -> (code: Int, error: String, finishedAt: Date?)? {
        guard let j = read(files.exit) else { return nil }
        return (Int(j["exitCode"]?.int ?? 0), j["error"]?.string ?? "", j["finishedAt"]?.string.flatMap(Timestamp.parse))
    }

    static func read(_ url: URL) -> JSON? { (try? Data(contentsOf: url)).flatMap(JSON.parse) }

    /// One request on the shim's control socket.
    @discardableResult
    func call(_ files: ShimFiles, _ method: String, _ path: String) throws -> Int {
        try request(files, method, path).status
    }

    /// One request with an optional JSON body; returns status and body.
    func request(_ files: ShimFiles, _ method: String, _ path: String, body: Data = Data()) throws -> (status: Int, body: Data) {
        let fd = try connectSocket(files)
        defer { close(fd) }
        var request = Data("\(method) \(path) HTTP/1.1\r\nHost: shim\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
        request.append(body)
        _ = request.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        var buf = [UInt8](repeating: 0, count: 4096)
        var response = Data()
        while case let n = Darwin.read(fd, &buf, buf.count), n > 0 { response.append(contentsOf: buf[0..<n]) }
        let headEnd = response.range(of: Data("\r\n\r\n".utf8))
        let head = String(decoding: response[..<(headEnd?.lowerBound ?? response.endIndex)], as: UTF8.self)
        let payload = headEnd.map { response[$0.upperBound...] } ?? Data()
        let status = Int(head.split(separator: " ").dropFirst().first ?? "") ?? 500
        guard status < 300 else {
            throw APIError(status, JSON.parse(Data(payload))?["message"]?.string ?? String(decoding: payload, as: UTF8.self))
        }
        return (status, Data(payload))
    }

    /// A hijacked raw stream (`/stdin`, `/exec-stream`): returns the socket once the shim
    /// switched protocols.
    func openStream(_ files: ShimFiles, _ path: String, body: Data = Data()) throws -> Int32 {
        let fd = try connectSocket(files)
        var request = Data("POST \(path) HTTP/1.1\r\nHost: shim\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\n\r\n".utf8)
        request.append(body)
        _ = request.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        var head = Data()
        var byte: UInt8 = 0
        while head.count < 4096, Darwin.read(fd, &byte, 1) == 1 {
            head.append(byte)
            if head.suffix(4) == Data("\r\n\r\n".utf8) { break }
        }
        let text = String(decoding: head, as: UTF8.self)
        guard text.hasPrefix("HTTP/1.1 101") else {
            // An error reply: relay its status and message.
            let status = Int(text.split(separator: " ").dropFirst().first ?? "") ?? 500
            let length = text.split(separator: "\r\n").first { $0.lowercased().hasPrefix("content-length:") }
                .flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) } ?? 0
            var body = [UInt8](repeating: 0, count: min(max(length, 0), 65536))
            var got = 0
            while got < body.count, case let n = Darwin.read(fd, &body[got], body.count - got), n > 0 { got += n }
            close(fd)
            throw APIError(status, JSON.parse(Data(body[0..<got]))?["message"]?.string ?? "shim refused \(path)")
        }
        return fd
    }

    private func connectSocket(_ files: ShimFiles) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw APIError(500, "shim: socket failed") }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let sockPath = files.socket.path
        guard sockPath.utf8.count < MemoryLayout.size(ofValue: addr.sun_path) else { throw APIError(500, "shim: socket path too long") }
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            buf.copyBytes(from: sockPath.utf8)
            buf[sockPath.utf8.count] = 0
        }
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard ok == 0 else {
            close(fd)
            throw APIError(409, "container is not running (shim unreachable)")
        }
        return fd
    }
}
