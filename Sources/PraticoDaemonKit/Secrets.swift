import ContainerizationOCI
import ContainerizationOS
import Foundation
import PraticoCore

/// Where pratico keeps a secret it must send again later (registry logins, the abuse.ch
/// key), one item per host in `domain`. On the Mac, pratico's own Keychain items; a daemon
/// on another `--home` (the e2e suites) keeps its own, in a domain naming that home, and
/// never reads the user's: a rebuilt binary reading them waits on a Keychain prompt. On Linux
/// hosts (docs/design/remote.md), which have no Keychain a daemon can rely on, a file only
/// the daemon's user can read: `<home>/secrets/<domain>.json`, mode 0600 in a 0700
/// directory, replaced atomically.
struct SecretStore: Sendable {
    struct Item: Codable, Sendable {
        var hostname: String
        var username: String
        var password: String
        var modified: Date
    }

    let domain: String
    #if !canImport(Security)
    let file: URL
    private static let lock = NSLock()
    #endif

    init(domain: String, home: URL) {
        #if canImport(Security)
        let own = home.standardizedFileURL.path == Pratico.home().standardizedFileURL.path
        self.domain = own ? domain : "\(domain) \(home.standardizedFileURL.path)"
        #else
        self.domain = domain
        #endif
        #if !canImport(Security)
        file = home.appending(path: "secrets/\(domain).json")
        #endif
    }

    func get(_ hostname: String) -> Item? {
        #if canImport(Security)
        guard let r = try? KeychainQuery().get(securityDomain: domain, hostname: hostname) else { return nil }
        return Item(hostname: hostname, username: r.username, password: r.password, modified: r.modifiedDate)
        #else
        return Self.lock.withLock { load()[hostname] }
        #endif
    }

    /// What is kept, without the secrets.
    func list() -> [(hostname: String, username: String, modified: Date)] {
        #if canImport(Security)
        ((try? KeychainQuery().list(securityDomain: domain)) ?? []).map { ($0.hostname, $0.username, $0.modifiedDate) }
        #else
        Self.lock.withLock { load().values.map { ($0.hostname, $0.username, $0.modified) } }
        #endif
    }

    func save(_ hostname: String, username: String, password: String) throws {
        #if canImport(Security)
        try KeychainHelper(securityDomain: domain).save(hostname: hostname, username: username, password: password)
        #else
        try Self.lock.withLock {
            var all = load()
            all[hostname] = Item(hostname: hostname, username: username, password: password, modified: Date())
            try store(all)
        }
        #endif
    }

    func delete(_ hostname: String) throws {
        #if canImport(Security)
        try KeychainHelper(securityDomain: domain).delete(hostname: hostname)
        #else
        try Self.lock.withLock {
            var all = load()
            guard all.removeValue(forKey: hostname) != nil else { return }
            try store(all)
        }
        #endif
    }

    #if !canImport(Security)
    private func load() -> [String: Item] {
        guard let data = try? Data(contentsOf: file) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([String: Item].self, from: data)) ?? [:]
    }

    private func store(_ all: [String: Item]) throws {
        let dir = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        chmod(dir.path, 0o700)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(all)
        // Written at 0600 before it holds anything, then moved over the old file.
        let partial = dir.appending(path: ".\(domain).json.partial")
        try? FileManager.default.removeItem(at: partial)
        guard FileManager.default.createFile(atPath: partial.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw APIError(500, "pratico: cannot write \(partial.path)")
        }
        let handle = try FileHandle(forWritingTo: partial)
        try handle.write(contentsOf: data)
        try handle.synchronize()
        try handle.close()
        guard rename(partial.path, file.path) == 0 else { throw APIError(500, "pratico: cannot replace \(file.path)") }
    }
    #endif
}
