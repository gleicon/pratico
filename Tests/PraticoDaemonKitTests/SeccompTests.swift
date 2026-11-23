import ContainerizationOCI
import Foundation
import Testing

/// Runs a classic BPF seccomp filter as the kernel would, on one call.
private func run(_ program: [SeccompInstruction], nr: UInt32, arch: UInt32 = LinuxSeccomp.auditArchAARCH64, args: [UInt64] = []) -> UInt32 {
    var data = [UInt32](repeating: 0, count: 16)
    data[0] = nr
    data[1] = arch
    for (i, v) in args.prefix(6).enumerated() {
        data[4 + 2 * i] = UInt32(truncatingIfNeeded: v)
        data[5 + 2 * i] = UInt32(truncatingIfNeeded: v >> 32)
    }
    var a: UInt32 = 0, pc = 0
    for _ in 0..<program.count {  // forward jumps only: at most one pass
        let i = program[pc]
        switch i.code {
        case 0x20: a = data[Int(i.k / 4)]; pc += 1
        case 0x54: a &= i.k; pc += 1
        case 0x05: pc += 1 + Int(i.k)
        case 0x15: pc += 1 + Int(a == i.k ? i.jt : i.jf)
        case 0x25: pc += 1 + Int(a > i.k ? i.jt : i.jf)
        case 0x35: pc += 1 + Int(a >= i.k ? i.jt : i.jf)
        case 0x06: return i.k
        default: Issue.record("unknown instruction \(i.code)"); return 0
        }
    }
    Issue.record("filter ran off its end")
    return 0
}

/// The profile read directly, independently of the compiler: first rule naming the call
/// whose arguments all hold decides, else the default.
private func expected(_ p: LinuxSeccomp, nr: UInt32, args: [UInt64], table: [String: UInt32] = LinuxSeccomp.syscallsARM64) -> UInt32 {
    func value(_ action: LinuxSeccompAction, _ errno: UInt?) -> UInt32 {
        switch action {
        case .actAllow: return 0x7FFF_0000
        case .actErrno: return 0x0005_0000 | UInt32(errno ?? 1)
        case .actKill, .actKillThread: return 0
        case .actKillProcess: return 0x8000_0000
        case .actTrap: return 0x0003_0000
        case .actLog: return 0x7FFC_0000
        case .actTrace: return 0x7FF0_0000 | UInt32(errno ?? 0)
        case .actNotify: return 0x7FC0_0000
        }
    }
    let names = table.filter { $0.value == nr }.map(\.key)
    for rule in p.syscalls where rule.names.contains(where: names.contains) {
        let holds = rule.args.allSatisfy { arg in
            let v = args.count > Int(arg.index) ? args[Int(arg.index)] : 0
            switch arg.op {
            case .opEqualTo: return v == arg.value
            case .opNotEqual: return v != arg.value
            case .opLessThan: return v < arg.value
            case .opLessEqual: return v <= arg.value
            case .opGreaterThan: return v > arg.value
            case .opGreaterEqual: return v >= arg.value
            case .opMaskedEqual: return v & arg.value == arg.valueTwo
            }
        }
        if holds { return value(rule.action, rule.errnoRet) }
    }
    return value(p.defaultAction, p.defaultErrnoRet)
}

private let samples: [[UInt64]] = [[], [0x7E02_0000], [0x1_0000_0000], [8], [0x0002_0000], [0xFFFF_FFFF], [0x20008], [UInt64.max]]

@Test func seccompDefaultProfileMatchesItsRules() throws {
    for caps in [["CAP_CHOWN", "CAP_NET_BIND_SERVICE"], ["CAP_SYS_ADMIN", "CAP_SYS_PTRACE", "CAP_BPF"]] {
        let set = LinuxCapabilities(bounding: caps, effective: caps, inheritable: [], permitted: caps, ambient: [])
        let profile = LinuxSeccomp.defaultProfile(capabilities: set, arch: .archAARCH64)
        let program = try profile.compileARM64()
        #expect(program.instructions.count < LinuxSeccomp.maxInstructions)
        for nr in Set(LinuxSeccomp.syscallsARM64.values).union([999, 0xFFFF_FFFF]) {
            for args in samples {
                #expect(run(program.instructions, nr: nr, args: args) == expected(profile, nr: nr, args: args), "call \(nr) args \(args)")
            }
        }
    }
}

