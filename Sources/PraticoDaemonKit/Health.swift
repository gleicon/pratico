import Foundation

/// Docker `Config.Healthcheck`, with Docker's defaults (SPEC FR-41).
struct HealthConfig: Equatable {
    var command: [String]
    var interval: TimeInterval
    var timeout: TimeInterval
    var retries: Int
    var startPeriod: TimeInterval

    /// nil when there is no check, or it is `NONE`.
    init?(_ json: JSON?) {
        guard let test = json?["Test"]?.strings, let kind = test.first else { return nil }
        switch kind {
        case "CMD-SHELL" where test.count == 2: command = ["/bin/sh", "-c", test[1]]
        case "CMD" where test.count > 1: command = Array(test.dropFirst())
        default: return nil  // NONE, or malformed
        }
        func seconds(_ key: String, _ fallback: TimeInterval) -> TimeInterval {
            guard let ns = json?[key]?.int, ns > 0 else { return fallback }
            return TimeInterval(ns) / 1e9
        }
        interval = seconds("Interval", 30)
        timeout = seconds("Timeout", 30)
        startPeriod = seconds("StartPeriod", 0)
        retries = json?["Retries"]?.int.flatMap { $0 > 0 ? Int($0) : nil } ?? 3
    }
}

struct HealthState {
    struct Probe {
        var start: Date
        var end: Date
        var exitCode: Int
        var output: String
    }

    var status = "starting"  // starting | healthy | unhealthy
    var failingStreak = 0
    var log: [Probe] = []

    /// Applies one probe result by Docker's rules; returns the new status if it changed.
    mutating func record(_ p: Probe, retries: Int, inStartPeriod: Bool) -> String? {
        let before = status
        log.append(p)
        if log.count > 5 { log.removeFirst(log.count - 5) }
        if p.exitCode == 0 {
            failingStreak = 0
            status = "healthy"
        } else if !inStartPeriod || status == "healthy" {
            failingStreak += 1
            if failingStreak >= retries { status = "unhealthy" }
        }
        return status == before ? nil : status
    }

    var json: JSON {
        [
            "Status": .string(status),
            "FailingStreak": .int(Int64(failingStreak)),
            "Log": .array(log.map {
                ["Start": .string(Timestamp.format($0.start)), "End": .string(Timestamp.format($0.end)),
                 "ExitCode": .int(Int64($0.exitCode)), "Output": .string($0.output)]
            }),
        ]
    }
}

/// Runs each running container's healthcheck through `container exec`.
final class HealthMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private var states: [String: HealthState] = [:]
    private var runs: [String: Int] = [:]  // bumped per start, so stale loops stop
    weak var service: ContainerService?

    func state(_ id: String) -> HealthState? {
        lock.lock()
        defer { lock.unlock() }
        return states[id]
    }

    /// Starts (or restarts) monitoring after the container starts.
    func started(_ rec: ContainerRecord) {
        guard let check = HealthConfig(rec.config["Healthcheck"]) else { return }
        lock.lock()
        states[rec.id] = HealthState()
        let run = (runs[rec.id] ?? 0) + 1
        runs[rec.id] = run
        lock.unlock()
        let began = Date()
        Thread.detachNewThread { [self] in
            while true {
                Thread.sleep(forTimeInterval: check.interval)
                guard let service, let current = try? service.resolve(rec.id), current.state.running,
                    isCurrent(rec.id, run)
                else { return }
                if service.isPaused(rec.id) { continue }
                let probe = service.healthProbe(rec, check)
                lock.lock()
                guard runs[rec.id] == run else { lock.unlock(); return }
                let changed = states[rec.id]?.record(probe, retries: check.retries,
                                                     inStartPeriod: Date().timeIntervalSince(began) < check.startPeriod)
                lock.unlock()
                if let changed { service.emit(current, "health_status: \(changed)") }
            }
        }
    }

    /// Container stopped: health is reported only while running, as in Docker's ps.
    func stopped(_ id: String) {
        lock.lock()
        runs[id] = (runs[id] ?? 0) + 1
        lock.unlock()
    }

    func removed(_ id: String) {
        lock.lock()
        states[id] = nil
        runs[id] = nil
        lock.unlock()
    }

    private func isCurrent(_ id: String, _ run: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return runs[id] == run
    }
}
