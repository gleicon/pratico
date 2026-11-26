import Foundation

/// The SSH key the menubar signs with for a Linux host, when the user chose one there:
/// `~/.pratico/hosts.json`, `{"identities": {"<docker context>": "/path/to/key"}}`. Only the
/// path is kept, never the key; with no choice, `~/.ssh/config` and ssh's default keys decide,
/// as for `ssh` itself.
public struct HostKeys: Sendable {
    public let file: URL

    public init(home: URL = Pratico.home()) {
        file = home.appending(path: "hosts.json")
    }

    public func identity(for context: String) -> String? {
        read()[context]
    }

    /// Sets (or, with nil, forgets) the key for `context`. The file is 0600 from creation.
    public func setIdentity(_ path: String?, for context: String) throws {
        var all = read()
        all[context] = path
        let data = try JSONSerialization.data(withJSONObject: ["identities": all], options: [.prettyPrinted, .sortedKeys])
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try DockerContexts.replace(file.resolvingSymlinksInPath(), with: data)
    }

    private func read() -> [String: String] {
        guard let data = try? Data(contentsOf: file),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return json["identities"] as? [String: String] ?? [:]
    }
}
