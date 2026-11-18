//===----------------------------------------------------------------------===//
// Copyright © 2026 the Pratico project authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//   https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
// Added by the Pratico project (Vendor/README.md).
//===----------------------------------------------------------------------===//

import ContainerizationError

/// One classic BPF instruction, laid out as the kernel's `struct sock_filter`.
public struct SeccompInstruction: Equatable, Sendable {
    public var code: UInt16
    public var jt: UInt8
    public var jf: UInt8
    public var k: UInt32

    public init(code: UInt16, jt: UInt8 = 0, jf: UInt8 = 0, k: UInt32) {
        self.code = code
        self.jt = jt
        self.jf = jf
        self.k = k
    }
}

/// A compiled filter: what `seccomp(SECCOMP_SET_MODE_FILTER, flags, &prog)` takes.
public struct SeccompProgram: Sendable {
    public var instructions: [SeccompInstruction]
    public var flags: UInt32
}

extension LinuxSeccomp {
    /// The kernel's limit on a filter's length (`BPF_MAXINSNS`).
    public static let maxInstructions = 4096
    /// `AUDIT_ARCH_AARCH64`: EM_AARCH64 (183), 64-bit, little-endian.
    public static let auditArchAARCH64: UInt32 = 0xC000_00B7

    enum Ret {
        static let killProcess: UInt32 = 0x8000_0000
        static let killThread: UInt32 = 0x0000_0000
        static let trap: UInt32 = 0x0003_0000
        static let errno: UInt32 = 0x0005_0000
        static let trace: UInt32 = 0x7FF0_0000
        static let log: UInt32 = 0x7FFC_0000
        static let allow: UInt32 = 0x7FFF_0000
    }

    enum Op {
        static let ldAbs: UInt16 = 0x20  // BPF_LD | BPF_W | BPF_ABS
        static let andK: UInt16 = 0x54  // BPF_ALU | BPF_AND | BPF_K
        static let ja: UInt16 = 0x05  // BPF_JMP | BPF_JA
        static let jeq: UInt16 = 0x15  // BPF_JMP | BPF_JEQ | BPF_K
        static let jgt: UInt16 = 0x25
        static let jge: UInt16 = 0x35
        static let ret: UInt16 = 0x06  // BPF_RET | BPF_K
    }

    /// Compiles the profile for arm64 into a filter. Calls are found by number through a
    /// balanced tree (about 30 instructions per call for Docker's default profile, not a
    /// scan of every rule); a call's rules are tried in profile order and the first that
    /// matches decides; a call no rule names gets `defaultAction`. Names arm64 does not
    /// have are skipped, as libseccomp does. Calls from any other architecture kill the
    /// process (the kernel runs no 32-bit code). Refused: notification (no listener),
    /// errno values outside 0...4095.
    public func compileARM64() throws -> SeccompProgram {
        guard listenerPath.isEmpty else { throw Self.refused("a seccomp notification listener (listenerPath)") }
        let flags = try Self.filterFlags(self.flags)
        let fallback = try Self.retValue(defaultAction, errno: defaultErrnoRet)
        var rules: [UInt32: [(action: UInt32, args: [LinuxSeccompArg])]] = [:]
        for syscall in syscalls {
            let action = try Self.retValue(syscall.action, errno: syscall.errnoRet)
            for arg in syscall.args where arg.index > 5 {
                throw ContainerizationError(.invalidArgument, message: "seccomp: argument index \(arg.index) does not exist (system calls have 6)")
            }
            for name in syscall.names {
                guard let nr = Self.syscallsARM64[name] else { continue }
                rules[nr, default: []].append((action, syscall.args))
            }
        }

        var asm = Assembler()
        let killArch = asm.label()
        asm.load(offset: 4)  // seccomp_data.arch
        asm.jumpUnless(Op.jeq, Self.auditArchAARCH64, to: killArch)
        asm.load(offset: 0)  // seccomp_data.nr
        let numbers = rules.keys.sorted()
        var bodies: [UInt32: Assembler.Label] = [:]
        for nr in numbers { bodies[nr] = asm.label() }
        asm.tree(numbers, bodies: bodies, fallback: fallback, depth: 0)
        for nr in numbers {
            asm.place(bodies[nr]!)
            for rule in rules[nr]! {
                let next = asm.label()
                for arg in rule.args { asm.compare(arg, failTo: next) }
                asm.ret(rule.action)
                asm.place(next)
            }
            asm.ret(fallback)
        }
        asm.place(killArch)
        asm.ret(Ret.killProcess)

        let program = try asm.assemble()
        guard program.count <= Self.maxInstructions else {
            throw ContainerizationError(.invalidArgument, message: "seccomp: the profile compiles to \(program.count) instructions, over the kernel's \(Self.maxInstructions)")
        }
        return SeccompProgram(instructions: program, flags: flags)
    }

