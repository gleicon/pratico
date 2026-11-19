import Testing

@testable import PraticoDaemonKit

private func limits(_ host: JSON) throws -> [String: String] {
    try CgroupLimits(RunOptions.parse(host: host, config: [:], defaultCPUs: 4, defaultMemoryMiB: 1024)).files()
}

@Test func limitsHoldWhatLinuxContainerWritesAtCreate() throws {
    let bare = try limits([:])
    #expect(bare["cpu.max"] == "400000 100000" && bare["memory.max"] == "1073741824")
    #expect(bare["pids.max"] == "max" && bare["memory.low"] == "0" && bare["cpuset.cpus"] == "")
    // A fractional --cpus is RunOptions' cpu.max, which wins over the VM's size.
    #expect(try limits(["NanoCpus": 500_000_000])["cpu.max"] == "50000 100000")
}

@Test func everyCgroupFileRunOptionsSetsIsOneLimitsCanWrite() throws {
    let all = try limits([
        "NanoCpus": 1_500_000_000, "CpuShares": 512, "CpusetCpus": "0-1", "PidsLimit": 64,
        "Memory": 268_435_456, "MemorySwap": 536_870_912, "MemoryReservation": 134_217_728,
    ])
    #expect(all.count == CgroupLimits.kernelDefaults.count + 2)
    #expect(all.allSatisfy { $0.value != CgroupLimits.kernelDefaults[$0.key] })  // each one set
}

@Test func anUpdateCanLiftALimit() throws {
    #expect(try limits(["PidsLimit": 64])["pids.max"] == "64")
    #expect(try limits(["PidsLimit": -1])["pids.max"] == "max")
    #expect(try limits(["Memory": 268_435_456, "MemorySwap": -1])["memory.swap.max"] == "max")
}

@Test func limitsRefuseAFileTheyDoNotKnow() {
    let odd = CgroupLimits(cpus: 1, memoryMiB: 256, cgroup: ["memory.high": "1"])
    #expect(throws: APIError.self) { try odd.files() }
}
