import Foundation

/// Registry credentials (SPEC FR-9, NFR-10, D-21). Apple `container` reads credentials
/// only from its own Keychain entries, written by `container registry login`; it takes
/// none per pull. So `docker login` and the `X-Registry-Auth` header become a Keychain
/// login, with the password passed on stdin. pratico never writes credentials to disk.
struct RegistryAuth: Equatable {
    var username: String
    var password: String
    var server: String

    /// Docker's `X-Registry-Auth`: base64url JSON. `{}` and token-only forms yield nil.
    static func header(_ value: String?) -> RegistryAuth? {
        guard let value, !value.isEmpty else { return nil }
        var b64 = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        b64 += String(repeating: "=", count: (4 - b64.count % 4) % 4)
        guard let data = Data(base64Encoded: b64), let json = JSON.parse(data) else { return nil }
        return body(json)
    }

    /// `POST /auth` body, or a decoded header.
    static func body(_ json: JSON) -> RegistryAuth? {
        guard let user = json["username"]?.string, !user.isEmpty,
            let pass = json["password"]?.string, !pass.isEmpty
        else { return nil }
        return RegistryAuth(username: user, password: pass, server: host(json["serveraddress"]?.string ?? ""))
    }

    /// Docker sends `https://index.docker.io/v1/` for Docker Hub and a bare host otherwise.
    static func host(_ server: String) -> String {
        var s = server
        for scheme in ["https://", "http://"] where s.hasPrefix(scheme) { s = String(s.dropFirst(scheme.count)) }
        s = String(s.split(separator: "/").first ?? "")
        return s.isEmpty || s == "index.docker.io" || s == "registry-1.docker.io" ? "docker.io" : s
    }

    /// Registry host of a normalized image reference.
    static func host(ofImage ref: String) -> String {
        String(ImageRef.normalize(ref).split(separator: "/").first ?? "docker.io")
    }
}
