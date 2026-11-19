import Containerization
import Foundation
import Synchronization

/// A container's cgroup limits: the body of the shim's `POST /limits` (`docker update` on
/// a running container). The VM keeps the vCPUs and memory it booted with; the limits
/// inside it change up to that.
struct CgroupLimits: Codable, Sendable, Equatable {
    var cpus: Int
    var memoryMiB: Int
    /// RunOptions' cgroup files (`cpu.max` for a fractional `--cpus`, `pids.max`, …).
    var cgroup: [String: String]

    init(cpus: Int, memoryMiB: Int, cgroup: [String: String]) {
        self.cpus = cpus
        self.memoryMiB = memoryMiB
        self.cgroup = cgroup
    }

    init(_ o: RunOptions) { self.init(cpus: o.cpus, memoryMiB: o.memoryMiB, cgroup: o.cgroup) }

    /// The files RunOptions may write, at cgroup v2's values for a new group: a limit left
    /// unset is written back to these, so an update can also lift one.
    static let kernelDefaults: [String: String] = [
        "cpu.weight": "100", "cpuset.cpus": "", "memory.low": "0", "memory.swap.max": "max", "pids.max": "max",
    ]

    /// Every file the guest holds for these limits, as LinuxContainer writes them at create:
    /// `cpu.max` and `memory.max` from the size, then the cgroup files, which win.
    func files() throws -> [String: String] {
        precondition(cpus >= 1 && memoryMiB >= 64, "limits below the VM minimum: \(cpus) vCPUs, \(memoryMiB) MiB")
        if let unknown = cgroup.keys.sorted().first(where: { Self.kernelDefaults[$0] == nil && $0 != "cpu.max" }) {
            throw APIError(400, "pratico: \(unknown) is not a cgroup file docker update sets")
        }
        var out = Self.kernelDefaults
        out["cpu.max"] = "\(cpus * 100_000) 100000"
        out["memory.max"] = "\(UInt64(memoryMiB).mib())"
        out.merge(cgroup) { _, set in set }
        assert(out.count == Self.kernelDefaults.count + 2, "a cgroup file outside the known set")
        return out
    }
}

/// The shim's view of its guest, under `ShimControl.guest`.
struct GuestState: Sendable {
    var limits: CgroupLimits
    var paused = false
}

extension ShimControl {
    /// The container's cgroup in the guest, where vminitd creates it (`/container/<id>`).
    var cgroupDirectory: String { "/sys/fs/cgroup/container/\(spec.id)" }

    /// Writes the files whose values differ from what the guest holds, in name order. A
    /// write the kernel refuses puts the ones before it back, so the container keeps one
    /// set of limits, the old or the new.
    func setLimits(_ new: CgroupLimits) throws {
        guard new.cpus <= spec.cpus, new.memoryMiB <= spec.memoryMiB else {
            throw APIError(409, "the VM booted with \(spec.cpus) vCPUs and \(spec.memoryMiB) MiB; its limits go up to that")
        }
        let target = try new.files()
        let dir = cgroupDirectory
        try guest.withLock { state in
            guard !state.paused else { throw APIError(409, "the container is paused; unpause it to change its limits") }
            let current = try state.limits.files()
            let changes = target.keys.sorted().compactMap { name -> Change? in
                guard let new = target[name], let old = current[name], new != old else { return nil }
                return Change(name: name, new: new, old: old)
            }
            guard !changes.isEmpty else { return }
            try blocking { [container] in
                try await container.withVirtualMachineInstance { vm in
                    let agent = try await vm.dialAgent()
                    defer { Task { try? await agent.close() } }
                    try await Self.write(changes, in: dir, agent)
                }
            }
            state.limits = new
        }
    }

    /// A cgroup file whose value changes, and the value to put back if a later one fails.
    struct Change: Sendable {
        var name: String
        var new: String
        var old: String
    }

    private static func write(_ changes: [Change], in dir: String, _ agent: any VirtualMachineAgent) async throws {
        func put(_ name: String, _ value: String) async throws {
            try await agent.writeFile(path: "\(dir)/\(name)", data: Data((value + "\n").utf8), flags: .init(), mode: 0)
        }
        for (i, change) in changes.enumerated() {
            do {
                try await put(change.name, change.new)
            } catch {
                for done in changes[..<i].reversed() { try? await put(done.name, done.old) }
                throw APIError(409, "the guest kernel refused \(change.name) = \(change.new): \(error)")
            }
        }
    }
}
