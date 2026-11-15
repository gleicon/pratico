import Containerization
import ContainerizationOS
import Foundation

/// What a container's create request asks of its VM and process beyond image, command,
/// mounts, ports and networks, read once from `HostConfig` and `Config` (SPEC D-45).
/// Every Docker option pratico accepts is applied from here; an option it cannot apply is
/// refused when set, so no setting is ever dropped. `create` validates, `start` applies
/// (the daemon what it owns, the shim the rest through `ShimSpec.options`).
struct RunOptions: Codable, Sendable, Equatable {
    /// The VM's vCPUs; `cgroup["cpu.max"]` holds a fractional `--cpus`.
    var cpus: Int
    var memoryMiB: Int
    /// cgroup v2 files the guest writes for the container (`cpu.max`, `cpu.weight`,
    /// `cpuset.cpus`, `pids.max`, `memory.low`, `memory.swap.max`).
    var cgroup: [String: String] = [:]
    /// Capability names (`CAP_…`); nil is Docker's default set.
    var capabilities: [String]?
    /// `--privileged` and `systempaths=unconfined`: no masked or read-only `/proc` paths.
    var unmaskedPaths = false
    var noNewPrivileges = false
    var readonlyRootfs = false
    var sysctls: [String: String] = [:]
    var ulimits: [Ulimit] = []
    var shmBytes: Int64?
    /// `--group-add`: names or numeric IDs, looked up in the image's `/etc/group` at start.
    var groups: [String] = []
    /// `--dns` and friends; nil leaves DNS to pratico-net's gateways.
    var dns: Resolver?
    /// `--add-host` entries; `host-gateway` is the gateway, filled in at start.
    var extraHosts: [HostEntry] = []
    var useInit = false
    var stopSignal = "SIGTERM"
    var stopTimeout = 10
    var restart = RestartPolicy()
    var logBytes = LogStore.defaultCap

    struct Ulimit: Codable, Sendable, Equatable {
        var kind: String  // RLIMIT_…
        var soft: UInt64
        var hard: UInt64
    }

    struct Resolver: Codable, Sendable, Equatable {
        var servers: [String] = []
        var search: [String] = []
        var options: [String] = []
    }

    struct HostEntry: Codable, Sendable, Equatable {
        var name: String
        var address: String
    }

    struct RestartPolicy: Codable, Sendable, Equatable {
        /// `no`, `always`, `unless-stopped`, or `on-failure`.
        var name = "no"
        /// `on-failure` only; 0 is no limit.
        var maxRetries = 0
    }

    init(cpus: Int, memoryMiB: Int) {
        self.cpus = cpus
        self.memoryMiB = memoryMiB
    }
}

extension RunOptions {
    /// Parses and checks a create request. Throws Docker's 400 for a value Docker refuses,
    /// and pratico's for an option it does not apply.
    static func parse(host: JSON, config: JSON, defaultCPUs: Int, defaultMemoryMiB: Int) throws -> RunOptions {
        try refuseUnsupported(host: host, config: config)
        let memory = host["Memory"]?.int ?? 0
        var o = RunOptions(cpus: defaultCPUs, memoryMiB: memory > 0 ? max(Int(memory / 1_048_576), 64) : defaultMemoryMiB)
        try o.parseCPU(host)
        try o.parseMemory(host, memory: memory)
        try o.parseSecurity(host)
        try o.parseProcess(host, config: config)
        try o.parseLifecycle(host, config: config)
        precondition(o.cpus >= 1 && o.memoryMiB >= 64, "VM below its minimum: \(o.cpus) vCPUs, \(o.memoryMiB) MiB")
        precondition(o.capabilities.map { !$0.contains("ALL") } ?? true, "ALL must be expanded")
        return o
    }

