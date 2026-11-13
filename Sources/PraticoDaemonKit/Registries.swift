import ContainerizationOCI
import ContainerizationOS
import Foundation
import PraticoCore

/// What the embedded runtime trusts and keeps for registries (SPEC D-29): the policy from
/// `config.toml` and the logins `docker login` kept in pratico's Keychain items. It
/// mirrors both, never a password, to `~/.pratico/registries.json` for the menubar, and
/// serves the same view at `GET /pratico/registries`.
final class Registries: Sendable {
    let policy: RegistryPolicy
    let stateFile: URL

    /// pratico's own Keychain items (not Docker's, not Apple `container`'s), one per registry.
    static let keychainDomain = "dev.pratico.registry"
    private static let keychain = KeychainHelper(securityDomain: keychainDomain)

    init(policy: RegistryPolicy, home: URL) {
        self.policy = policy
        stateFile = Pratico.registriesPath(home: home)
    }

    /// Checks the credentials with the registry, then keeps them unless
    /// `registry_keep_logins = false`.
    func login(_ auth: RegistryAuth) throws {
        let client = try RegistrySession(host: auth.server, credentials: (auth.username, auth.password), policy: policy)
        do {
            try blocking { try await client.ping() }
        } catch let e as RegistryError where e.unauthorized {
            throw APIError(401, e.description)
        } catch {
            throw APIError(500, "login to \(auth.server) failed: \(error)")
        }
        guard policy.keepLogins else { return }
        do { try Self.keychain.save(hostname: auth.server, username: auth.username, password: auth.password) } catch {
            throw APIError(500, "pratico: cannot keep the login in the Keychain: \(error)")
        }
        writeState()
    }

    /// The `docker logout` the Docker CLI never sends to a daemon.
    func logout(_ server: String) throws {
        let host = RegistryAuth.host(server)
        guard logins().contains(where: { $0["server"]?.string == host }) else { throw APIError(404, "pratico keeps no login for \(host)") }
        do { try Self.keychain.delete(hostname: host) } catch { throw APIError(500, "cannot remove the login for \(host): \(error)") }
        writeState()
    }

    /// Kept logins, without passwords.
    func logins() -> [JSON] {
        ((try? Self.keychain.list()) ?? []).sorted { $0.hostname < $1.hostname }.map {
            ["server": .string($0.hostname), "username": .string($0.username), "saved": .string(ISO8601DateFormatter().string(from: $0.modifiedDate))]
        }
    }

    /// The request's credentials for `host`'s own registry, else the ones `docker login`
    /// kept (clients other than the Docker CLI rarely send any). With
    /// `registry_keep_logins = false` the Keychain is never read, as with dockerd.
    func credentials(_ auth: RegistryAuth?, for host: String) -> (username: String, password: String)? {
        if let auth, auth.server == host { return (auth.username, auth.password) }
        guard policy.keepLogins else { return nil }
        guard let kept = try? KeychainQuery().get(securityDomain: Self.keychainDomain, hostname: host) else { return nil }
        return (kept.username, kept.password)
    }

    var warnings: JSON { .array(policy.warnings.map { .string($0) }) }

    /// `registries.json` and `GET /pratico/registries`.
    var state: JSON { ["policy": policy.summary, "warnings": warnings, "logins": .array(logins())] }

    func writeState() {
        try? state.encoded().write(to: stateFile, options: .atomic)
    }
}
