import ContainerizationArchive
import ContainerizationOCI
import ContainerizationOS
import Foundation
import PraticoCore

/// The threat feeds egress protection matches against (D-51), fetched on this Mac and
/// cached in `scan-db/egress/`, so a daemon offline uses the last copy. Nothing is
/// redistributed. Without a key: Feodo Tracker and SSL Blacklist (abuse.ch, CC0) and
/// Spamhaus DROP. With a free abuse.ch Auth-Key (Keychain): URLhaus and ThreatFox.
final class EgressFeeds: @unchecked Sendable {
    struct Feed: Sendable {
        var name: String
        var url: String
        var keyed: Bool
        var refresh: TimeInterval
        var parse: @Sendable (Data, inout ThreatSet) -> Void
    }

    static let keychainDomain = "dev.pratico.egress"
    static let keychainHost = "abuse.ch"
    /// A feed bigger than this is not read: the caps hold whatever a server sends.
    static let maxBytes = 64 << 20

    let dir: URL
    let env: [String: String]
    let guardian: EgressGuard
    private let queue = DispatchQueue(label: "pratico.egress-feeds")
    private let lock = NSLock()
    private var status: [String: (entries: Int, updated: Date?, error: String?)] = [:]

    init(dir: URL, guardian: EgressGuard, env: [String: String] = ProcessInfo.processInfo.environment) {
        self.dir = dir
        self.guardian = guardian
        self.env = env
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    static let all: [Feed] = [
        Feed(name: "feodo", url: "https://feodotracker.abuse.ch/downloads/ipblocklist.txt", keyed: false, refresh: 3600) { d, s in
            for ip in lines(d) { if let a = IPv4.parse(ip) { s.addresses[a] = "Feodo Tracker (botnet C2)" } }
        },
        Feed(name: "sslbl", url: "https://sslbl.abuse.ch/blacklist/sslipblacklist.txt", keyed: false, refresh: 3600) { d, s in
            for line in lines(d) {
                let (ip, port) = line.splitOnce(",")
                guard let a = IPv4.parse(ip) else { continue }
                if let port, let p = UInt16(port) { s.ipPorts[UInt64(a) << 16 | UInt64(p)] = "SSL Blacklist (botnet C2)" } else { s.addresses[a] = "SSL Blacklist (botnet C2)" }
            }
        },
        Feed(name: "spamhaus-drop", url: "https://www.spamhaus.org/drop/drop_v4.json", keyed: false, refresh: 24 * 3600) { d, s in
            for line in lines(d) { if let cidr = JSON.parse(Data(line.utf8))?["cidr"]?.string { s.addRange(cidr, "Spamhaus DROP (hijacked network)") } }
        },
        Feed(name: "urlhaus", url: "https://urlhaus-api.abuse.ch/v2/files/exports/{key}/recent.csv", keyed: true, refresh: 3600) { d, s in
            for f in csv(d) where f.count > 2 {
                guard let host = URL(string: f[2])?.host?.lowercased(), !sharedHost(host) else { continue }
                if let a = IPv4.parse(host) { s.addresses[a] = "URLhaus (malware distribution)" } else { s.names[host] = "URLhaus (malware distribution)" }
            }
        },
        Feed(name: "threatfox", url: "https://threatfox-api.abuse.ch/v2/files/exports/{key}/full.csv.zip", keyed: true, refresh: 3600) { d, s in
            for f in csv(unzipped(d)) where f.count > 3 {
                let value = f[2], label = "ThreatFox (\(f.count > 4 ? f[4] : "IOC"))"
                switch f[3] {
                case "domain": if !sharedHost(value) { s.names[value.lowercased()] = label }
                case "ip:port":
                    let (ip, port) = value.splitOnce(":")
                    if let a = IPv4.parse(ip), let p = port.flatMap(UInt16.init) { s.ipPorts[UInt64(a) << 16 | UInt64(p)] = label }
                case "url":
                    if let host = URL(string: value)?.host?.lowercased(), !sharedHost(host), IPv4.parse(host) == nil { s.names[host] = label }
                default: break
                }
            }
        },
    ]

    /// Hosts many people share (code hosting, file sharing, clouds' storage): a feed's URL
    /// on one names a file there, not the host; blocking the host would cut off GitHub.
    /// Their URLs wait for HTTPS inspection, which can see the path.
    static let shared = ["github.com", "githubusercontent.com", "gitlab.com", "bitbucket.org", "google.com", "googleapis.com",
                         "googleusercontent.com", "dropbox.com", "dropboxusercontent.com", "discord.com", "discordapp.com",
                         "discordapp.net", "onedrive.live.com", "1drv.ms", "sharepoint.com", "mediafire.com", "pastebin.com",
                         "amazonaws.com", "cloudfront.net", "blob.core.windows.net", "azureedge.net", "pages.dev", "workers.dev",
                         "r2.dev", "vercel.app", "netlify.app", "herokuapp.com", "telegram.org", "t.me", "archive.org",
                         "transfer.sh", "catbox.moe", "bit.ly", "tinyurl.com"]

    static func sharedHost(_ host: String) -> Bool {
        let h = host.lowercased()
        return shared.contains { h == $0 || h.hasSuffix("." + $0) }
    }

    // MARK: Refresh

    /// Loads the caches, then refreshes each feed when its time comes, in the background.
    func start() {
        rebuild()
        queue.async { [self] in
            while true {
                var changed = false
                for feed in Self.all where refreshIfDue(feed) { changed = true }
                if changed { rebuild() }
                Thread.sleep(forTimeInterval: 300)
            }
        }
    }

    private func cache(_ feed: Feed) -> URL { dir.appending(path: feed.name) }

    /// True when a new copy was written.
    private func refreshIfDue(_ feed: Feed) -> Bool {
        let file = cache(feed)
        let age = (try? FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date).map { Date().timeIntervalSince($0) } ?? .infinity
        guard age > feed.refresh else { return false }
        let override = env["PRATICO_EGRESS_\(feed.name.uppercased().replacingOccurrences(of: "-", with: "_"))_URL"]
        var raw = override ?? feed.url
        if feed.keyed && override == nil {  // an override (a file:// URL in tests) needs no key
            guard let key = Self.key() else {
                note(feed.name, error: "needs a free abuse.ch Auth-Key (Settings or POST /pratico/egress/key)")
                return false
            }
            raw = raw.replacingOccurrences(of: "{key}", with: key.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")
        }
        // An empty answer is a feed with nothing listed now (SSL Blacklist often is), not a failure.
        guard let url = URL(string: raw), let data = ScanService.fetch(url, timeout: 60), data.count <= Self.maxBytes else {
            note(feed.name, error: "fetch failed; using the last copy")
            return false
        }
        do { try data.write(to: file, options: .atomic) } catch {
            note(feed.name, error: "cannot cache: \(error)")
            return false
        }
        return true
    }

    /// Every cached feed merged into one set, handed to the guard.
    func rebuild() {
        var set = ThreatSet()
        for feed in Self.all {
            guard let data = try? Data(contentsOf: cache(feed)), data.count <= Self.maxBytes else { continue }
            var one = ThreatSet()
            feed.parse(data, &one)
            set.names.merge(one.names) { a, _ in a }
            set.addresses.merge(one.addresses) { a, _ in a }
            set.ipPorts.merge(one.ipPorts) { a, _ in a }
            set.ranges += one.ranges
            let updated = (try? FileManager.default.attributesOfItem(atPath: cache(feed).path)[.modificationDate] as? Date)
            lock.withLock { status[feed.name] = (one.names.count + one.addresses.count + one.ipPorts.count + one.ranges.count, updated, nil) }
        }
        set.sortRanges()
        guardian.setFeeds(set)
    }

    private func note(_ feed: String, error: String) {
        lock.withLock {
            let old = status[feed]
            status[feed] = (old?.entries ?? 0, old?.updated, error)
        }
    }

    /// `GET /pratico/egress/feeds`.
    func summary() -> JSON {
        let s = lock.withLock { status }
        return [
            "Block": .bool(guardian.blockThreats),
            "Key": .bool(Self.key() != nil),
            "Feeds": .array(Self.all.map { f in
                let st = s[f.name]
                return ["Name": .string(f.name), "NeedsKey": .bool(f.keyed), "Entries": .int(Int64(st?.entries ?? 0)),
                        "Updated": st?.updated.map { .string(Timestamp.format($0)) } ?? .null, "Error": st?.error.map(JSON.string) ?? .null]
            }),
        ]
    }

    // MARK: The abuse.ch key

    static func key() -> String? {
        (try? KeychainQuery().get(securityDomain: keychainDomain, hostname: keychainHost))?.password
    }

    /// Stores the key and fetches the keyed feeds now.
    func setKey(_ key: String?) throws {
        let helper = KeychainHelper(securityDomain: Self.keychainDomain)
        if let key {
            guard (16...128).contains(key.count), key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else {
                throw APIError(400, "that does not look like an abuse.ch Auth-Key")
            }
            try helper.save(hostname: Self.keychainHost, username: "auth-key", password: key)
            queue.async { [self] in
                for feed in Self.all where feed.keyed { try? FileManager.default.removeItem(at: cache(feed)); _ = refreshIfDue(feed) }
                rebuild()
            }
        } else {
            try? helper.delete(hostname: Self.keychainHost)
            for feed in Self.all where feed.keyed { try? FileManager.default.removeItem(at: cache(feed)) }
            rebuild()
        }
    }

    // MARK: Parsing

    static func lines(_ d: Data) -> [String] {
        String(decoding: d, as: UTF8.self).split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    /// abuse.ch's CSV: quoted fields, `#` comment lines.
    static func csv(_ d: Data) -> [[String]] {
        lines(d).map { line in
            var fields: [String] = [], field = "", quoted = false
            for c in line {
                if c == "\"" { quoted.toggle() } else if c == ",", !quoted { fields.append(field.trimmingCharacters(in: .whitespaces)); field = "" } else { field.append(c) }
            }
            fields.append(field.trimmingCharacters(in: .whitespaces))
            return fields
        }
    }

    /// The first file of a zip, bounded.
    static func unzipped(_ d: Data) -> Data {
        let tmp = FileManager.default.temporaryDirectory.appending(path: "pratico-feed-\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: tmp) }
        guard (try? d.write(to: tmp)) != nil, let reader = try? ArchiveReader(file: tmp) else { return Data() }
        for (_, data) in reader where !data.isEmpty { return data.count <= maxBytes ? data : Data() }
        return Data()
    }
}