    private mutating func parseCPU(_ host: JSON) throws {
        let nano = host["NanoCpus"]?.int ?? 0
        let quota = host["CpuQuota"]?.int ?? 0
        let period = host["CpuPeriod"]?.int ?? 0
        if nano > 0 && (quota > 0 || period > 0) {
            throw APIError(400, "Conflicting options: Nano CPUs and CPU Period cannot both be set")
        }
        if nano > 0 {
            cpus = Int((nano + 999_999_999) / 1_000_000_000)
            cgroup["cpu.max"] = "\(nano / 10_000) 100000"
        } else if quota > 0 {
            let p = period > 0 ? period : 100_000
            guard (1_000...1_000_000).contains(p) else { throw APIError(400, "CPU cfs period can not be less than 1ms (i.e. 1000) or larger than 1s (i.e. 1000000)") }
            guard quota >= 1_000 else { throw APIError(400, "CPU cfs quota can not be less than 1ms (i.e. 1000)") }
            cpus = Int((quota + p - 1) / p)
            cgroup["cpu.max"] = "\(quota) \(p)"
        } else if period > 0 {
            throw APIError(400, "pratico: --cpu-period needs --cpu-quota")
        }
        if let shares = host["CpuShares"]?.int, shares > 0 {
            // runc's conversion of cgroup v1 shares to v2 weight.
            let s = min(max(shares, 2), 262_144)
            cgroup["cpu.weight"] = "\(1 + ((s - 2) * 9_999) / 262_142)"
        }
        if let set = host["CpusetCpus"]?.string, !set.isEmpty {
            guard let ids = Self.cpuList(set) else { throw APIError(400, "Invalid value \(set) for cpuset cpus") }
            guard ids.allSatisfy({ $0 < cpus }) else {
                throw APIError(400, "Requested CPUs are not available - requested \(set), available: 0-\(cpus - 1)")
            }
            cgroup["cpuset.cpus"] = set
        }
        if let mems = host["CpusetMems"]?.string, !mems.isEmpty, mems != "0" {
            throw APIError(400, "Requested memory nodes are not available - requested \(mems), available: 0")
        }
    }

    /// `0-2,4` → [0, 1, 2, 4]; nil when malformed.
    static func cpuList(_ s: String) -> [Int]? {
        var out: [Int] = []
        for part in s.split(separator: ",", omittingEmptySubsequences: false) {
            let ends = part.split(separator: "-", omittingEmptySubsequences: false).map { Int($0) }
            switch ends.count {
            case 1: guard let a = ends[0], a >= 0 else { return nil }; out.append(a)
            case 2: guard let a = ends[0], let b = ends[1], a >= 0, a <= b else { return nil }; out += Array(a...b)
            default: return nil
            }
        }
        return out
    }

    private mutating func parseMemory(_ host: JSON, memory: Int64) throws {
        if let low = host["MemoryReservation"]?.int, low > 0 {
            if memory > 0 && low > memory {
                throw APIError(400, "Minimum memory limit can not be less than memory reservation limit, see usage")
            }
            cgroup["memory.low"] = "\(low)"
        }
        if let swap = host["MemorySwap"]?.int, swap != 0 {
            if swap == -1 {
                cgroup["memory.swap.max"] = "max"
            } else {
                guard memory > 0 else { throw APIError(400, "You should always set the Memory limit when using Memoryswap limit, see usage") }
                guard swap >= memory else { throw APIError(400, "Minimum memoryswap limit should be larger than memory limit, see usage") }
                cgroup["memory.swap.max"] = "\(swap - memory)"
            }
        }
        if let pids = host["PidsLimit"]?.int, pids > 0 { cgroup["pids.max"] = "\(pids)" }
        if let shm = host["ShmSize"]?.int, shm > 0 { shmBytes = shm }
    }

    private mutating func parseSecurity(_ host: JSON) throws {
        if host["Privileged"]?.bool == true {
            capabilities = CapabilityName.allCases.map(\.description)
            unmaskedPaths = true
        } else {
            let add = try (host["CapAdd"]?.strings ?? []).map(Self.capability)
            let drop = try (host["CapDrop"]?.strings ?? []).map(Self.capability)
            if !add.isEmpty || !drop.isEmpty {
                let all = CapabilityName.allCases.map(\.description)
                let base = drop.contains("ALL") ? [] : Self.defaultCapabilities.filter { !drop.contains($0) }
                capabilities = add.contains("ALL") ? all.filter { !drop.contains($0) || add.contains($0) } : Array(Set(base + add)).sorted()
            }
        }
        for opt in host["SecurityOpt"]?.strings ?? [] {
            let (key, value) = Self.securityOpt(opt)
            switch (key, value) {
            case ("no-new-privileges", "" ), ("no-new-privileges", "true"): noNewPrivileges = true
            case ("no-new-privileges", "false"): noNewPrivileges = false
            case ("systempaths", "unconfined"): unmaskedPaths = true
            // pratico runs no seccomp, AppArmor, or SELinux policy: the VM is the boundary.
            case ("seccomp", "unconfined"), ("apparmor", "unconfined"), ("label", "disable"): break
            case ("seccomp", _), ("apparmor", _), ("label", _):
                throw APIError(400, "pratico: --security-opt \(opt) is not supported: pratico applies no \(key) policy inside the VM; only \(key)=\(key == "label" ? "disable" : "unconfined") is accepted")
            default:
                throw APIError(400, "pratico: --security-opt \(opt) is not supported")
            }
        }
        readonlyRootfs = host["ReadonlyRootfs"]?.bool ?? false
    }

