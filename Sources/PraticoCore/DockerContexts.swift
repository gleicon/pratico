import Foundation

/// The docker CLI's contexts, which are pratico's list of hosts (docs/design/remote.md): the
/// menubar shows them and makes one current as `docker context use` does, by writing
/// `currentContext` in the CLI's `config.json`. Contexts are added and removed with
/// `docker context create` and `rm`; pratico keeps no list of its own.
public struct DockerContexts: Sendable {
    public struct Context: Sendable, Equatable, Identifiable {
        public let name: String
        /// `unix:///…`, `ssh://user@host`, `tcp://…`; nil when it has no docker endpoint.
        public let host: String?
        public var id: String { name }

        /// The host part of an `ssh://` endpoint: what the menubar names it by.
        public var sshTarget: String? {
            guard let host, let url = URL(string: host), url.scheme == "ssh" else { return nil }
            return host.dropFirst("ssh://".count).description
        }
    }

    /// The CLI's own: always there, never stored, `DOCKER_HOST` or the default socket.
    public static let defaultName = "default"

    /// `DOCKER_CONFIG`, else `~/.docker`, as the CLI resolves it.
    public let directory: URL

    public init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else if let env = ProcessInfo.processInfo.environment["DOCKER_CONFIG"], !env.isEmpty {
            self.directory = URL(filePath: env, directoryHint: .isDirectory)
        } else {
            self.directory = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".docker", directoryHint: .isDirectory)
        }
    }

    var configFile: URL { directory.appending(path: "config.json") }

    /// `default` first, then the stored contexts by name.
    public func list() -> [Context] {
        let meta = directory.appending(path: "contexts/meta", directoryHint: .isDirectory)
        let dirs = (try? FileManager.default.contentsOfDirectory(at: meta, includingPropertiesForKeys: nil)) ?? []
        let stored = dirs.compactMap { dir -> Context? in
            guard let data = try? Data(contentsOf: dir.appending(path: "meta.json")),
                  let m = try? JSONDecoder().decode(Meta.self, from: data), m.Name != Self.defaultName
            else { return nil }
            return Context(name: m.Name, host: m.Endpoints?["docker"]?.Host)
        }
        return [Context(name: Self.defaultName, host: nil)] + stored.sorted { $0.name < $1.name }
    }

    /// `currentContext`, or `default` when unset.
    public func current() -> String {
        (try? object())?["currentContext"] as? String ?? Self.defaultName
    }

    /// Makes `name` current, as `docker context use`: `default` removes the key. Every other
    /// key of `config.json` (registry logins among them) is kept; the file stays 0600.
    public func use(_ name: String) throws {
        guard name == Self.defaultName || list().contains(where: { $0.name == name }) else {
            throw ContextError(description: "no docker context named \(name)")
        }
        var json = try object() ?? [:]
        if name == Self.defaultName { json.removeValue(forKey: "currentContext") } else { json["currentContext"] = name }
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: configFile, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configFile.path)
    }

    /// The file as JSON; nil when there is none. A file that is not a JSON object is an
    /// error, never overwritten.
    private func object() throws -> [String: Any]? {
        guard let data = try? Data(contentsOf: configFile) else { return nil }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ContextError(description: "\(configFile.path) is not a JSON object")
        }
        return json
    }

    public struct ContextError: Error, CustomStringConvertible {
        public let description: String
    }

    private struct Meta: Decodable {
        let Name: String
        let Endpoints: [String: Endpoint]?
        struct Endpoint: Decodable { let Host: String? }
    }
}
