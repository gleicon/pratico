import Containerization
import ContainerizationOCI
import ContainerizationExtras
import ContainerizationOS
import Foundation
import Synchronization

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
    /// An ext4 disk image attached as a block device (a disk volume, D-49).
    var block: Bool? = nil

    init(source: String, destination: String, readOnly: Bool, socket: Bool = false, tmpfs: [String]? = nil, block: Bool = false) {
        self.source = source
        self.destination = destination
        self.readOnly = readOnly
        self.socket = socket
        self.tmpfs = tmpfs
        self.block = block ? true : nil
    }

    /// Specs written before socket mounts have no `socket`.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        source = try c.decode(String.self, forKey: .source)
        destination = try c.decode(String.self, forKey: .destination)
        readOnly = try c.decode(Bool.self, forKey: .readOnly)
        socket = try c.decodeIfPresent(Bool.self, forKey: .socket) ?? false
        tmpfs = try c.decodeIfPresent([String].self, forKey: .tmpfs)
        block = try c.decodeIfPresent(Bool.self, forKey: .block)
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
        config.seccompProfile = try Self.seccomp(spec.options)
        for m in spec.mounts {
            if m.socket {
                config.sockets.append(UnixSocketConfiguration(source: URL(filePath: m.source), destination: URL(filePath: m.destination), direction: .into))
            } else if let options = m.tmpfs {
                config.mounts.append(.any(type: "tmpfs", source: "tmpfs", destination: m.destination, options: options))
            } else if m.block == true {
                config.mounts.append(.block(format: "ext4", source: m.source, destination: m.destination, options: m.readOnly ? ["ro"] : []))
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

    /// The container's seccomp filter (D-54); a container with no options gets Docker's default.
    static func seccomp(_ o: RunOptions?) throws -> LinuxContainer.Configuration.SeccompProfile {
        switch o?.seccomp ?? .default {
        case .default: return .default
        case .unconfined: return .unconfined
        case .profile(let json): return .profile(try RunOptions.seccompProfile(json, capabilities: o?.capabilities))
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
    /// What the guest's cgroup holds now (the spec's, then each `POST /limits`), and
    /// whether the VM is paused: one lock, so limits are never written to a paused VM.
    let guest: Mutex<GuestState>

    init(container: LinuxContainer, files: ShimFiles, spec: ShimSpec, stdin: StdinStream?) {
        self.container = container
        self.files = files
        self.spec = spec
        self.stdin = stdin
        guest = Mutex(GuestState(limits: CgroupLimits(cpus: spec.cpus, memoryMiB: spec.memoryMiB, cgroup: spec.options?.cgroup ?? [:])))
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

    /// The process and the VM: start, signals, stop, stdin, terminal size, NICs, limits,
    /// pause.
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
        case ("POST", "limits"):
            guard let new = try? JSONDecoder().decode(CgroupLimits.self, from: req.body) else { throw APIError(400, "not cgroup limits") }
            try setLimits(new)
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
            try guest.withLock { state in
                try blocking { try await c.withVirtualMachineInstance { try await $0.pause() } }
                state.paused = true
            }
            record("paused")
        case ("POST", "resume"):
            try guest.withLock { state in
                try blocking { try await c.withVirtualMachineInstance { try await $0.resume() } }
                state.paused = false
            }
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