    /// Docker's `CAP_X`, `X`, or `ALL`, as `CAP_X` or `ALL`.
    private static func capability(_ s: String) throws -> String {
        if s.uppercased() == "ALL" { return "ALL" }
        do { return try CapabilityName(rawValue: s).description } catch { throw APIError(400, "invalid capability: \(s)") }
    }

    /// Docker's default capabilities (Docker Engine 25+, the same as containerd's).
    static let defaultCapabilities = [
        "CAP_AUDIT_WRITE", "CAP_CHOWN", "CAP_DAC_OVERRIDE", "CAP_FOWNER", "CAP_FSETID", "CAP_KILL", "CAP_MKNOD",
        "CAP_NET_BIND_SERVICE", "CAP_NET_RAW", "CAP_SETFCAP", "CAP_SETGID", "CAP_SETPCAP", "CAP_SETUID", "CAP_SYS_CHROOT",
    ]

    /// `key=value`, `key:value` (older CLIs), or a bare `key`.
    private static func securityOpt(_ s: String) -> (String, String) {
        guard let i = s.firstIndex(where: { $0 == "=" || $0 == ":" }) else { return (s, "") }
        return (String(s[..<i]), String(s[s.index(after: i)...]))
    }

    private mutating func parseProcess(_ host: JSON, config: JSON) throws {
        sysctls = (host["Sysctls"]?.object ?? [:]).compactMapValues(\.string)
        if let domain = config["Domainname"]?.string, !domain.isEmpty { sysctls["kernel.domainname"] = domain }
        for u in host["Ulimits"]?.array ?? [] {
            let name = u["Name"]?.string ?? ""
            let kind = "RLIMIT_" + name.uppercased()
            guard (try? LinuxRLimit.Kind(kind)) != nil else { throw APIError(400, "invalid ulimit type: \(name)") }
            func value(_ key: String) -> UInt64 { (u[key]?.int).map { $0 < 0 ? .max : UInt64($0) } ?? .max }
            let soft = value("Soft"), hard = value("Hard")
            guard soft <= hard else { throw APIError(400, "ulimit soft limit must be less than or equal to hard limit: \(soft) > \(hard)") }
            ulimits.append(Ulimit(kind: kind, soft: soft, hard: hard))
        }
        groups = host["GroupAdd"]?.strings ?? []
        let servers = host["Dns"]?.strings ?? [], search = host["DnsSearch"]?.strings ?? [], options = host["DnsOptions"]?.strings ?? []
        if !servers.isEmpty || !search.isEmpty || !options.isEmpty {
            for s in servers where IPv4.parse(s) == nil { throw APIError(400, "pratico: --dns \(s) is not an IPv4 address (pratico-net is IPv4 only)") }
            dns = Resolver(servers: servers, search: search, options: options)
        }
        for entry in host["ExtraHosts"]?.strings ?? [] {
            // `name:ip` (Docker) or `name=ip` (Docker 25+); names hold neither.
            guard let i = entry.firstIndex(where: { $0 == ":" || $0 == "=" }) else { throw APIError(400, "invalid IP address in add-host: \"\(entry)\"") }
            let name = String(entry[..<i]), address = String(entry[entry.index(after: i)...])
            guard !name.isEmpty, address == "host-gateway" || IPv4.parse(address) != nil else {
                throw APIError(400, "invalid IP address in add-host: \"\(address)\"")
            }
            extraHosts.append(HostEntry(name: name, address: address))
        }
        useInit = host["Init"]?.bool ?? false
    }

