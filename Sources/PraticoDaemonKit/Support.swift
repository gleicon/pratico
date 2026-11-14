import Foundation
import PraticoCore

/// Docker Engine API version pratico advertises (SPEC FR-6.a/b, D-5): the latest
/// published when implementation started (Docker 29.6, API 1.55) and that release's minimum.
public enum DockerAPI {
    public static let version = "1.55"
    public static let minVersion = "1.44"

    /// Docker Engine's check on a `/vX.Y` request, with its words: a client outside the
    /// supported range is refused, so an old CLI says so instead of misbehaving (AC-49).
    static func accept(_ requested: String?) throws {
        guard let requested else { return }
        if compare(requested, minVersion) < 0 {
            throw APIError(400, "client version \(requested) is too old. Minimum supported API version is \(minVersion), please upgrade your client to a newer version")
        }
        if compare(requested, version) > 0 {
            throw APIError(400, "client version \(requested) is too new. Maximum supported API version is \(version)")
        }
    }

    /// Dotted versions compared numerically: 1.9 < 1.44.
    static func compare(_ a: String, _ b: String) -> Int {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l < r ? -1 : 1 }
        }
        return 0
    }
}

public enum DaemonInfo {
    public static let version = Pratico.version
}

enum Timestamp {
    static let zero = "0001-01-01T00:00:00Z"

    static func format(_ date: Date?) -> String {
        guard let date else { return zero }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    static func parse(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    /// Docker's `units.HumanDuration`, used in `docker ps` status strings.
    static func human(since date: Date?, now: Date = Date()) -> String {
        let s = Int(now.timeIntervalSince(date ?? now))
        switch s {
        case ..<1: return "Less than a second"
        case 1: return "1 second"
        case ..<60: return "\(s) seconds"
        case ..<120: return "About a minute"
        case ..<3600: return "\(s / 60) minutes"
        case ..<7200: return "About an hour"
        case ..<172_800: return "\(s / 3600) hours"
        default: return "\(s / 86400) days"
        }
    }
}

enum Names {
    private static let left = ["brave", "calm", "eager", "fond", "keen", "lucid", "nifty", "quiet", "sharp", "witty"]
    private static let right = ["albatross", "barge", "buoy", "harbour", "keel", "mast", "pilot", "rudder", "tug", "wharf"]

    /// Docker-style generated name (`adjective_noun`).
    static func random() -> String { "\(left.randomElement()!)_\(right.randomElement()!)" }

    static func valid(_ name: String) -> Bool {
        guard let first = name.first, first.isLetter || first.isNumber, name.count >= 2 else { return false }
        return name.allSatisfy { $0.isLetter || $0.isNumber || "_.-".contains($0) }
    }
}

func randomHexID() -> String {
    (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
}

/// A scanner run's exit status and output.
struct ProcessResult: Sendable {
    var status: Int32
    var stdout: Data
    var stderr: Data

    var ok: Bool { status == 0 }
    var errorText: String {
        String(decoding: stderr.isEmpty ? stdout : stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// A mutable value shared with a closure.
final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}
