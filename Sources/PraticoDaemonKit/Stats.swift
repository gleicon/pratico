import Foundation

/// `GET /containers/{id}/stats` from each shim's guest agent (SPEC FR-19).
///
/// A background sampler polls every `idleInterval` while containers run, back to back
/// while a client wants stats, and at once when a container starts. Paused containers are
/// skipped: a paused VM does not answer.
///
/// The agent reports cumulative CPU time; Docker clients compute CPU % from the delta
/// against `precpu_stats`. `system_cpu_usage` is synthesized as wall-clock time
/// times the container's CPUs, so 100% means one fully busy CPU, as in Docker.
final class StatsService: @unchecked Sendable {
    struct Sample {
        var time: Date
        var raw: JSON
    }

    let containers: ContainerService
    private let lock = NSLock()
    /// Latest and previous sample per Docker container ID.
    private var samples: [String: (now: Sample, pre: Sample?)] = [:]
    private var lastDemand = Date.distantPast
    private var generation = 0
    private let wakeup = DispatchSemaphore(value: 0)
    static let idleInterval: TimeInterval = 10
    static let demandWindow: TimeInterval = 60
    static let epoch = Date()

    init(containers: ContainerService) {
        self.containers = containers
        // `static let` is lazy: pin the epoch before any sample, or the first deltas
        // are negative (the Docker CLI then fails to decode them as unsigned).
        _ = Self.epoch
        Thread.detachNewThread { [self] in sampleLoop() }
    }

    /// Samples soon, e.g. after a container starts.
    func wake() { wakeup.signal() }

    private func sampleLoop() {
        while true {
            let targets = containers.all().filter { $0.state.running && !containers.isPaused($0.id) }
            if !targets.isEmpty { sample(targets, prune: true) }
            lock.lock()
            let busy = Date().timeIntervalSince(lastDemand) < Self.demandWindow
            lock.unlock()
            if !(busy && !targets.isEmpty) { _ = wakeup.wait(timeout: .now() + Self.idleInterval) }
        }
    }

    private func sample(_ targets: [ContainerRecord], prune: Bool) {
        let byApple = Dictionary(targets.map { ($0.appleId, $0.id) }, uniquingKeysWith: { a, _ in a })
        let fetched = fetch(targets)
        let now = Date()
        lock.lock()
        for raw in fetched {
            guard let apple = raw["id"]?.string, let id = byApple[apple] else { continue }
            // A per-record fetch time keeps CPU deltas right when samples interleave.
            let at = raw["fetchedAt"]?.double.map { Date(timeIntervalSince1970: $0) } ?? now
            if let last = samples[id]?.now, at <= last.time { continue }
            samples[id] = (Sample(time: at, raw: raw), samples[id]?.now)
        }
        if prune {
            let live = Set(targets.map(\.id))
            samples = samples.filter { live.contains($0.key) || containers.isPaused($0.key) }
        }
        generation += 1
        lock.unlock()
    }

    /// One record per container, `id` = its VM name, from the guest agent through each shim.
    private func fetch(_ targets: [ContainerRecord]) -> [JSON] {
        targets.compactMap { rec in
            guard let r = try? containers.embedded.shim.request(containers.shimFiles(rec.id), "GET", "/stats"),
                var o = JSON.parse(r.body)?.object
            else { return nil }
            o["id"] = .string(rec.appleId)
            o["fetchedAt"] = .double(Date().timeIntervalSince1970)
            return .object(o)
        }
    }

    private func current(_ id: String) -> (now: Sample, pre: Sample?, generation: Int)? {
        lock.lock()
        defer { lock.unlock() }
        // The idle sampler sleeps up to `idleInterval`; new demand starts it right away.
        if Date().timeIntervalSince(lastDemand) >= Self.demandWindow { wakeup.signal() }
        lastDemand = Date()
        // With one sample there is no delta yet: report 0% rather than lifetime usage.
        return samples[id].map { ($0.now, $0.pre ?? $0.now, generation) }
    }