    private mutating func parseLifecycle(_ host: JSON, config: JSON) throws {
        if let s = config["StopSignal"]?.string, !s.isEmpty {
            guard Signals.number(s) != nil else { throw APIError(400, "invalid signal: \(s)") }
            stopSignal = s
        }
        if let t = config["StopTimeout"]?.int {
            guard t >= -1 else { throw APIError(400, "invalid stop timeout: \(t); -1 waits without limit") }
            stopTimeout = Int(t)
        }
        let policy = host["RestartPolicy"]
        let name = policy?["Name"]?.string ?? ""
        switch name {
        case "", "no": break
        case "always", "unless-stopped", "on-failure":
            if host["AutoRemove"]?.bool == true { throw APIError(400, "Conflicting options: --restart and --rm") }
            restart = RestartPolicy(name: name, maxRetries: Int(policy?["MaximumRetryCount"]?.int ?? 0))
            if name != "on-failure" && restart.maxRetries != 0 {
                throw APIError(400, "maximum retry count cannot be used with restart policy '\(name)'")
            }
        default:
            throw APIError(400, "invalid restart policy '\(name)'")
        }
        let log = host["LogConfig"]
        let driver = log?["Type"]?.string ?? ""
        guard ["", "json-file", "local"].contains(driver) else {
            throw APIError(400, "pratico: log driver \(driver) is not supported; logs stay in pratico's own store (json-file and local are accepted)")
        }
        var opts = (log?["Config"]?.object ?? [:]).compactMapValues(\.string)
        let size = try opts.removeValue(forKey: "max-size").map(Self.bytes)
        let files = try opts.removeValue(forKey: "max-file").map { s -> Int in
            guard let n = Int(s), n > 0 else { throw APIError(400, "invalid value for max-file: \(s)") }
            return n
        }
        if let bad = opts.keys.sorted().first { throw APIError(400, "pratico: log option \(bad) is not supported; only max-size and max-file are") }
        if let size { logBytes = max(Int(size) * (files ?? 1), 64 * 1024) }
    }

    /// Docker's sizes: `10m`, `1g`, `512k`, `100` (bytes); binary units.
    static func bytes(_ s: String) throws -> Int64 {
        let units: [Character: Int64] = ["b": 1, "k": 1 << 10, "m": 1 << 20, "g": 1 << 30, "t": 1 << 40]
        var t = s.lowercased()
        if t.hasSuffix("ib") { t.removeLast(2) } else if t.count > 1, t.hasSuffix("b"), units[t[t.index(t.endIndex, offsetBy: -2)]] != nil { t.removeLast() }
        let unit = t.last.flatMap { units[$0] }
        if unit != nil { t.removeLast() }
        guard let n = Double(t), n >= 0 else { throw APIError(400, "invalid size: '\(s)'") }
        return Int64(n * Double(unit ?? 1))
    }

