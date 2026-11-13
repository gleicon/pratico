import Foundation

/// `~/.pratico/config.toml`: built-in defaults, with the file holding overrides only
/// (SPEC FR-37, FR-38, D-14). Parsed by hand: the file is flat `key = value` lines, a
/// subset of TOML too small to justify a dependency.
public struct Config: Equatable, Sendable {
    public enum Value: Equatable, Sendable, CustomStringConvertible {
        case bool(Bool)
        case int(Int)
        case string(String)
        case strings([String])

        public var description: String {
            switch self {
            case .bool(let v): "\(v)"
            case .int(let v): "\(v)"
            case .string(let v): Self.quote(v)
            case .strings(let v): "[" + v.map(Self.quote).joined(separator: ", ") + "]"
            }
        }

        private static func quote(_ v: String) -> String {
            "\"\(v.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
        }
    }

    public struct Key: Sendable {
        public var name: String
        public var defaultValue: Value
        public var summary: String
        /// Range check for integers.
        public var range: ClosedRange<Int>?
        /// Allowed values for strings.
        public var choices: [String]?
    }

    public static let keys: [Key] = [
        Key(name: "start_at_login", defaultValue: .bool(true), summary: "Start the daemon at login"),
        Key(name: "default_cpus", defaultValue: .int(4), summary: "CPUs per container when Docker sets no limit", range: 1...64),
        Key(name: "default_memory", defaultValue: .int(1024), summary: "Memory per container in MiB when Docker sets no limit", range: 64...1_048_576),
        Key(name: "scan", defaultValue: .bool(true), summary: "Scan pulled images for vulnerabilities and malware"),
        Key(name: "scan_block", defaultValue: .string("kev"),
            summary: "Findings that stop and block an image's containers: off, malware, kev (malware + exploited CVEs), critical (kev + CVSS >= 9)",
            choices: ["off", "malware", "kev", "critical"]),
        Key(name: "scan_allow", defaultValue: .strings([]), summary: "Image IDs allowed to run despite findings"),
        Key(name: "scan_custom", defaultValue: .strings([]),
            summary: "Your own scanners: executables run as <path> <image.tar> that print pratico's findings JSON"),
        Key(name: "registry_http", defaultValue: .strings([]),
            summary: "Registries (host, host:port, or IPv4 CIDR) reached over plain HTTP, credentials included, like Docker's insecure-registries"),
        Key(name: "registry_http_loopback", defaultValue: .bool(true),
            summary: "Allow plain HTTP, credentials included, to registries on localhost and 127.0.0.0/8, as Docker does"),
        Key(name: "registry_ca", defaultValue: .strings([]),
            summary: "PEM files of extra CA certificates trusted for registries, added to the system's trusted roots"),
        Key(name: "registry_system_roots", defaultValue: .bool(true),
            summary: "Trust the system's roots for registries; false trusts only registry_ca"),
        Key(name: "registry_keep_logins", defaultValue: .bool(true),
            summary: "Keep docker login credentials in pratico's Keychain items, for clients that send none; false only checks them, as dockerd does"),
    ]

    /// Values set in the file, by key.
    public private(set) var overrides: [String: Value] = [:]

    public init(overrides: [String: Value] = [:]) { self.overrides = overrides }

    public func value(_ name: String) -> Value? {
        overrides[name] ?? Self.keys.first { $0.name == name }?.defaultValue
    }

    public var startAtLogin: Bool { if case .bool(let v) = value("start_at_login") { v } else { true } }
    public var defaultCPUs: Int { if case .int(let v) = value("default_cpus") { v } else { 4 } }
    public var defaultMemoryMiB: Int { if case .int(let v) = value("default_memory") { v } else { 1024 } }
    public var scan: Bool { if case .bool(let v) = value("scan") { v } else { true } }
    public var scanBlock: String { if case .string(let v) = value("scan_block") { v } else { "kev" } }
    public var scanAllow: [String] { if case .strings(let v) = value("scan_allow") { v } else { [] } }
    public var scanCustom: [String] { if case .strings(let v) = value("scan_custom") { v } else { [] } }
    public var registryHTTP: [String] { if case .strings(let v) = value("registry_http") { v } else { [] } }
    public var registryHTTPLoopback: Bool { if case .bool(let v) = value("registry_http_loopback") { v } else { true } }
    public var registryCA: [String] { if case .strings(let v) = value("registry_ca") { v } else { [] } }
    public var registrySystemRoots: Bool { if case .bool(let v) = value("registry_system_roots") { v } else { true } }
    public var registryKeepLogins: Bool { if case .bool(let v) = value("registry_keep_logins") { v } else { true } }

    // MARK: Loading

    public struct ParseError: Error, Equatable, CustomStringConvertible {
        public var line: Int
        public var key: String?
        public var message: String

        public var description: String {
            "config.toml line \(line): \(key.map { "`\($0)`: " } ?? "")\(message)"
        }
    }

    public static func path(home: URL = Pratico.home()) -> URL { home.appending(path: "config.toml") }

