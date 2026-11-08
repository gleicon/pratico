import Foundation

/// One Docker event, in the `/events` wire format.
struct DockerEvent: Sendable {
    var type: String  // container | image
    var action: String
    var id: String
    var attributes: [String: String]
    var time: Date

    var json: JSON {
        let nanos = Int64(time.timeIntervalSince1970 * 1e9)
        var j: [String: JSON] = [
            "Type": .string(type),
            "Action": .string(action),
            "Actor": ["ID": .string(id), "Attributes": JSON(attributes)],
            "scope": "local",
            "time": .int(nanos / 1_000_000_000),
            "timeNano": .int(nanos),
        ]
        // Legacy fields some clients still read.
        if type == "container" {
            j["status"] = .string(action)
            j["id"] = .string(id)
            j["from"] = .string(attributes["image"] ?? "")
        }
        return .object(j)
    }

    /// Docker `filters` semantics: OR within a key, AND across keys.
    func matches(_ filters: [String: [String]]) -> Bool {
        for (key, values) in filters where !values.isEmpty {
            let ok = values.contains { v in
                switch key {
                case "type": return type == v
                case "event": return action == v || action.hasPrefix(v + ":")
                case "container": return type == "container" && (id.hasPrefix(v) || attributes["name"] == v)
                case "image": return attributes["image"] == v || (type == "image" && id == v)
                case "label":
                    let (k, val) = v.splitOnce("=")
                    guard let have = attributes[k] else { return false }
                    return val == nil || have == val
                default: return true
                }
            }
            if !ok { return false }
        }
        return true
    }
}

/// Fan-out of daemon events (SPEC FR-20), with a bounded in-memory history for `since`.
final class EventBus: @unchecked Sendable {
    typealias Subscriber = @Sendable (DockerEvent) -> Bool  // false = unsubscribe
    private let lock = NSLock()
    private var history: [DockerEvent] = []
    private var subscribers: [Int: Subscriber] = [:]
    private var nextId = 0
    static let historyLimit = 1000

    func emit(_ type: String, _ action: String, id: String, attributes: [String: String] = [:]) {
        let e = DockerEvent(type: type, action: action, id: id, attributes: attributes, time: Date())
        lock.lock()
        history.append(e)
        if history.count > Self.historyLimit { history.removeFirst(history.count - Self.historyLimit) }
        let subs = subscribers
        lock.unlock()
        for (key, s) in subs where !s(e) {
            lock.lock()
            subscribers[key] = nil
            lock.unlock()
        }
    }

    /// Past events from `since`, then live ones, atomically (no gap, no duplicate).
    func subscribe(since: Date?, _ s: @escaping Subscriber) -> (past: [DockerEvent], token: Int) {
        lock.lock()
        defer { lock.unlock() }
        let past = since.map { t in history.filter { $0.time >= t } } ?? []
        let token = nextId
        nextId += 1
        subscribers[token] = s
        return (past, token)
    }

    func unsubscribe(_ token: Int) {
        lock.lock()
        subscribers[token] = nil
        lock.unlock()
    }

    /// `GET /events`. Streams until `until` passes or the client goes away.
    func serve(_ req: Request, conn: Connection) {
        let filters = ContainerService.parseFilters(req.query["filters"])
        let since = req.query["since"].flatMap(Self.parseTime)
        let until = req.query["until"].flatMap(Self.parseTime)
        conn.beginChunked()
        let gone = DispatchSemaphore(value: 0)
        let send: @Sendable (DockerEvent) -> Bool = { e in
            if let until, e.time > until { return true }
            guard e.matches(filters) else { return true }
            if conn.chunk(e.json.encoded() + Data("\n".utf8)) { return true }
            gone.signal()
            return false
        }
        // Live events queue behind the replay so order holds.
        let queue = DispatchQueue(label: "pratico.events")
        let sub = subscribe(since: since) { e in queue.sync { send(e) } }
        queue.sync { for e in sub.past where !send(e) { break } }
        if let until {
            let wait = until.timeIntervalSinceNow
            if wait > 0 { _ = gone.wait(timeout: .now() + wait) }
        } else {
            // Keepalive probe: an empty chunk is invalid, so detect a closed peer by reading.
            while gone.wait(timeout: .now() + 1) == .timedOut {
                var pfd = pollfd(fd: conn.fd, events: Int16(POLLIN), revents: 0)
                if poll(&pfd, 1, 0) > 0 { break }  // client sent EOF (or data it should not)
            }
        }
        unsubscribe(sub.token)
        queue.sync {}
        conn.endChunked()
    }

    /// Docker accepts Unix seconds (optionally fractional) or RFC 3339.
    static func parseTime(_ s: String) -> Date? {
        if let d = Double(s) { return Date(timeIntervalSince1970: d) }
        return Timestamp.parse(s)
    }
}