    static func refused(_ what: String) -> ContainerizationError {
        ContainerizationError(.unsupported, message: "seccomp: \(what) is not supported")
    }

    static func retValue(_ action: LinuxSeccompAction, errno: UInt?) throws -> UInt32 {
        let data = errno ?? 1  // EPERM, as runc
        guard data <= 4095 else { throw ContainerizationError(.invalidArgument, message: "seccomp: errno \(data) is out of range (0...4095)") }
        switch action {
        case .actKill, .actKillThread: return Ret.killThread
        case .actKillProcess: return Ret.killProcess
        case .actTrap: return Ret.trap
        case .actErrno: return Ret.errno | UInt32(data)
        case .actTrace: return Ret.trace | UInt32(errno ?? 0)
        case .actAllow: return Ret.allow
        case .actLog: return Ret.log
        case .actNotify: throw refused("SCMP_ACT_NOTIFY (it needs a notification listener)")
        }
    }

    static func filterFlags(_ flags: [LinuxSeccompFlag]) throws -> UInt32 {
        var bits: UInt32 = 0
        for flag in flags {
            switch flag {
            case .flagLog: bits |= 2  // SECCOMP_FILTER_FLAG_LOG
            case .flagSpecAllow: bits |= 4  // SECCOMP_FILTER_FLAG_SPEC_ALLOW
            case .flagWaitKillableRecv: throw refused("SECCOMP_FILTER_FLAG_WAIT_KILLABLE_RECV (it needs a notification listener)")
            }
        }
        return bits
    }
}

/// Builds a filter from fixed-size pieces: every jump that may go far is a conditional
/// jump to the next instruction or the one after, plus `ja` (32-bit offset), so the
/// 8-bit `jt`/`jf` offsets never overflow and the layout is known before it is resolved.
struct Assembler {
    struct Label: Hashable { let id: Int }
    private enum Piece {
        case insn(SeccompInstruction)
        case ja(Label)
        case place(Label)
    }
    private var pieces: [Piece] = []
    private var labels = 0

    mutating func label() -> Label {
        labels += 1
        return Label(id: labels)
    }

    mutating func place(_ l: Label) { pieces.append(.place(l)) }
    mutating func load(offset: UInt32) { pieces.append(.insn(.init(code: LinuxSeccomp.Op.ldAbs, k: offset))) }
    mutating func ret(_ value: UInt32) { pieces.append(.insn(.init(code: LinuxSeccomp.Op.ret, k: value))) }

    /// Jumps to `target` when `A op k` holds; falls through otherwise.
    mutating func jumpIf(_ op: UInt16, _ k: UInt32, to target: Label) {
        pieces.append(.insn(.init(code: op, jt: 0, jf: 1, k: k)))
        pieces.append(.ja(target))
    }

    /// Jumps to `target` when `A op k` does not hold; falls through otherwise.
    mutating func jumpUnless(_ op: UInt16, _ k: UInt32, to target: Label) {
        pieces.append(.insn(.init(code: op, jt: 1, jf: 0, k: k)))
        pieces.append(.ja(target))
    }