    /// Waits (bounded) for a sample newer than `after`.
    private func next(_ id: String, after: Int, timeout: TimeInterval) -> (now: Sample, pre: Sample?, generation: Int)? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let c = current(id), c.generation > after { return c }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return current(id)
    }

    func stats(_ ref: String, stream: Bool, oneShot: Bool, conn: Connection) throws {
        let rec = try containers.resolve(ref)
        let cpus = Self.cpus(rec)
        guard rec.state.running else {
            conn.json(200, Self.encode(rec, cpus: cpus, now: nil, pre: nil))
            return
        }
        if containers.isPaused(rec.id) {
            let s = current(rec.id)?.now
            conn.json(200, Self.encode(rec, cpus: cpus, now: s, pre: s))
            return
        }
        var c = current(rec.id)
        if !stream || c == nil {
            // Agent stats take milliseconds: sample now rather than rely on the loop, twice,
            // so CPU has a fresh delta within the CLI's 2 s patience.
            sample([rec], prune: false)
            Thread.sleep(forTimeInterval: 0.5)
            sample([rec], prune: false)
            c = current(rec.id)
        }
        if c == nil {
            // Not sampled yet (just started): ask for one, within the client's patience.
            wake()
            c = next(rec.id, after: -1, timeout: 1.8)
        }
        if !stream {
            conn.json(200, Self.encode(rec, cpus: cpus, now: c?.now, pre: oneShot ? nil : c?.pre))
            return
        }
        conn.beginChunked()
        wake()
        var sent = -1
        while let r = try? containers.resolve(rec.id), r.state.running {
            guard let s = next(rec.id, after: sent, timeout: 5) else { continue }
            if s.generation == sent { continue }
            if !conn.chunk(Self.encode(rec, cpus: cpus, now: s.now, pre: s.pre).encoded() + Data("\n".utf8)) { return }
            sent = s.generation
        }
        conn.endChunked()
    }

    static func cpus(_ rec: ContainerRecord) -> Int64 {
        rec.hostConfig["NanoCpus"]?.int.flatMap { $0 > 0 ? max(($0 + 999_999_999) / 1_000_000_000, 1) : nil }
            ?? Int64(ProcessInfo.processInfo.activeProcessorCount)
    }

    static func encode(_ rec: ContainerRecord, cpus: Int64, now: Sample?, pre: Sample?) -> JSON {
        let epoch = Self.epoch
        func cpu(_ s: Sample?) -> JSON {
            guard let s else {
                return ["cpu_usage": ["total_usage": 0], "system_cpu_usage": 0, "online_cpus": .int(cpus)]
            }
            let usageNs = (s.raw["cpuUsageUsec"]?.int ?? 0) * 1000
            // Measured from daemon start: Unix-epoch nanoseconds times many CPUs overflows Int64.
            let systemNs = max(Int64(s.time.timeIntervalSince(epoch) * 1e9), 0) * cpus
            return [
                "cpu_usage": ["total_usage": .int(usageNs), "usage_in_kernelmode": 0, "usage_in_usermode": .int(usageNs)],
                "system_cpu_usage": .int(systemNs),
                "online_cpus": .int(cpus),
                "throttling_data": ["periods": 0, "throttled_periods": 0, "throttled_time": 0],
            ]
        }
        let raw = now?.raw ?? [:]
        let int: (String) -> JSON = { .int(raw[$0]?.int ?? 0) }
        return [
            "read": .string(Timestamp.format(now?.time)),
            "preread": .string(Timestamp.format(pre?.time)),
            "id": .string(rec.id),
            "name": .string("/\(rec.name)"),
            "pids_stats": ["current": int("numProcesses")],
            "num_procs": 0,
            "cpu_stats": cpu(now),
            "precpu_stats": cpu(pre),
            "memory_stats": now == nil ? [:] : ["usage": int("memoryUsageBytes"), "limit": int("memoryLimitBytes"), "stats": [:]],
            "networks": now == nil ? [:] : ["eth0": [
                "rx_bytes": int("networkRxBytes"), "tx_bytes": int("networkTxBytes"),
                "rx_packets": 0, "tx_packets": 0, "rx_errors": 0, "tx_errors": 0, "rx_dropped": 0, "tx_dropped": 0,
            ]],
            "blkio_stats": ["io_service_bytes_recursive": now == nil ? .null : [
                ["major": 0, "minor": 0, "op": "read", "value": int("blockReadBytes")],
                ["major": 0, "minor": 0, "op": "write", "value": int("blockWriteBytes")],
            ]],
            "storage_stats": [:],
        ]
    }
}