@Test func seccompEveryOperatorAcrossWordBoundaries() throws {
    let edges: [UInt64] = [0, 1, 0xFFFF_FFFF, 0x1_0000_0000, 0x1_0000_0001, 0xFFFF_FFFF_0000_0000, UInt64.max]
    let ops: [LinuxSeccompOperator] = [.opEqualTo, .opNotEqual, .opLessThan, .opLessEqual, .opGreaterThan, .opGreaterEqual, .opMaskedEqual]
    for op in ops {
        for value in edges {
            let arg = LinuxSeccompArg(index: 2, value: value, valueTwo: value & 0xFFFF_0000_FFFF, op: op)
            let profile = LinuxSeccomp(defaultAction: .actAllow, defaultErrnoRet: nil, architectures: [.archAARCH64], flags: [], listenerPath: "", listenerMetadata: "",
                                       syscalls: [LinuxSyscall(names: ["openat"], action: .actErrno, errnoRet: 13, args: [arg])])
            let program = try profile.compileARM64()
            for v in edges {
                let args: [UInt64] = [0, 0, v]
                #expect(run(program.instructions, nr: 56, args: args) == expected(profile, nr: 56, args: args), "\(op) \(value) against \(v)")
            }
        }
    }
}

@Test func seccompOtherArchitecturesAreKilled() throws {
    let profile = LinuxSeccomp(defaultAction: .actAllow, defaultErrnoRet: nil, architectures: [], flags: [], listenerPath: "", listenerMetadata: "", syscalls: [])
    let program = try profile.compileARM64()
    #expect(run(program.instructions, nr: 56, arch: 0xC000_003E) == 0x8000_0000)  // x86_64
    #expect(run(program.instructions, nr: 56) == 0x7FFF_0000)
}

@Test func seccompRefusesWhatItCannotApply() {
    let notify = LinuxSeccomp(defaultAction: .actAllow, defaultErrnoRet: nil, architectures: [], flags: [], listenerPath: "", listenerMetadata: "",
                              syscalls: [LinuxSyscall(names: ["mkdirat"], action: .actNotify, errnoRet: nil, args: [])])
    #expect(throws: (any Error).self) { try notify.compileARM64() }
    let listener = LinuxSeccomp(defaultAction: .actAllow, defaultErrnoRet: nil, architectures: [], flags: [], listenerPath: "/run/x.sock", listenerMetadata: "", syscalls: [])
    #expect(throws: (any Error).self) { try listener.compileARM64() }
    let errno = LinuxSeccomp(defaultAction: .actErrno, defaultErrnoRet: 5000, architectures: [], flags: [], listenerPath: "", listenerMetadata: "", syscalls: [])
    #expect(throws: (any Error).self) { try errno.compileARM64() }
}

