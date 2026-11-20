import Foundation

/// Ask mode (D-62): a container with `dev.pratico.egress.ask=true` reaches a destination
/// only once someone allows it. A connection to one not yet decided is held at the switch
/// while the menubar asks; `allow` lets it, and that destination, through until the
/// container stops, `always` adds it to the container's allowlist for good, `deny` refuses
/// it until the container stops. A question nobody answers within `timeout` is refused,
/// and asked again by the next connection.
final class EgressQuestions: @unchecked Sendable {
    enum Answer: String, Sendable { case allow, always, deny }
    /// What a held packet is told: go, or be refused and why.
    enum Outcome: Sendable, Equatable {
        case allowed
        case refused(String)
    }

    struct Question: Sendable {
        var id: String
        var container: String
        var destination: String
        var port: UInt16
        var asked: Date
    }

    static let timeout: TimeInterval = 30
    /// How long this registry waits: `timeout`, or `PRATICO_EGRESS_ASK_SECONDS` (tests).
    let wait: TimeInterval

    init(wait: TimeInterval = ProcessInfo.processInfo.environment["PRATICO_EGRESS_ASK_SECONDS"].flatMap(TimeInterval.init) ?? EgressQuestions.timeout) {
        self.wait = min(max(wait, 0.1), Self.timeout)  // an environment value: clamped, never trusted
    }
    /// Questions open at once, all containers, and per container: past either, a new one
    /// is refused at once, so one container cannot crowd out another's.
    static let maxPending = 64
    static let maxPendingPerContainer = 8
    /// Waiters on one question: connections to the same destination share it.
    static let maxWaiters = 256

    private let lock = NSLock()
    private var pending: [String: (question: Question, waiters: [@Sendable (Outcome) -> Void])] = [:]
    private var byDestination: [String: String] = [:]  // container + destination → question id
    /// What was answered for a running container, until it stops: destination → allowed.
    private var session: [String: [String: Bool]] = [:]
    private let queue = DispatchQueue(label: "pratico.egress.questions")

    /// Destinations answered `always`, per container: read once from where the daemon keeps
    /// them, written back on each new one.
    private var always: [String: [String]] = [:]
    var load: @Sendable (_ container: String) -> [String] = { _ in [] }
    var save: @Sendable (_ container: String, _ destinations: [String]) -> Void = { _, _ in }
    /// Destinations a container's allowlist holds at most from answers.
    static let maxAlways = 1024

    /// What was answered for this destination while the container runs, if anything.
    func decided(_ container: String, _ destination: String) -> Bool? {
        lock.withLock { session[container]?[destination] }
    }

    /// What a container's allowlist holds from `always` answers.
    func alwaysAllowed(_ container: String) -> [String] {
        lock.withLock {
            if let known = always[container] { return known }
            let read = Array(load(container).prefix(Self.maxAlways))
            always[container] = read
            return read
        }
    }

    /// Asks, or joins the question already open for this destination; `done` runs once,
    /// on an arbitrary queue, with whether the connection may go.
    func ask(_ container: String, _ destination: String, port: UInt16, _ done: @escaping @Sendable (Outcome) -> Void) {
        let key = container + "\u{1F}" + destination
        let opened: Question? = lock.withLock {
            if let allowed = session[container]?[destination] {
                queue.async { done(allowed ? .allowed : Self.denied(destination)) }
                return nil
            }
            if let id = byDestination[key], pending[id] != nil {
                if pending[id]!.waiters.count < Self.maxWaiters { pending[id]!.waiters.append(done) } else { queue.async { done(.refused("too many connections waiting on one question")) } }
                return nil
            }
            guard pending.count < Self.maxPending else {
                queue.async { done(.refused("more than \(Self.maxPending) questions open")) }
                return nil
            }
            guard pending.values.filter({ $0.question.container == container }).count < Self.maxPendingPerContainer else {
                queue.async { done(.refused("more than \(Self.maxPendingPerContainer) of this container's questions open")) }
                return nil
            }
            let q = Question(id: randomHexID().prefix(16).description, container: container, destination: destination, port: port, asked: Date())
            pending[q.id] = (q, [done])
            byDestination[key] = q.id
            return q
        }
        guard let opened else { return }
        queue.asyncAfter(deadline: .now() + wait) { [weak self, wait] in
            self?.close(opened.id, .refused("\(destination) was not answered within \(Int(wait)) s"), remember: nil)
        }
    }

    func list() -> [Question] { lock.withLock { pending.values.map(\.question).sorted { $0.asked < $1.asked } } }

    /// False when no such question is open (answered already, or timed out).
    @discardableResult
    func answer(_ id: String, _ answer: Answer) -> Bool {
        guard let q = lock.withLock({ pending[id]?.question }) else { return false }
        if answer == .always {
            let list: [String]? = lock.withLock {
                var list = always[q.container] ?? load(q.container)
                guard !list.contains(q.destination), list.count < Self.maxAlways else { return nil }
                list.append(q.destination)
                always[q.container] = list
                return list
            }
            if let list { save(q.container, list) }
        }
        return close(id, answer == .deny ? Self.denied(q.destination) : .allowed, remember: answer)
    }

    @discardableResult
    private func close(_ id: String, _ outcome: Outcome, remember answer: Answer?) -> Bool {
        let entry: (question: Question, waiters: [@Sendable (Outcome) -> Void])? = lock.withLock {
            guard let e = pending.removeValue(forKey: id) else { return nil }
            byDestination[e.question.container + "\u{1F}" + e.question.destination] = nil
            if let answer, answer != .always { session[e.question.container, default: [:]][e.question.destination] = answer == .allow }
            return e
        }
        guard let entry else { return false }
        for w in entry.waiters { queue.async { w(outcome) } }
        return true
    }

    /// The container is gone: its `always` answers go with it.
    func removed(_ container: String) {
        stopped(container)
        lock.withLock { always[container] = nil }
    }

    /// The container stopped: its answers end, and its open questions are refused.
    func stopped(_ container: String) {
        let open = lock.withLock {
            session[container] = nil
            return pending.values.filter { $0.question.container == container }.map(\.question.id)
        }
        for id in open { close(id, .refused("the container stopped"), remember: nil) }
    }

    static func denied(_ destination: String) -> Outcome { .refused("\(destination) was refused when asked") }
}
