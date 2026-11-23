import Crypto
import Foundation
import NIOSSH

/// A private key file as `ssh-keygen` writes it (`openssh-key-v1`), ed25519 or ECDSA, read
/// for pratico's own SSH. swift-nio-ssh reads no key files (apple/swift-nio-ssh#94) and signs
/// with no agent (#189, #230): until it does, a key with a passphrase, or one that lives only
/// in an agent, is refused with that reason. PKCS#8 and SEC1 ECDSA files are read too.
public enum OpenSSHKey {
    public struct Unreadable: Error, CustomStringConvertible {
        public let description: String
    }

    public static func load(_ path: String) throws -> NIOSSHPrivateKey {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            throw Unreadable(description: "cannot read \(path)")
        }
        return try parse(text, name: path)
    }

    public static func parse(_ text: String, name: String) throws -> NIOSSHPrivateKey {
        if text.contains("-----BEGIN OPENSSH PRIVATE KEY-----") { return try parseOpenSSH(text, name: name) }
        if text.contains("ENCRYPTED") { throw Unreadable(description: "\(name) has a passphrase, which pratico cannot use until swift-nio-ssh supports ssh-agent") }
        if let k = try? P256.Signing.PrivateKey(pemRepresentation: text) { return NIOSSHPrivateKey(p256Key: k) }
        if let k = try? P384.Signing.PrivateKey(pemRepresentation: text) { return NIOSSHPrivateKey(p384Key: k) }
        if let k = try? P521.Signing.PrivateKey(pemRepresentation: text) { return NIOSSHPrivateKey(p521Key: k) }
        if text.contains("RSA PRIVATE KEY") { throw Unreadable(description: "\(name) is an RSA key; pratico's SSH uses ed25519 and ECDSA keys") }
        throw Unreadable(description: "\(name) is not a private key pratico can read")
    }

    static func parseOpenSSH(_ text: String, name: String) throws -> NIOSSHPrivateKey {
        let body = text.split(whereSeparator: \.isNewline).filter { !$0.hasPrefix("-----") }.joined()
        guard let data = Data(base64Encoded: body) else { throw Unreadable(description: "\(name) is not valid base64") }
        var r = SSHReader(data)
        guard r.take(15) == Data("openssh-key-v1\0".utf8) else { throw Unreadable(description: "\(name) is not an openssh-key-v1 file") }
        let cipher = try r.string()
        _ = try r.string()  // kdf name
        _ = try r.string()  // kdf options
        guard cipher == Data("none".utf8) else {
            throw Unreadable(description: "\(name) has a passphrase, which pratico cannot use until swift-nio-ssh supports ssh-agent")
        }
        guard try r.uint32() == 1 else { throw Unreadable(description: "\(name) holds more than one key") }
        _ = try r.string()  // public key
        var p = SSHReader(try r.string())
        guard try p.uint32() == (try p.uint32()) else { throw Unreadable(description: "\(name) is corrupt (check bytes differ)") }
        let type = String(decoding: try p.string(), as: UTF8.self)
        switch type {
        case "ssh-ed25519":
            _ = try p.string()  // public
            let secret = try p.string()
            guard secret.count == 64 else { throw Unreadable(description: "\(name): bad ed25519 key length") }
            return NIOSSHPrivateKey(ed25519Key: try Curve25519.Signing.PrivateKey(rawRepresentation: secret.prefix(32)))
        case "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521":
            _ = try p.string()  // curve
            _ = try p.string()  // public point
            let size = ["ecdsa-sha2-nistp256": 32, "ecdsa-sha2-nistp384": 48, "ecdsa-sha2-nistp521": 66][type]!
            let scalar = try fixed(try p.string(), size: size, name: name)
            switch size {
            case 32: return NIOSSHPrivateKey(p256Key: try P256.Signing.PrivateKey(rawRepresentation: scalar))
            case 48: return NIOSSHPrivateKey(p384Key: try P384.Signing.PrivateKey(rawRepresentation: scalar))
            default: return NIOSSHPrivateKey(p521Key: try P521.Signing.PrivateKey(rawRepresentation: scalar))
            }
        case "ssh-rsa":
            throw Unreadable(description: "\(name) is an RSA key; pratico's SSH uses ed25519 and ECDSA keys")
        default:
            throw Unreadable(description: "\(name) is a \(type) key; pratico's SSH uses ed25519 and ECDSA keys")
        }
    }

    /// An mpint as the curve's fixed-size scalar: its sign byte dropped, left-padded.
    static func fixed(_ mpint: Data, size: Int, name: String) throws -> Data {
        let trimmed = mpint.drop { $0 == 0 }
        guard trimmed.count <= size else { throw Unreadable(description: "\(name): bad ECDSA key length") }
        return Data(repeating: 0, count: size - trimmed.count) + trimmed
    }
}

/// SSH's wire encoding: big-endian uint32s and length-prefixed strings, bounds-checked.
struct SSHReader {
    private var data: Data
    init(_ data: Data) { self.data = Data(data) }

    mutating func take(_ n: Int) -> Data? {
        guard n >= 0, data.count >= n else { return nil }
        defer { data = Data(data.dropFirst(n)) }
        return Data(data.prefix(n))
    }

    mutating func uint32() throws -> UInt32 {
        guard let b = take(4) else { throw OpenSSHKey.Unreadable(description: "truncated key") }
        return b.reduce(0) { $0 << 8 | UInt32($1) }
    }

    mutating func string() throws -> Data {
        let n = Int(try uint32())
        guard let s = take(n) else { throw OpenSSHKey.Unreadable(description: "truncated key") }
        return s
    }
}
