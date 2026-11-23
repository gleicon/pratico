import Foundation

/// Where an `ssh://` docker context leads, resolved as `ssh` resolves it from
/// `~/.ssh/config`, for the settings pratico's own SSH uses: `HostName`, `Port`, `User`,
/// `IdentityFile`, `UserKnownHostsFile`, and `Include`. A host that needs a jump or a proxy
/// is refused rather than reached some other way. `Match` blocks are not evaluated.
public struct SSHTarget: Sendable, Equatable {
    public var alias: String
    public var hostName: String
    public var port: Int
    public var user: String
    public var identityFiles: [String]
    public var knownHostsFiles: [String]

    public struct Unsupported: Error, CustomStringConvertible {
        public let description: String
    }

    /// `user@host:port` as a docker context's `ssh://` endpoint carries it.
    public static func resolve(_ endpoint: String, config: URL? = nil, home: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> SSHTarget {
        var rest = Substring(endpoint)
        var user: String?
        if let at = rest.lastIndex(of: "@") {
            user = String(rest[..<at])
            rest = rest[rest.index(after: at)...]
        }
        var port: Int?
        if let colon = rest.lastIndex(of: ":"), let p = Int(rest[rest.index(after: colon)...]) {
            port = p
            rest = rest[..<colon]
        }
        let alias = String(rest)
        guard !alias.isEmpty else { throw Unsupported(description: "no host in ssh://\(endpoint)") }

        let file = config ?? home.appending(path: ".ssh/config")
        var settings: [String: [String]] = [:]
        try SSHConfigParser(home: home, alias: alias).read(file, into: &settings, depth: 0)
        for refused in ["proxyjump", "proxycommand"] where settings[refused] != nil {
            throw Unsupported(description: "\(alias) is reached through \(refused == "proxyjump" ? "ProxyJump" : "ProxyCommand") in ~/.ssh/config, which pratico's SSH does not do")
        }
        let resolvedUser = user ?? settings["user"]?.first ?? NSUserName()
        let tokens = { (s: String) in SSHConfigParser.expand(s, home: home, host: alias, user: resolvedUser) }
        let ssh = home.appending(path: ".ssh").path
        return SSHTarget(
            alias: alias,
            hostName: settings["hostname"]?.first.map(tokens) ?? alias,
            port: port ?? settings["port"]?.first.flatMap { Int($0) } ?? 22,
            user: resolvedUser,
            identityFiles: settings["identityfile"]?.map(tokens) ?? ["\(ssh)/id_ed25519", "\(ssh)/id_ecdsa"],
            knownHostsFiles: (settings["userknownhostsfile"]?.first?.split(separator: " ").map { tokens(String($0)) }
                ?? ["\(ssh)/known_hosts", "\(ssh)/known_hosts2"]) + ["/etc/ssh/ssh_known_hosts"])
    }
}

/// OpenSSH's rules for the subset: keywords are case-insensitive, the first value given
/// wins (except `IdentityFile`, which adds up), and `Host` patterns take `*`, `?` and `!`.
struct SSHConfigParser {
    let home: URL
    let alias: String
    static let maxIncludeDepth = 8

    func read(_ file: URL, into settings: inout [String: [String]], depth: Int) throws {
        guard depth <= Self.maxIncludeDepth else { throw SSHTarget.Unsupported(description: "~/.ssh/config includes more than \(Self.maxIncludeDepth) levels deep") }
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return }
        var applies = true
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let parts = Self.split(line)
            guard let keyword = parts.first?.lowercased(), parts.count > 1 else { continue }
            let values = Array(parts.dropFirst())
            switch keyword {
            case "host": applies = Self.matches(alias, patterns: values)
            case "match": applies = false  // not evaluated: its settings are not applied
            case "include" where applies:
                for pattern in values { for f in expandInclude(pattern) { try read(f, into: &settings, depth: depth + 1) } }
            case "identityfile" where applies: settings[keyword, default: []] += values
            default:
                if applies && settings[keyword] == nil { settings[keyword] = [values.joined(separator: " ")] }
            }
        }
    }

    /// `Include` paths: relative ones are under ~/.ssh; `*` and `?` match file names.
    func expandInclude(_ pattern: String) -> [URL] {
        var path = pattern.hasPrefix("~/") ? home.path + pattern.dropFirst() : pattern
        if !path.hasPrefix("/") { path = home.appending(path: ".ssh").path + "/" + path }
        let dir = URL(filePath: path).deletingLastPathComponent()
        let name = URL(filePath: path).lastPathComponent
        guard name.contains("*") || name.contains("?") else { return [URL(filePath: path)] }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.filter { Self.glob(name, $0) }.sorted().map { dir.appending(path: $0) }
    }

    /// Words, with double quotes grouping, and `key=value` as `key value`.
    static func split(_ line: String) -> [String] {
        var words: [String] = []
        var word = ""
        var quoted = false
        for ch in line {
            if ch == "\"" { quoted.toggle(); continue }
            if !quoted && (ch == " " || ch == "\t" || (ch == "=" && words.isEmpty)) {
                if !word.isEmpty { words.append(word); word = "" }
            } else {
                word.append(ch)
            }
        }
        if !word.isEmpty { words.append(word) }
        return words
    }

    static func matches(_ host: String, patterns: [String]) -> Bool {
        var matched = false
        for p in patterns {
            if p.hasPrefix("!") {
                if glob(String(p.dropFirst()), host) { return false }
            } else if glob(p, host) {
                matched = true
            }
        }
        return matched
    }

    /// `*` and `?` only, as ssh's patterns; iterative, bounded by both lengths.
    static func glob(_ pattern: String, _ text: String) -> Bool {
        let p = Array(pattern.lowercased()), t = Array(text.lowercased())
        var pi = 0, ti = 0, star = -1, mark = 0
        while ti < t.count {
            if pi < p.count && (p[pi] == "?" || p[pi] == t[ti]) {
                pi += 1; ti += 1
            } else if pi < p.count && p[pi] == "*" {
                star = pi; mark = ti; pi += 1
            } else if star >= 0 {
                pi = star + 1; mark += 1; ti = mark
            } else {
                return false
            }
        }
        while pi < p.count && p[pi] == "*" { pi += 1 }
        return pi == p.count
    }

    /// `~`, `%d` (home), `%h` (the host as written), `%u` and `%r` (the user), `%%`.
    static func expand(_ s: String, home: URL, host: String, user: String) -> String {
        var out = s.hasPrefix("~/") ? home.path + s.dropFirst() : s
        for (token, value) in [("%d", home.path), ("%h", host), ("%u", user), ("%r", user), ("%%", "%")] {
            out = out.replacingOccurrences(of: token, with: value)
        }
        return out
    }
}