    /// Options pratico does not apply, refused only when set: a value the Docker CLI
    /// sends by default (zero, empty, `private`) passes.
    private static func refuseUnsupported(host: JSON, config: JSON) throws {
        func set(_ v: JSON?) -> Bool {
            switch v {
            case nil, .null?: false
            case .bool(let b)?: b
            case .string(let s)?: !s.isEmpty
            case .array(let a)?: !a.isEmpty
            case .object(let o)?: !o.isEmpty
            default: (v?.int ?? 0) != 0 || (v?.double ?? 0) != 0
            }
        }
        let refused: [(key: String, flag: String, why: String)] = [
            ("Devices", "--device", "a VM has no host devices"),
            ("DeviceRequests", "--gpus", "a VM has no host devices"),
            ("DeviceCgroupRules", "--device-cgroup-rule", "a VM has no host devices"),
            ("BlkioWeight", "--blkio-weight", "the VM's disk is not a host device"),
            ("BlkioWeightDevice", "--blkio-weight-device", "the VM's disk is not a host device"),
            ("BlkioDeviceReadBps", "--device-read-bps", "the VM's disk is not a host device"),
            ("BlkioDeviceWriteBps", "--device-write-bps", "the VM's disk is not a host device"),
            ("BlkioDeviceReadIOps", "--device-read-iops", "the VM's disk is not a host device"),
            ("BlkioDeviceWriteIOps", "--device-write-iops", "the VM's disk is not a host device"),
            ("CpuRealtimePeriod", "--cpu-rt-period", "the guest kernel has no real-time group scheduling"),
            ("CpuRealtimeRuntime", "--cpu-rt-runtime", "the guest kernel has no real-time group scheduling"),
            ("CpuCount", "--cpu-count", "it is a Windows option"),
            ("CpuPercent", "--cpu-percent", "it is a Windows option"),
            ("IOMaximumIOps", "--io-maxiops", "it is a Windows option"),
            ("IOMaximumBandwidth", "--io-maxbandwidth", "it is a Windows option"),
            ("KernelMemory", "--kernel-memory", "cgroup v2 has no kernel memory limit"),
            ("KernelMemoryTCP", "--kernel-memory-tcp", "cgroup v2 has no kernel memory limit"),
            ("OomKillDisable", "--oom-kill-disable", "cgroup v2 cannot disable the OOM killer"),
            ("OomScoreAdj", "--oom-score-adj", "the guest agent cannot set it"),
            ("CgroupParent", "--cgroup-parent", "each container is its VM's only cgroup"),
            ("VolumesFrom", "--volumes-from", "name the volumes with -v instead"),
            ("StorageOpt", "--storage-opt", "the root filesystem is a disk image per container"),
            ("Cgroup", "--cgroup", "each container is its VM's only cgroup"),
        ]
        for r in refused where set(host[r.key]) {
            throw APIError(400, "pratico: \(r.flag) is not supported: \(r.why)")
        }
        if let s = host["MemorySwappiness"]?.int, s != -1 {
            throw APIError(400, "pratico: --memory-swappiness is not supported: cgroup v2 has no per-container swappiness")
        }
        let namespaces: [(key: String, flag: String, accepted: [String])] = [
            ("PidMode", "--pid", ["", "private"]),
            ("IpcMode", "--ipc", ["", "private", "shareable"]),
            ("UTSMode", "--uts", ["", "private"]),
            ("UsernsMode", "--userns", ["", "host"]),  // no remapping: Docker's `host`
            ("CgroupnsMode", "--cgroupns", ["", "private"]),
        ]
        for n in namespaces {
            let v = host[n.key]?.string ?? ""
            guard n.accepted.contains(v) else {
                throw APIError(400, "pratico: \(n.flag)=\(v) is not supported: each container is its own VM, with its own namespaces")
            }
        }
        for (port, list) in host["PortBindings"]?.object ?? [:] {
            for b in list.array ?? [] {
                let ip = b["HostIp"]?.string ?? ""
                guard ip.isEmpty || IPv4.parse(ip) != nil else {
                    throw APIError(400, "pratico: publishing \(port) on \(ip) is not supported: pratico-net is IPv4 only")
                }
            }
        }
        if let r = host["Runtime"]?.string, !["", "runc"].contains(r) { throw APIError(400, "pratico: --runtime \(r) is not supported") }
        if let i = host["Isolation"]?.string, !["", "default"].contains(i) { throw APIError(400, "pratico: --isolation \(i) is not supported") }
        if config["NetworkDisabled"]?.bool == true { throw APIError(400, "pratico: NetworkDisabled is not supported; use --network none") }
    }
}

/// Linux signal numbers (arm64, as the guest sees them), by name with or without `SIG`,
/// or as a number; `SIGRTMIN+n` too.
enum Signals {
    private static let table = [
        "HUP": 1, "INT": 2, "QUIT": 3, "ILL": 4, "TRAP": 5, "ABRT": 6, "IOT": 6, "BUS": 7, "FPE": 8, "KILL": 9,
        "USR1": 10, "SEGV": 11, "USR2": 12, "PIPE": 13, "ALRM": 14, "TERM": 15, "STKFLT": 16, "CHLD": 17, "CONT": 18,
        "STOP": 19, "TSTP": 20, "TTIN": 21, "TTOU": 22, "URG": 23, "XCPU": 24, "XFSZ": 25, "VTALRM": 26, "PROF": 27,
        "WINCH": 28, "IO": 29, "POLL": 29, "PWR": 30, "SYS": 31, "RTMIN": 34, "RTMAX": 64,
    ]

    static func number(_ name: String) -> Int? {
        if let n = Int(name) { return (1...64).contains(n) ? n : nil }
        var n = name.uppercased()
        if n.hasPrefix("SIG") { n.removeFirst(3) }
        if n.hasPrefix("RTMIN+"), let k = Int(n.dropFirst(6)), (0...30).contains(k) { return 34 + k }
        if n.hasPrefix("RTMAX-"), let k = Int(n.dropFirst(6)), (0...30).contains(k) { return 64 - k }
        return table[n]
    }
}