@Test func seccompDockerConditionsFollowTheContainer() throws {
    let json = """
        {"defaultAction":"SCMP_ACT_ERRNO","defaultErrnoRet":1,
         "archMap":[{"architecture":"SCMP_ARCH_AARCH64","subArchitectures":["SCMP_ARCH_ARM"]}],
         "syscalls":[
          {"names":["read","write"],"action":"SCMP_ACT_ALLOW"},
          {"names":["mount"],"action":"SCMP_ACT_ALLOW","includes":{"caps":["CAP_SYS_ADMIN"]}},
          {"names":["ptrace"],"action":"SCMP_ACT_ALLOW","excludes":{"caps":["CAP_SYS_PTRACE"]}},
          {"names":["clone3"],"action":"SCMP_ACT_ERRNO","errnoRet":38,"includes":{"arches":["amd64"]}},
          {"names":["landlock_create_ruleset"],"action":"SCMP_ACT_ALLOW","includes":{"minKernel":"5.13"}},
          {"names":["futex_waitv"],"action":"SCMP_ACT_ALLOW","includes":{"minKernel":"9.0"}}
         ]}
        """
    let plain = try LinuxSeccomp.decodeAnyFormat(from: Data(json.utf8), for: .init(capabilities: ["CAP_CHOWN"], kernel: (6, 18)))
    let names = Set(plain.syscalls.flatMap(\.names))
    #expect(names == ["read", "write", "ptrace", "landlock_create_ruleset"])
    #expect(plain.architectures.map(\.rawValue) == ["SCMP_ARCH_AARCH64", "SCMP_ARCH_ARM"])
    let admin = try LinuxSeccomp.decodeAnyFormat(from: Data(json.utf8), for: .init(capabilities: ["CAP_SYS_ADMIN", "CAP_SYS_PTRACE"], kernel: (6, 18)))
    #expect(Set(admin.syscalls.flatMap(\.names)) == ["read", "write", "mount", "landlock_create_ruleset"])
    // The OCI format still decodes as itself.
    let oci = try LinuxSeccomp.decodeAnyFormat(from: Data(#"{"defaultAction":"SCMP_ACT_ALLOW"}"#.utf8), for: .init(capabilities: [], kernel: (6, 18)))
    #expect(oci.defaultAction == .actAllow)
}

@Test func seccompDefaultProfileMatchesItsRulesOnX86_64() throws {
    for caps in [["CAP_CHOWN", "CAP_NET_BIND_SERVICE"], ["CAP_SYS_ADMIN", "CAP_SYS_PTRACE", "CAP_BPF"]] {
        let set = LinuxCapabilities(bounding: caps, effective: caps, inheritable: [], permitted: caps, ambient: [])
        let profile = LinuxSeccomp.defaultProfile(capabilities: set, arch: .archX86_64)
        let program = try profile.compile(for: .x86_64)
        #expect(program.instructions.count < LinuxSeccomp.maxInstructions)
        for nr in Set(LinuxSeccomp.syscallsX86_64.values).union([999, 0x3FFF_FFFF]) {
            for args in samples {
                #expect(run(program.instructions, nr: nr, arch: LinuxSeccomp.auditArchX86_64, args: args)
                        == expected(profile, nr: nr, args: args, table: LinuxSeccomp.syscallsX86_64), "call \(nr) args \(args)")
            }
        }
    }
}

/// x32 calls are x86_64's with __X32_SYSCALL_BIT set: they pass the arch check, so the
/// filter refuses them by number, whatever the profile allows.
@Test func seccompX32AndOtherArchitecturesAreKilledOnX86_64() throws {
    let all = LinuxSeccomp(defaultAction: .actAllow, defaultErrnoRet: nil, architectures: [], flags: [], listenerPath: "", listenerMetadata: "", syscalls: [])
    let program = try all.compile(for: .x86_64)
    let x86 = LinuxSeccomp.auditArchX86_64
    #expect(run(program.instructions, nr: 0, arch: x86) == 0x7FFF_0000)
    #expect(run(program.instructions, nr: 0x4000_0000, arch: x86) == 0x8000_0000)  // x32 read
    #expect(run(program.instructions, nr: 0x4000_0000 | 59, arch: x86) == 0x8000_0000)  // x32 execve
    #expect(run(program.instructions, nr: 56, arch: LinuxSeccomp.auditArchAARCH64) == 0x8000_0000)
    #expect(try all.compile(for: .arm64).instructions.count < program.instructions.count)  // arm64 has no x32 check
}

@Test func seccompDockerConditionsFollowTheArchitecture() throws {
    let json = """
        {"defaultAction":"SCMP_ACT_ERRNO","defaultErrnoRet":1,
         "archMap":[{"architecture":"SCMP_ARCH_X86_64","subArchitectures":["SCMP_ARCH_X86","SCMP_ARCH_X32"]},
                    {"architecture":"SCMP_ARCH_AARCH64","subArchitectures":["SCMP_ARCH_ARM"]}],
         "syscalls":[{"names":["clone3"],"action":"SCMP_ACT_ERRNO","errnoRet":38,"includes":{"arches":["amd64"]}},
                     {"names":["arch_prctl"],"action":"SCMP_ACT_ALLOW","excludes":{"arches":["arm64"]}}]}
        """
    let x86 = try LinuxSeccomp.decodeAnyFormat(from: Data(json.utf8), for: .init(capabilities: [], kernel: (6, 18), arch: .x86_64))
    let arm = try LinuxSeccomp.decodeAnyFormat(from: Data(json.utf8), for: .init(capabilities: [], kernel: (6, 18), arch: .arm64))
    #expect(Set(x86.syscalls.flatMap(\.names)) == ["clone3", "arch_prctl"])
    #expect(arm.syscalls.isEmpty)
    #expect(x86.architectures.map(\.rawValue) == ["SCMP_ARCH_X86_64", "SCMP_ARCH_X86", "SCMP_ARCH_X32"])
}
