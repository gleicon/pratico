import Foundation

/// `~/.pratico/alerts.json`: what the menubar lists under Alerts and turns into
/// notifications (SPEC FR-33, D-24). Newest last, capped at 50, one per `key`.
final class AlertLog: @unchecked Sendable {
    let path: URL
    private let lock = NSLock()
    static let limit = 50

    init(path: URL) {
        self.path = path
        mergeUnkeyed()
    }

    /// Alerts written before alerts had a `key` repeat each rescan's verdict: each gets its
    /// title as key, and the newest of a title is kept.
    private func mergeUnkeyed() {
        lock.lock()
        defer { lock.unlock() }
        let list = read()
        guard list.contains(where: { $0["key"] == nil }) else { return }
        var seen = Set<String>()
        var kept: [JSON] = []
        for alert in list.reversed() {
            guard case .object(var fields) = alert else { continue }
            let key = fields["key"]?.string ?? "title:" + (fields["title"]?.string ?? "")
            guard seen.insert(key).inserted else { continue }
            fields["key"] = .string(key)
            kept.append(.object(fields))
        }
        assert(kept.count <= list.count, "merging added alerts")
        write(kept.reversed())
    }

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

    /// Drops every alert whose key starts with `prefix`: all of one container's.
    func resolve(prefix: String) {
        precondition(!prefix.isEmpty, "an empty prefix would drop every alert")
        lock.lock()
        defer { lock.unlock() }
        let list = read()
        let kept = list.filter { !($0["key"]?.string ?? "").hasPrefix(prefix) }
        if kept.count != list.count { write(kept) }
    }

    /// Drops port and health alerts (`port:<id>:…`, `health:<id>`) of containers not in
    /// `ids`: ones removed while the daemon was away, or before alerts ended at removal.
    func dropContainerAlerts(except ids: Set<String>) {
        lock.lock()
        defer { lock.unlock() }
        let list = read()
        let kept = list.filter { alert in
            let parts = (alert["key"]?.string ?? "").split(separator: ":", maxSplits: 2).map(String.init)
            guard parts.count >= 2, ["port", "health", "drift"].contains(parts[0]) else { return true }
            return ids.contains(parts[1])
        }
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
/// loopback, which other machines can reach, and a healthcheck turning `unhealthy`; both
/// end when the container is removed.
/// Driven by the container events, so it sees every start whoever made it.
final class ContainerAlerts: @unchecked Sendable {
    let alerts: AlertLog
    let containers: ContainerService
    /// Ask-mode containers' activity, read again when it grows: what alerts for drift.
    private let drift = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "pratico.alerts.drift"))
    private var activitySize: [String: Int] = [:]  // container → its activity log's size when last read
    static let driftEvery: DispatchTimeInterval = .seconds(2)
    /// Events read from an ask-mode container's activity each time it grows.
    static let driftWindow = 500

    init(alerts: AlertLog, containers: ContainerService, events: EventBus) {
        self.alerts = alerts
        self.containers = containers
        alerts.dropContainerAlerts(except: Set(containers.all().map(\.id)))
        _ = events.subscribe(since: nil) { [weak self] e in
            guard let self else { return false }
            if e.type == "container" { handle(e) }
            return true
        }
        drift.schedule(deadline: .now() + Self.driftEvery, repeating: Self.driftEvery)
        drift.setEventHandler { [weak self] in self?.checkDrift() }
        drift.resume()
    }

    deinit { drift.cancel() }

    /// Ask mode (D-62) watches a container closely: running a file that did not come with
    /// its image (`FromImage` false) alerts. Other containers only mark it in their activity,
    /// as builds run what they write all the time.
    private func checkDrift() {
        var live: Set<String> = []
        for rec in containers.all() where rec.state.running && rec.labels[MCPTools.askLabel] == "true" {
            live.insert(rec.id)
            let files = containers.shimFiles(rec.id)
            let size = (try? FileManager.default.attributesOfItem(atPath: files.activity.path)[.size] as? Int) ?? 0
            guard size != activitySize[rec.id] else { continue }
            activitySize[rec.id] = size
            for e in containers.activity(rec.id, limit: Self.driftWindow) where e["Kind"]?.string == "exec" && e["FromImage"]?.bool == false {
                let path = e["Path"]?.string ?? "?"
                alerts.raise(key: "drift:\(rec.id):\(path)", level: "serious", title: "\(rec.name) ran \(path), which is not from its image",
                             detail: "\(rec.name) is in ask mode, and ran \(path) (\(e["Command"]?.string ?? "")), a file it downloaded, built, or changed, or one on a volume. Its activity has the arguments and the process that started it.")
            }
        }
        activitySize = activitySize.filter { live.contains($0.key) }
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
        case "destroy":  // not at stop: a restart would raise and notify it again
            alerts.resolve(prefix: "port:\(e.id):")
            alerts.resolve(prefix: "drift:\(e.id):")
            alerts.resolve(key: "health:\(e.id)")
        default:
            break
        }
    }
}