    /// Balanced search over sorted call numbers; A holds the number. Depth is bounded
    /// by log2 of the count (at most 9 for arm64's 325 calls).
    mutating func tree(_ numbers: [UInt32], bodies: [UInt32: Label], fallback: UInt32, depth: Int) {
        precondition(depth <= 16, "seccomp tree deeper than its input allows")
        guard numbers.count > 4 else {
            for nr in numbers { jumpIf(LinuxSeccomp.Op.jeq, nr, to: bodies[nr]!) }
            ret(fallback)
            return
        }
        let mid = numbers.count / 2
        let right = label()
        jumpIf(LinuxSeccomp.Op.jge, numbers[mid], to: right)
        tree(Array(numbers[..<mid]), bodies: bodies, fallback: fallback, depth: depth + 1)
        place(right)
        tree(Array(numbers[mid...]), bodies: bodies, fallback: fallback, depth: depth + 1)
    }

    /// Falls through when the call's argument satisfies `arg`, else jumps to `fail`.
    /// Arguments are 64-bit; seccomp_data stores them little-endian, so the low word is
    /// at 16 + 8·index and the high word 4 bytes on. Comparisons are unsigned.
    mutating func compare(_ arg: LinuxSeccompArg, failTo fail: Label) {
        let lo = UInt32(16 + 8 * arg.index), hi = lo + 4
        let (vh, vl) = (UInt32(truncatingIfNeeded: arg.value >> 32), UInt32(truncatingIfNeeded: arg.value))
        let ok = label()
        let O = LinuxSeccomp.Op.self
        switch arg.op {
        case .opEqualTo:
            load(offset: hi); jumpUnless(O.jeq, vh, to: fail)
            load(offset: lo); jumpUnless(O.jeq, vl, to: fail)
        case .opNotEqual:
            load(offset: hi); jumpUnless(O.jeq, vh, to: ok)
            load(offset: lo); jumpIf(O.jeq, vl, to: fail)
        case .opGreaterThan, .opGreaterEqual:
            load(offset: hi); jumpIf(O.jgt, vh, to: ok); jumpUnless(O.jeq, vh, to: fail)
            load(offset: lo); jumpUnless(arg.op == .opGreaterThan ? O.jgt : O.jge, vl, to: fail)
        case .opLessThan, .opLessEqual:
            load(offset: hi); jumpIf(O.jgt, vh, to: fail); jumpUnless(O.jeq, vh, to: ok)
            load(offset: lo); jumpIf(arg.op == .opLessThan ? O.jge : O.jgt, vl, to: fail)
        case .opMaskedEqual:
            // OCI's `value` is the mask and `valueTwo` the result: (arg & value) == valueTwo.
            let (rh, rl) = (UInt32(truncatingIfNeeded: arg.valueTwo >> 32), UInt32(truncatingIfNeeded: arg.valueTwo))
            load(offset: hi); pieces.append(.insn(.init(code: O.andK, k: vh))); jumpUnless(O.jeq, rh, to: fail)
            load(offset: lo); pieces.append(.insn(.init(code: O.andK, k: vl))); jumpUnless(O.jeq, rl, to: fail)
        }
        place(ok)
    }

    /// Lays the pieces out and resolves every `ja` to its label.
    func assemble() throws -> [SeccompInstruction] {
        var at: [Label: Int] = [:]
        var pc = 0
        for piece in pieces {
            if case .place(let l) = piece { at[l] = pc } else { pc += 1 }
        }
        var out: [SeccompInstruction] = []
        out.reserveCapacity(pc)
        for piece in pieces {
            switch piece {
            case .insn(let i): out.append(i)
            case .ja(let l):
                guard let target = at[l], target > out.count else {
                    throw ContainerizationError(.internalError, message: "seccomp: a jump goes backwards or nowhere")
                }
                out.append(.init(code: LinuxSeccomp.Op.ja, k: UInt32(target - out.count - 1)))
            case .place: break
            }
        }
        precondition(out.count == pc, "seccomp: assembled length differs from the layout")
        return out
    }
}
