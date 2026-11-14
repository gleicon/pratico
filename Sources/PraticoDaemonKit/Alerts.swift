import Foundation

/// `~/.pratico/alerts.json`: what the menubar lists under Alerts and turns into
/// notifications (SPEC FR-33, D-24). Newest last, capped at 50, one per `key`.
final class AlertLog: @unchecked Sendable {
    let path: URL
    private let lock = NSLock()
    static let limit = 50

    init(path: URL) { self.path = path }

    /// Records the alert unless one with `key` is already there. With `replace`, the new
    /// one takes its place instead (a rescan's verdict supersedes the last one).
    func raise(key: String, level: String, title: String, detail: String, replace: Bool = false) {
        lock.lock()
        defer { lock.unlock() }
        var list = read()
        if list.contains(where: { $0["key"]?.string == key }) {
            guard replace else { return }
            list.removeAll { $0["key"]?.string == key }
        }
        list.append(["time": .string(Timestamp.format(Date())), "level": .string(level), "key": .string(key),
                     "title": .string(title), "detail": .string(detail)])
        if list.count > Self.limit { list.removeFirst(list.count - Self.limit) }
        write(list)
    }

    /// Drops the alert with `key`, so the condition alerts again if it comes back.
    func resolve(key: String) {
        lock.lock()
        defer { lock.unlock() }
        let list = read()
        let kept = list.filter { $0["key"]?.string != key }
        if kept.count != list.count { write(kept) }
    }

    /// The menubar's Clear Alerts.
    func clear() {
        lock.lock()
        defer { lock.unlock() }
        write([])
    }

    private func read() -> [JSON] { (try? Data(contentsOf: path)).flatMap { JSON.parse($0)?.array } ?? [] }
    private func write(_ list: [JSON]) { try? JSON.array(list).encoded().write(to: path, options: .atomic) }
}

/// Alerts about running containers (FR-33): a port published on an address other than
/// loopback, which other machines can reach, and a healthcheck turning `unhealthy`.
/// Driven by the container events, so it sees every start whoever made it.
final class ContainerAlerts: @unchecked Sendable {
    let alerts: AlertLog
    let containers: ContainerService

    init(alerts: AlertLog, containers: ContainerService, events: EventBus) {
        self.alerts = alerts
        self.containers = containers
        _ = events.subscribe(since: nil) { [weak self] e in
            guard let self else { return false }
            if e.type == "container" { handle(e) }
            return true
        }
    }

    static func isLoopback(_ ip: String) -> Bool { ip.hasPrefix("127.") || ip == "::1" || ip == "localhost" }

    private func handle(_ e: DockerEvent) {
        let name = e.attributes["name"] ?? String(e.id.prefix(12))
        switch e.action {
        case "start":
            guard let rec = try? containers.resolve(e.id) else { return }
            for p in containers.ports(rec) {
                guard let ip = p["IP"]?.string, !Self.isLoopback(ip), let port = p["PublicPort"]?.int else { continue }
                let shown = ip == "0.0.0.0" || ip == "::" ? "\(ip) (every network this Mac is on)" : ip
                alerts.raise(
                    key: "port:\(e.id):\(ip):\(port)", level: "warning",
                    title: "\(name) is reachable from other machines on port \(port)",
                    detail: "Container \(name) publishes port \(port) on \(shown). Publish it as -p 127.0.0.1:\(port):\(p["PrivatePort"]?.int ?? port) to keep it on this Mac.")
            }
        case "health_status: unhealthy":
            alerts.raise(key: "health:\(e.id)", level: "warning", title: "\(name) is unhealthy",
                         detail: "Container \(name)'s healthcheck is failing. docker inspect \(name) shows its last checks.")
        case "health_status: healthy":
            alerts.resolve(key: "health:\(e.id)")
        default:
            break
        }
    }
}
