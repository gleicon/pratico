import Foundation
import PraticoCore

/// Docker's restart policies (`--restart`, D-45). A container that exits is started again
/// when its policy says so, after a delay that doubles from 100 ms to a minute and resets
/// once a run lasts 10 s. `docker stop` and `docker kill` mark it stopped by hand: `always`
/// then waits for the daemon's next start, `unless-stopped` stays down. When the daemon
/// starts (at login, after the Mac restarts), `always` and `unless-stopped` containers that
/// are not running come back.
final class RestartSupervisor: @unchecked Sendable {
    weak var containers: ContainerService?
    private let lock = NSLock()
    /// Delay exponent per container; in memory only, as Docker's.
    private var backoff: [String: Int] = [:]
    /// Restarts scheduled and not yet started.
    private var pending: Set<String> = []

    static func shouldRestart(_ policy: RunOptions.RestartPolicy, code: Int, restarts: Int, byHand: Bool) -> Bool {
        guard !byHand else { return false }
        switch policy.name {
        case "always", "unless-stopped": return true
        case "on-failure": return code != 0 && (policy.maxRetries == 0 || restarts < policy.maxRetries)
        default: return false
        }
    }

    static func atDaemonStart(_ policy: RunOptions.RestartPolicy, byHand: Bool) -> Bool {
        policy.name == "always" || (policy.name == "unless-stopped" && !byHand)
    }

    static func delay(_ exponent: Int) -> Double { min(0.1 * pow(2, Double(min(exponent, 10))), 60) }

    func isPending(_ id: String) -> Bool { lock.withLock { pending.contains(id) } }

    /// The container exited; schedules its restart if the policy says so.
    func exited(_ rec: ContainerRecord, code: Int) {
        guard let containers, let options = try? containers.runOptions(rec),
            Self.shouldRestart(options.restart, code: code, restarts: rec.state.restartCount ?? 0, byHand: rec.state.stoppedByHand ?? false)
        else { return }
        let ranLong = rec.state.startedAt.map { Date().timeIntervalSince($0) >= 10 } ?? false
        let wait: Double = lock.withLock {
            let e = ranLong ? 0 : (backoff[rec.id] ?? -1) + 1
            backoff[rec.id] = e
            pending.insert(rec.id)
            return Self.delay(e)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + wait) { [weak self] in self?.fire(rec.id) }
    }

    /// A start, a stop, or a removal by hand supersedes a scheduled restart.
    func cancel(_ id: String) {
        lock.withLock { _ = pending.remove(id) }
    }

    func forget(_ id: String) {
        lock.withLock {
            pending.remove(id)
            backoff[id] = nil
        }
    }

    /// Attempts at a restart that a change holding the container (`docker cp`, `docker
    /// update`) put off, a second apart.
    static let busyRetries = 60

    private func fire(_ id: String, attempt: Int = 0) {
        precondition(attempt <= Self.busyRetries, "restart retried past its bound")
        guard lock.withLock({ pending.remove(id) != nil }), let containers else { return }
        do { try containers.restartByPolicy(id) } catch let e as APIError where e.busy && attempt < Self.busyRetries {
            lock.withLock { _ = pending.insert(id) }
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) { [weak self] in self?.fire(id, attempt: attempt + 1) }
        } catch {
            Pratico.log("pratico-daemon: restart policy could not start \(id.prefix(12)): \(error)")
        }
    }

    /// The daemon just started: brings back what `always` and `unless-stopped` keep up.
    func daemonStarted() {
        guard let containers else { return }
        for rec in containers.all() where !rec.state.running {
            guard let options = try? containers.runOptions(rec),
                Self.atDaemonStart(options.restart, byHand: rec.state.stoppedByHand ?? false)
            else { continue }
            do { try containers.restartByPolicy(rec.id, atDaemonStart: true) } catch {
                Pratico.log("pratico-daemon: restart policy could not start \(rec.name): \(error)")
            }
        }
    }
}
