import Crypto
import Foundation
import NIOSSH

/// Host key checking against `known_hosts`, as `ssh` does with `StrictHostKeyChecking yes`:
/// pratico's SSH never trusts a key on first use and never adds one. A host it has not seen
/// is trusted by connecting once with `ssh`, which asks.
public enum KnownHosts {
    public enum Verdict: Equatable {
        case trusted
        /// No line names the host: connect once with `ssh`.
        case unknown
        /// Lines name the host with other keys: the key changed, or someone is in between.
        case changed
        case revoked
    }

    /// `host` as `known_hosts` writes it: bare on port 22, else `[host]:port`.
    static func entryName(_ host: String, port: Int) -> String {
        port == 22 ? host.lowercased() : "[\(host.lowercased())]:\(port)"
    }

    public static func verify(_ key: NIOSSHPublicKey, host: String, port: Int, files: [String]) -> Verdict {
        let name = entryName(host, port: port)
        var named = false
        var matched = false
        for file in files {
            guard let text = try? String(contentsOfFile: file, encoding: .utf8) else { continue }
            for raw in text.split(whereSeparator: \.isNewline) {
                var fields = raw.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
                guard let first = fields.first, !first.hasPrefix("#") else { continue }
                var marker: String?
                if first.hasPrefix("@") {
                    marker = first
                    fields.removeFirst()
                }
                guard fields.count >= 3, names(fields[0], include: name) else { continue }
                // A CA line vouches for certificates, which pratico's SSH does not check.
                if marker == "@cert-authority" { continue }
                let lineKey = try? NIOSSHPublicKey(openSSHPublicKey: "\(fields[1]) \(fields[2])")
                if marker == "@revoked" {
                    if lineKey == key { return .revoked }
                    continue
                }
                named = true
                if lineKey == key { matched = true }
            }
        }
        if matched { return .trusted }
        return named ? .changed : .unknown
    }

    /// A line's comma-separated hosts: plain, `*`/`?` patterns, `!` negations, or hashed
    /// (`|1|salt|HMAC-SHA1(salt, name)`, as `HashKnownHosts` writes them).
    static func names(_ field: String, include name: String) -> Bool {
        var hit = false
        for entry in field.split(separator: ",").map(String.init) {
            if entry.hasPrefix("|1|") {
                let parts = entry.split(separator: "|")
                guard parts.count == 3, let salt = Data(base64Encoded: String(parts[1])),
                      let hash = Data(base64Encoded: String(parts[2])) else { continue }
                let mac = HMAC<Insecure.SHA1>.authenticationCode(for: Data(name.utf8), using: SymmetricKey(data: salt))
                if Data(mac) == hash { hit = true }
            } else if entry.hasPrefix("!") {
                if SSHConfigParser.glob(String(entry.dropFirst()), name) { return false }
            } else if SSHConfigParser.glob(entry, name) {
                hit = true
            }
        }
        return hit
    }
}