    /// Loads the file; a missing file yields the defaults (FR-37).
    public static func load(home: URL = Pratico.home()) throws -> Config {
        let url = path(home: home)
        guard FileManager.default.fileExists(atPath: url.path) else { return Config() }
        let text = try String(contentsOf: url, encoding: .utf8)
        return try parse(text)
    }

    /// `text` with only `name`'s line changed: replaced, appended, or removed for `nil` (back
    /// to the default). Comments and every other line stay as they are (FR-34).
    public static func setting(_ name: String, to value: Value?, in text: String) throws -> String {
        var lines = text.isEmpty ? [] : text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        let index = lines.firstIndex {
            let line = stripComment($0)
            guard let eq = line.firstIndex(of: "=") else { return false }
            return line[..<eq].trimmingCharacters(in: .whitespaces) == name
        }
        let line = value.map { "\(name) = \($0)" }
        switch (index, line) {
        case (let i?, let line?): lines[i] = line
        case (let i?, nil): lines.remove(at: i)
        case (nil, let line?): lines.append(line)
        case (nil, nil): break
        }
        let out = lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
        _ = try parse(out)
        return out
    }

    public static func parse(_ text: String) throws -> Config {
        var overrides: [String: Value] = [:]
        for (index, raw) in text.components(separatedBy: .newlines).enumerated() {
            let lineNo = index + 1
            let line = stripComment(raw).trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("[") {
                throw ParseError(line: lineNo, key: nil, message: "tables are not supported; use top-level keys")
            }
            guard let eq = line.firstIndex(of: "=") else {
                throw ParseError(line: lineNo, key: nil, message: "expected `key = value`")
            }
            let name = line[..<eq].trimmingCharacters(in: .whitespaces)
            let rawValue = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            guard let key = keys.first(where: { $0.name == name }) else {
                throw ParseError(line: lineNo, key: name, message: "unknown key")
            }
            guard overrides[name] == nil else {
                throw ParseError(line: lineNo, key: name, message: "duplicate key")
            }
            overrides[name] = try parseValue(rawValue, for: key, line: lineNo)
        }
        return Config(overrides: overrides)
    }

    private static func parseValue(_ raw: String, for key: Key, line: Int) throws -> Value {
        func invalid(_ expected: String) -> ParseError {
            ParseError(line: line, key: key.name, message: "invalid value `\(raw)`, expected \(expected)")
        }
        switch key.defaultValue {
        case .bool:
            switch raw {
            case "true": return .bool(true)
            case "false": return .bool(false)
            default: throw invalid("true or false")
            }
        case .int:
            let digits = raw.replacingOccurrences(of: "_", with: "")
            guard let v = Int(digits) else { throw invalid("an integer") }
            if let range = key.range, !range.contains(v) {
                throw invalid("an integer in \(range.lowerBound)...\(range.upperBound)")
            }
            return .int(v)
        case .string:
            let v = try parseString(raw, invalid)
            if let choices = key.choices, !choices.contains(v) {
                throw invalid("one of " + choices.joined(separator: ", "))
            }
            return .string(v)
        case .strings:
            // Single-line array of quoted strings: ["a", "b"].
            guard raw.hasPrefix("["), raw.hasSuffix("]") else { throw invalid("an array of quoted strings") }
            let body = raw.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
            if body.isEmpty { return .strings([]) }
            var items: [String] = []
            var current = ""
            var inString = false
            var escaped = false
            for c in body {
                if escaped { escaped = false; current.append(c); continue }
                if c == "\\" && inString { escaped = true; current.append(c); continue }
                if c == "\"" { inString.toggle() }
                if c == "," && !inString {
                    items.append(try parseString(current.trimmingCharacters(in: .whitespaces), invalid))
                    current = ""
                } else {
                    current.append(c)
                }
            }
            let last = current.trimmingCharacters(in: .whitespaces)
            if !last.isEmpty { items.append(try parseString(last, invalid)) }
            return .strings(items)
        }
    }

    private static func parseString(_ raw: String, _ invalid: (String) -> ParseError) throws -> String {
        guard raw.count >= 2, raw.hasPrefix("\""), raw.hasSuffix("\"") else { throw invalid("a quoted string") }
        var out = ""
        var escaped = false
        for c in raw.dropFirst().dropLast() {
            if escaped {
                switch c {
                case "n": out.append("\n")
                case "t": out.append("\t")
                case "\"", "\\": out.append(c)
                default: throw invalid("a string with valid escapes")
                }
                escaped = false
            } else if c == "\\" {
                escaped = true
            } else {
                out.append(c)
            }
        }
        return out
    }

    /// Drops a `#` comment, ignoring `#` inside a quoted string.
    private static func stripComment(_ line: String) -> String {
        var inString = false
        var escaped = false
        for (i, c) in zip(line.indices, line) {
            if escaped { escaped = false; continue }
            if c == "\\" && inString { escaped = true }
            else if c == "\"" { inString.toggle() }
            else if c == "#" && !inString { return String(line[..<i]) }
        }
        return line
    }
}
