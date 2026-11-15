import Foundation

/// Docker's filter semantics, in one place for every list, prune, and events endpoint.
/// Values of one key are alternatives (OR), keys combine (AND), except `label`: every
/// label filter must match, as dockerd's `MatchKVList` does.
enum Filters {
    /// `label=k` (present) or `label=k=v` (equal).
    static func label(_ filter: String, in have: [String: String]) -> Bool {
        let (k, v) = filter.splitOnce("=")
        guard let value = have[k] else { return false }
        return v == nil || value == v
    }

    /// Every `label` filter matches; no filters match everything.
    static func labels(_ filters: [String]?, in have: [String: String]) -> Bool {
        (filters ?? []).allSatisfy { label($0, in: have) }
    }

    /// dockerd's boolean filter and query values: `1` and `true`.
    static func isTrue(_ value: String) -> Bool { value == "1" || value.lowercased() == "true" }

    /// Whether `key` asks for true (any of its values), nil when the key is absent.
    static func bool(_ filters: [String: [String]], _ key: String) -> Bool? {
        filters[key].map { $0.contains(where: isTrue) }
    }

    /// Applies `filters` to one item: `label` against `labels`, every other key through
    /// `match`, OR across its values; keys `match` does not know are ignored by returning true.
    static func pass(_ filters: [String: [String]], labels: [String: String], _ match: (String, String) -> Bool) -> Bool {
        guard self.labels(filters["label"], in: labels) else { return false }
        for (key, values) in filters where key != "label" && !values.isEmpty {
            if !values.contains(where: { match(key, $0) }) { return false }
        }
        return true
    }
}

/// Docker's prune filters: `until` (Unix time, RFC 3339, or a duration back from now such
/// as `24h` or `1h30m`) keeps what was created after it; `label=k[=v]` keeps only matches,
/// `label!=k[=v]` drops them. Any other filter is refused, as dockerd does.
struct PruneFilter {
    var until: Date?
    var labels: [String] = []
    var notLabels: [String] = []

    init(_ filters: [String: [String]], allowed: Set<String> = ["until", "label", "label!"]) throws {
        for key in filters.keys where !allowed.contains(key) {
            throw APIError(400, "invalid filter '\(key)'")
        }
        if let raw = filters["until"]?.last {
            guard let date = Self.time(raw) else { throw APIError(400, "invalid filter 'until=\(raw)'") }
            until = date
        }
        labels = filters["label"] ?? []
        notLabels = filters["label!"] ?? []
    }

    func matches(created: Date, labels have: [String: String]) -> Bool {
        if let until, created >= until { return false }
        return Filters.labels(labels, in: have) && !notLabels.contains { Filters.label($0, in: have) }
    }

    static func time(_ raw: String) -> Date? {
        if let d = duration(raw) { return Date().addingTimeInterval(-d) }
        return EventBus.parseTime(raw)
    }

    /// Go's duration syntax: one or more `<number><unit>`, units h, m, s, ms.
    static func duration(_ raw: String) -> TimeInterval? {
        let units: [String: Double] = ["h": 3600, "m": 60, "s": 1, "ms": 0.001]
        var total = 0.0
        var rest = Substring(raw)
        guard !rest.isEmpty else { return nil }
        while !rest.isEmpty {
            let number = rest.prefix { $0.isNumber || $0 == "." }
            rest = rest.dropFirst(number.count)
            let unit = rest.prefix { $0.isLetter }
            rest = rest.dropFirst(unit.count)
            guard let n = Double(number), let scale = units[String(unit)] else { return nil }
            total += n * scale
        }
        return total
    }
}
