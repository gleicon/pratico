import ContainerizationError
import ContainerizationExtras
import ContainerizationOCI
import Crypto
import Foundation
import NIOCore
import NIOHTTP1
import PraticoCore

#if canImport(Security)
import Security
#else
import NIOSSL
import X509
#endif

/// How pratico reaches registries (SPEC D-29), from `config.toml`:
/// `registry_http`, `registry_http_loopback`, `registry_ca`, `registry_system_roots`.
/// Every way it departs from "HTTPS verified by the system's roots" is reported where the
/// user sees it (`docker info`, pull and push output, the daemon log, `registries.json`),
/// so a trust decision pratico made on the user's behalf is never mistaken for a MITM.
struct RegistryPolicy: @unchecked Sendable {
    struct CA: Sendable {
        var file: String
        var subject: String
        var sha256: String  // hex, of the DER certificate
    }

    /// `registry_http`: host or host:port, as in image references.
    var httpHosts: [String] = []
    var httpLoopback = true
    var systemRoots = true
    /// `registry_keep_logins`: keep `docker login` credentials, or only check them.
    var keepLogins = true
    var cas: [CA] = []
    /// The CA certificates themselves, in `cas` order.
    #if canImport(Security)
    var anchors: [SecCertificate] = []
    #else
    var anchors: [NIOSSLCertificate] = []
    #endif

    /// Loads and checks the CA files; an unreadable or empty one is a configuration error,
    /// so the daemon refuses to start rather than silently trusting less (or more).
    static func load(_ config: Config, environment: [String: String] = ProcessInfo.processInfo.environment) throws -> RegistryPolicy {
        var p = RegistryPolicy()
        p.httpHosts = config.registryHTTP.map { $0.lowercased() }
        p.httpLoopback = config.registryHTTPLoopback
        p.systemRoots = config.registrySystemRoots
        p.keepLogins = config.registryKeepLogins
        // SSL_CERT_FILE adds to the roots here, unlike Containerization's client, where it
        // replaced them (and Docker Hub stopped verifying).
        var files = config.registryCA
        if let env = environment["SSL_CERT_FILE"], !env.isEmpty { files.append(env) }
        for file in files {
            let path = (file as NSString).expandingTildeInPath
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
                throw ConfigError("registry_ca: cannot read \(file)")
            }
            let ders = pemCertificates(text)
            guard !ders.isEmpty else { throw ConfigError("registry_ca: no PEM certificate in \(file)") }
            for der in ders {
                #if canImport(Security)
                guard let cert = SecCertificateCreateWithData(nil, der as CFData) else {
                    throw ConfigError("registry_ca: \(file) holds a certificate macOS cannot read")
                }
                let subject = (SecCertificateCopySubjectSummary(cert) as String?) ?? "unnamed"
                #else
                guard let cert = try? NIOSSLCertificate(bytes: [UInt8](der), format: .der),
                    let parsed = try? Certificate(derEncoded: [UInt8](der))
                else { throw ConfigError("registry_ca: \(file) holds a certificate pratico cannot read") }
                let subject = parsed.subject.flatMap { $0 }.first { $0.type == .RDNAttributeType.commonName }
                    .map { "\($0.value)" } ?? "unnamed"
                #endif
                let digest = SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
                p.cas.append(CA(file: file, subject: subject, sha256: digest))
                p.anchors.append(cert)
            }
        }
        if !p.systemRoots && p.anchors.isEmpty {
            throw ConfigError("registry_system_roots = false needs at least one registry_ca, or no registry can be verified")
        }
        return p
    }

    struct ConfigError: Error, CustomStringConvertible {
        var description: String
        init(_ d: String) { description = d }
    }

    static func pemCertificates(_ text: String) -> [Data] {
        var out: [Data] = []
        var current: String?
        for line in text.split(whereSeparator: \.isNewline).map({ $0.trimmingCharacters(in: .whitespaces) }) {
            if line == "-----BEGIN CERTIFICATE-----" {
                current = ""
            } else if line == "-----END CERTIFICATE-----" {
                if let b64 = current, let der = Data(base64Encoded: b64) { out.append(der) }
                current = nil
            } else if current != nil {
                current! += line
            }
        }
        return out
    }

    /// Only `localhost` and IP literals in 127.0.0.0/8 or ::1: a DNS name such as
    /// `127.example.com` is not loopback, whatever it starts with.
    static func isLoopback(_ host: String) -> Bool {
        let name = hostName(host)
        if name == "localhost" || name == "[::1]" { return true }
        return IPv4.parse(name).map { $0 >> 24 == 127 } ?? false
    }

    static func hostName(_ host: String) -> String {
        if host.hasPrefix("[") { return String(host.prefix { $0 != "]" }) + "]" }
        return String(host.split(separator: ":").first ?? Substring(host)).lowercased()
    }

    /// A `registry_http` entry is a host, a host:port, or an IPv4 CIDR (as Docker's
    /// insecure-registries), which matches registries named by an address in it.
    private static func matches(_ entry: String, _ host: String) -> Bool {
        guard entry.contains("/") else { return entry == host || entry == hostName(host) }
        return IPv4.cidr(entry).map { IPv4.contains($0, hostName(host)) } ?? false
    }

    /// Why plain HTTP may be used for `host`, or nil when it may not.
    func plainHTTPReason(_ host: String) -> String? {
        let h = host.lowercased()
        if httpHosts.contains(where: { Self.matches($0, h) }) { return "registry_http in config.toml" }
        if httpLoopback && Self.isLoopback(h) { return "registry_http_loopback, a loopback registry" }
        return nil
    }

    /// `docker info`'s `RegistryConfig`, in Docker's shape: the CLI lists the insecure ones.
    var registryConfig: JSON {
        var cidrs: [JSON] = httpLoopback ? ["127.0.0.0/8"] : []
        var indexes: [String: JSON] = ["docker.io": ["Name": "docker.io", "Mirrors": [], "Secure": true, "Official": true]]
        for h in httpHosts {
            if h.contains("/"), let c = IPv4.cidr(h) { cidrs.append(.string("\(IPv4.format(c.base))/\(c.prefix)")) } else {
                indexes[h] = ["Name": .string(h), "Mirrors": [], "Secure": false, "Official": false]
            }
        }
        return ["AllowNondistributableArtifactsCIDRs": [], "AllowNondistributableArtifactsHostnames": [],
                "InsecureRegistryCIDRs": .array(cidrs), "IndexConfigs": .object(indexes), "Mirrors": []]
    }

    /// `docker info` warnings: the CLI prints each as `WARNING: …`.
    var warnings: [String] {
        var out: [String] = []
        for h in httpHosts {
            out.append("pratico: registry \(h) may be reached over plain HTTP, credentials included (registry_http in config.toml)")
        }
        for ca in cas {
            out.append("pratico: registries may be verified by an extra CA, \"\(ca.subject)\" SHA-256 \(ca.sha256.prefix(16))… from \(ca.file) (registry_ca)")
        }
        if !systemRoots { out.append("pratico: registries are verified only by registry_ca, not by the system's roots (registry_system_roots = false)") }
        return out
    }

    /// The part of `registries.json` the menubar shows.
    var summary: JSON {
        ["httpLoopback": .bool(httpLoopback), "http": .array(httpHosts.map { .string($0) }), "systemRoots": .bool(systemRoots),
         "keepLogins": .bool(keepLogins),
         "ca": .array(cas.map { ["file": .string($0.file), "subject": .string($0.subject), "sha256": .string($0.sha256)] })]
    }
}

/// Errors in Docker-like wording; `ImageService` prefixes them.
struct RegistryError: Error, CustomStringConvertible {
    var status: Int
    var description: String
    var unauthorized: Bool { status == 401 || status == 403 }
}

/// pratico's registry client (OCI distribution), over `RegistryTransport` (URLSession on
/// the Mac, with the system's proxy, PAC settings, and roots), plus the policy above. It is the `ContentClient` Containerization's import and export use.
///
/// It keeps Containerization's guards: digests are verified, a pinned digest cannot be
/// substituted, sizes are bounded, and tokens are only fetched from the registry's own
/// domain. Credentials never leave over plain HTTP unless the policy allows that host,
/// and never follow a redirect to another host.
final class RegistrySession: ContentClient, @unchecked Sendable {
    let host: String  // as in the reference: docker.io, ghcr.io, 127.0.0.1:5000
    let base: URL
    private let credentials: (username: String, password: String)?
    private let policy: RegistryPolicy
    private let note: @Sendable (String) -> Void
    private var transport: (any RegistryTransport)!
    private let lock = NSLock()
    private var tokens: [String: (header: String, expires: Date)] = [:]  // by scope
    private var basic = false  // the registry asked for Basic
    private var noted: Set<String> = []
    static let manifestLimit = 4 << 20

    static let manifestTypes = [MediaTypes.dockerManifest, MediaTypes.dockerManifestList, MediaTypes.imageManifest, MediaTypes.index]

    /// `note` gets each awareness message once per session (pull/push output, daemon log).
    init(host: String, credentials: (username: String, password: String)?, policy: RegistryPolicy,
         note: @escaping @Sendable (String) -> Void = { _ in }) throws
    {
        self.host = host.lowercased()
        let wire = self.host == "docker.io" ? "registry-1.docker.io" : self.host
        let scheme = Self.scheme(for: self.host, wire: wire, policy: policy)
        guard let url = URL(string: "\(scheme)://\(wire)") else { throw RegistryError(status: 400, description: "invalid registry \(host)") }
        base = url
        // The Docker CLI sends an empty auth for an anonymous pull: that is no login.
        self.credentials = credentials.flatMap { $0.username.isEmpty && $0.password.isEmpty ? nil : $0 }
        self.policy = policy
        self.note = note
        transport = policy.transport(host: self.host) { [weak self] key, message in self?.say(key, message) }
        if base.scheme == "http", let why = policy.plainHTTPReason(self.host) {
            say("plain-http", "pratico: \(self.host) answers plain HTTP; pratico uses it (\(why)), so this traffic is not encrypted")
        }
    }

    deinit { transport?.shutdown() }

    private func say(_ key: String, _ message: String) {
        lock.lock()
        let first = noted.insert(key).inserted
        lock.unlock()
        guard first else { return }
        note(message)
        Pratico.log("pratico-daemon: \(message)")
    }

    // MARK: Scheme

    /// HTTPS, unless the policy allows plain HTTP for the host and it does not speak TLS
    /// (Docker's order for insecure registries). Definite answers are kept per daemon run.
    private static func scheme(for host: String, wire: String, policy: RegistryPolicy) -> String {
        guard policy.plainHTTPReason(host) != nil else { return "https" }
        return schemes.answer(host) {
            guard let url = URL(string: "https://\(wire)/v2/") else { return "https" }
            let probe = policy.transport(host: host) { _, _ in }
            defer { probe.shutdown() }
            // nil: not up yet, ask again next time.
            return (try? blocking { await probe.speaksTLS(url) }).flatMap { $0.map { $0 ? "https" : "http" } }
        } ?? "https"
    }

    private static let schemes = Memo<String, String>()

    // MARK: Redirects

    /// The next request for a redirect, or nil to stop at it: never from HTTPS to plain
    /// HTTP, and no credentials to another host (blobs commonly redirect to a CDN, which
    /// gets none). Both transports leave redirects to this.
    static func redirect(_ request: RegistryRequest, _ response: RegistryResponse) -> RegistryRequest? {
        let from = request.url
        guard [301, 302, 303, 307, 308].contains(response.status),
            let location = response.value("Location"), let to = URL(string: location, relativeTo: from)?.absoluteURL
        else { return nil }
        if from.scheme == "https" && to.scheme != "https" { return nil }
        var next = request
        next.url = to
        if response.status == 303 && request.httpMethod != "HEAD" { next.httpMethod = "GET" }
        if from.host?.lowercased() != to.host?.lowercased() || from.port != to.port {
            next.setValue(nil, forHTTPHeaderField: "Authorization")
        }
        return next
    }

    static let maxRedirects = 10

    // MARK: Requests

    private func url(_ path: String, query: [URLQueryItem]? = nil) -> URL {
        var c = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        c.percentEncodedPath = path
        c.queryItems = query
        return c.url!
    }

    /// Sends `make()` with what the registry asked for: a cached Bearer token for `scope`,
    /// or Basic. A 401 with a challenge is answered once.
    private func send(_ scope: String?, _ make: () throws -> RegistryRequest) async throws -> (RegistryBody, RegistryResponse) {
        var answered = false
        while true {
            var request = try make()
            if let header = authorization(scope) { request.setValue(header, forHTTPHeaderField: "Authorization") }
            var (http, bytes) = try await transport.send(request)
            var hops = 0
            while hops < Self.maxRedirects, let next = Self.redirect(request, http) {
                hops += 1
                request = next
                (http, bytes) = try await transport.send(request)
            }
            guard http.status == 401, !answered, let challenge = http.value("WWW-Authenticate") else {
                return (bytes, http)
            }
            answered = true
            try await answer(challenge, scope: scope)
        }
    }

    private func authorization(_ scope: String?) -> String? {
        lock.lock()
        defer { lock.unlock() }
        if let t = tokens[scope ?? ""], t.expires > Date() { return t.header }
        if basic, let c = credentials { return Self.basicHeader(c) }
        return nil
    }

    static func basicHeader(_ c: (username: String, password: String)) -> String {
        "Basic " + Data("\(c.username):\(c.password)".utf8).base64EncodedString()
    }

    private func answer(_ header: String, scope: String?) async throws {
        let challenges = Self.parseChallenges(header)
        if let bearer = challenges.first(where: { $0.type == "bearer" }) {
            try await fetchToken(bearer.params, scope: bearer.params["scope"] ?? scope, key: scope ?? "")
        } else if challenges.contains(where: { $0.type == "basic" }) {
            guard credentials != nil else { throw RegistryError(status: 401, description: "\(host) requires a login: run docker login \(host)") }
            lock.withLock { basic = true }
        } else {
            throw RegistryError(status: 401, description: "\(host) asked for an authentication scheme pratico does not speak: \(header)")
        }
    }

    private func fetchToken(_ params: [String: String], scope: String?, key: String) async throws {
        guard let realm = params["realm"], var c = URLComponents(string: realm) else {
            throw RegistryError(status: 401, description: "\(host) sent a Bearer challenge without a realm")
        }
        try validateRealm(c)
        var items = [URLQueryItem(name: "client_id", value: "pratico")]
        if let s = params["service"] { items.append(URLQueryItem(name: "service", value: s)) }
        if let scope, !scope.isEmpty { items.append(URLQueryItem(name: "scope", value: scope)) }
        c.queryItems = items
        guard let url = c.url else { throw RegistryError(status: 401, description: "invalid token realm \(realm)") }
        var request = RegistryRequest(url: url)
        if let creds = credentials { request.setValue(Self.basicHeader(creds), forHTTPHeaderField: "Authorization") }
        // Token requests do not follow redirects (Containerization refuses them too).
        let (http, body) = try await transport.send(request)
        guard http.status == 200 else {
            // A refusal, or a token server asking for credentials again: wrong ones.
            if [401, 403].contains(http.status) || http.value("WWW-Authenticate") != nil {
                throw Self.wrongCredentials(host)
            }
            throw RegistryError(status: http.status, description: "token request to \(realm) failed with response: \(http.status)")
        }
        let data = try await Self.collect(body, limit: 1 << 20)
        guard let json = JSON.parse(data), let token = json["token"]?.string ?? json["access_token"]?.string else {
            throw RegistryError(status: 502, description: "\(realm) answered without a token")
        }
        let ttl = Double(json["expires_in"]?.int ?? 60)
        lock.withLock { tokens[key] = ("Bearer \(token)", Date().addingTimeInterval(max(ttl - 5, 5))) }
    }

    /// Tokens only from the registry's own registrable domain (registry-1.docker.io →
    /// auth.docker.io), over HTTPS; a plain-HTTP registry may only use itself.
    private func validateRealm(_ realm: URLComponents) throws {
        guard let realmHost = realm.host?.lowercased(), let registryHost = base.host?.lowercased() else {
            throw RegistryError(status: 401, description: "cannot tell the token server's host")
        }
        if base.scheme == "http" {
            guard realm.scheme == "http" || realm.scheme == "https", realmHost == registryHost, realm.port == base.port else {
                throw RegistryError(status: 401, description: "\(host) is plain HTTP; pratico takes tokens only from \(host) itself, not \(realmHost)")
            }
            return
        }
        guard realm.scheme == "https" else { throw RegistryError(status: 401, description: "token server \(realmHost) is not HTTPS") }
        func domain(_ h: String) -> String? {
            guard IPv4.parse(h) == nil, !h.contains(":") else { return nil }
            let labels = h.split(separator: ".")
            return labels.count >= 2 ? labels.suffix(2).joined(separator: ".") : nil
        }
        if let a = domain(registryHost), let b = domain(realmHost) {
            guard a == b else { throw RegistryError(status: 401, description: "token server \(realmHost) is not in \(registryHost)'s domain") }
            return
        }
        guard realmHost == registryHost, (realm.port ?? 443) == (base.port ?? 443) else {
            throw RegistryError(status: 401, description: "token server \(realmHost) does not match registry \(registryHost)")
        }
    }

    static func parseChallenges(_ header: String) -> [(type: String, params: [String: String])] {
        var out: [(String, [String: String])] = []
        let scanner = Scanner(string: header)
        scanner.charactersToBeSkipped = .whitespaces
        while !scanner.isAtEnd {
            guard let type = scanner.scanUpToCharacters(from: .whitespaces) else { break }
            var params: [String: String] = [:]
            while let key = scanner.scanUpToString("="), scanner.scanString("=") != nil {
                let value: String
                if scanner.scanString("\"") != nil {
                    value = scanner.scanUpToString("\"") ?? ""
                    _ = scanner.scanString("\"")
                } else {
                    value = scanner.scanUpToString(",") ?? ""
                }
                params[key.trimmingCharacters(in: CharacterSet(charactersIn: ", ")).lowercased()] = value
                if scanner.scanString(",") == nil { break }
            }
            out.append((type.lowercased(), params))
        }
        return out
    }

    static func collect(_ body: RegistryBody, limit: Int) async throws -> Data {
        var data = Data()
        for try await chunk in body {
            data.append(chunk)
            guard data.count <= limit else { throw RegistryError(status: 502, description: "response larger than \(limit) bytes") }
        }
        return data
    }

    private func failure(_ http: RegistryResponse, _ body: RegistryBody, _ what: String) async -> RegistryError {
        let json = (try? await Self.collect(body, limit: 64 << 10)).flatMap { JSON.parse($0) }
        let reason = json?["errors"]?.array?.first?["message"]?.string ?? HTTPResponseStatus(statusCode: http.status).reasonPhrase
        if http.status == 401 || http.status == 403 {
            // Docker Hub answers a repository that does not exist the same way, with or
            // without a login: say so, as Docker does.
            let hint = credentials == nil
                ? " (the repository does not exist, or it is private: docker login \(host))"
                : " (the repository does not exist, or the login pratico keeps for \(host) cannot read it)"
            return RegistryError(status: http.status, description: "\(what): unauthorized: \(reason)\(hint)")
        }
        return RegistryError(status: http.status, description: "\(what) failed with response: \(http.status) \(reason)")
    }

    // MARK: Login

    /// `GET /v2/` with the credentials: a 401 after answering the challenge means wrong
    /// credentials. A registry without authentication accepts any.
    func ping() async throws {
        let (bytes, http) = try await send(nil) { RegistryRequest(url: url("/v2/")) }
        guard http.status == 200 else {
            let e = await failure(http, bytes, "GET \(url("/v2/").absoluteString)")
            if e.unauthorized { throw Self.wrongCredentials("Get \"\(url("/v2/").absoluteString)\"") }
            throw e
        }
    }

    /// Docker's wording, which scripts match on.
    private static func wrongCredentials(_ what: String) -> RegistryError {
        RegistryError(status: 401, description: "\(what): unauthorized: incorrect username or password")
    }

    // MARK: ContentClient

    static func scope(_ name: String, push: Bool = false) -> String { "repository:\(name):\(push ? "pull,push" : "pull")" }

    private func path(_ name: String, _ d: Descriptor) -> String {
        "/v2/\(name)/\(Self.manifestTypes.contains(d.mediaType) ? "manifests" : "blobs")/\(d.digest)"
    }

    func resolve(name: String, tag: String) async throws -> Descriptor {
        let accept = (Self.manifestTypes + ["*/*"]).joined(separator: ", ")
        let target = url("/v2/\(name)/manifests/\(tag)")
        let (bytes, http) = try await send(Self.scope(name)) {
            var r = RegistryRequest(url: target)
            r.httpMethod = "HEAD"
            r.setValue(accept, forHTTPHeaderField: "Accept")
            return r
        }
        guard http.status == 200 else { throw await failure(http, bytes, "HEAD \(target.absoluteString)") }
        guard let header = http.value("Docker-Content-Digest"),
            let digest = try? ParsedDigest(parsing: header).description
        else { throw RegistryError(status: 502, description: "\(host) sent no valid Docker-Content-Digest for \(name):\(tag)") }
        guard let type = http.value("Content-Type"),
            let size = http.value("Content-Length").flatMap(Int64.init), size >= 0
        else { throw RegistryError(status: 502, description: "\(host) sent no Content-Type or Content-Length for \(name):\(tag)") }
        if tag.hasPrefix("sha256:"), digest.lowercased() != tag.lowercased() {
            throw RegistryError(status: 502, description: "registry returned digest \(digest) for pinned reference \(tag), refusing to accept substituted content")
        }
        return Descriptor(mediaType: type, digest: digest, size: size)
    }

    func fetch<T: Codable>(name: String, descriptor: Descriptor) async throws -> T {
        try JSONDecoder().decode(T.self, from: try await fetchData(name: name, descriptor: descriptor))
    }

    func fetchData(name: String, descriptor: Descriptor) async throws -> Data {
        guard !descriptor.mediaType.isEmpty else { throw RegistryError(status: 400, description: "missing media type for \(descriptor.digest)") }
        let target = url(path(name, descriptor))
        let (bytes, http) = try await send(Self.scope(name)) {
            var r = RegistryRequest(url: target)
            r.setValue(descriptor.mediaType, forHTTPHeaderField: "Accept")
            return r
        }
        guard http.status == 200 else { throw await failure(http, bytes, "GET \(target.absoluteString)") }
        let data = try await Self.collect(bytes, limit: Int(min(descriptor.size, Int64(Self.manifestLimit * 16))))
        try Self.verify(SHA256.hash(data: data), descriptor)
        return data
    }

    func fetchBlob(name: String, descriptor: Descriptor, into file: URL, progress: ProgressHandler?) async throws -> (Int64, SHA256Digest) {
        let target = url("/v2/\(name)/blobs/\(descriptor.digest)")
        let (bytes, http) = try await send(Self.scope(name)) {
            var r = RegistryRequest(url: target)
            r.setValue(descriptor.mediaType.isEmpty ? "*/*" : descriptor.mediaType, forHTTPHeaderField: "Accept")
            return r
        }
        guard http.status == 200 else { throw await failure(http, bytes, "GET \(target.absoluteString)") }
        guard FileManager.default.createFile(atPath: file.path, contents: nil), let out = try? FileHandle(forWritingTo: file) else {
            throw RegistryError(status: 500, description: "cannot create \(file.path)")
        }
        defer { try? out.close() }
        var hasher = SHA256()
        var received: Int64 = 0
        for try await chunk in bytes {
            received += Int64(chunk.count)
            guard received <= descriptor.size else {
                throw RegistryError(status: 502, description: "blob download exceeded expected size \(descriptor.size) for \(descriptor.digest)")
            }
            try out.write(contentsOf: chunk)
            hasher.update(data: chunk)
            await progress?([.addSize(Int64(chunk.count))])
        }
        let digest = hasher.finalize()
        try Self.verify(digest, descriptor)
        return (received, digest)
    }

    private static func verify(_ digest: SHA256.Digest, _ d: Descriptor) throws {
        let computed = "sha256:" + digest.map { String(format: "%02x", $0) }.joined()
        guard computed == d.digest.lowercased() else {
            throw RegistryError(status: 502, description: "content digest mismatch: expected \(d.digest)")
        }
    }

    /// Manifests go to `manifests/<tag>`, blobs through an upload session; content the
    /// registry already has is reported as `.exists`, as Containerization's export expects.
    func push<T: Sendable & AsyncSequence>(name: String, ref tag: String, descriptor: Descriptor,
                                           streamGenerator: () throws -> T, progress: ProgressHandler?) async throws
    where T.Element == ByteBuffer {
        let isManifest = Self.manifestTypes.contains(descriptor.mediaType)
        let scope = Self.scope(name, push: true)
        let object = isManifest ? (tag.contains("@") || tag.isEmpty ? descriptor.digest : tag) : descriptor.digest
        let check = url("/v2/\(name)/\(isManifest ? "manifests" : "blobs")/\(object)")
        let (headBytes, head) = try await send(scope) {
            var r = RegistryRequest(url: check)
            r.httpMethod = "HEAD"
            r.setValue("\(descriptor.mediaType), */*", forHTTPHeaderField: "Accept")
            return r
        }
        if head.status == 200, !isManifest || object == descriptor.digest
            || head.value("Docker-Content-Digest") == descriptor.digest
        {
            throw ContainerizationError(.exists, message: "content already exists \(descriptor.digest)")
        } else if head.status != 200 && head.status != 404 {
            throw await failure(head, headBytes, "HEAD \(check.absoluteString)")
        }

        // The body, staged on disk: URLSession uploads a file, and a retry after a challenge needs it again.
        let staged = FileManager.default.temporaryDirectory.appending(path: "pratico-push-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: staged.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: staged) }
        let out = try FileHandle(forWritingTo: staged)
        for try await buf in try streamGenerator() { try out.write(contentsOf: Data(buf.readableBytesView)) }
        try out.close()

        let target: URL
        if isManifest {
            target = check
        } else {
            let start = url("/v2/\(name)/blobs/uploads/")
            let (b, http) = try await send(scope) {
                var r = RegistryRequest(url: start)
                r.httpMethod = "POST"
                return r
            }
            if http.status == 201 { throw ContainerizationError(.exists, message: "content already exists \(descriptor.digest)") }
            guard [200, 202, 204].contains(http.status), let location = http.value("Location"),
                var c = URLComponents(string: location)
            else { throw await failure(http, b, "POST \(start.absoluteString)") }
            // A relative Location is on the registry; an absolute one must stay on it too.
            if let h = c.host, h.lowercased() != base.host?.lowercased() {
                throw RegistryError(status: 502, description: "\(host) sent an upload location on another host (\(h))")
            }
            var resolved = URLComponents(url: base, resolvingAgainstBaseURL: false)!
            resolved.percentEncodedPath = c.percentEncodedPath
            c.queryItems = (c.queryItems ?? []) + [URLQueryItem(name: "digest", value: descriptor.digest)]
            resolved.percentEncodedQuery = c.percentEncodedQuery
            target = resolved.url!
        }
        let contentType = isManifest ? descriptor.mediaType : "application/octet-stream"
        var put = RegistryRequest(url: target)
        put.httpMethod = "PUT"
        put.setValue(contentType, forHTTPHeaderField: "Content-Type")
        put.setValue(String(descriptor.size), forHTTPHeaderField: "Content-Length")
        if let header = authorization(scope) { put.setValue(header, forHTTPHeaderField: "Authorization") }
        let http = try await transport.upload(put, file: staged)
        guard [200, 201, 204].contains(http.status) else {
            throw RegistryError(status: http.status, description: "PUT \(target.absoluteString) failed with response: \(http.status)")
        }
        guard http.value("Docker-Content-Digest") == descriptor.digest else {
            throw RegistryError(status: 502, description: "\(host) stored \(descriptor.digest) under another digest")
        }
    }
}

/// A per-key answer computed once it is known.
private final class Memo<Key: Hashable, Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Key: Value] = [:]

    /// `compute` returning nil means "no answer yet": nothing is kept.
    func answer(_ key: Key, _ compute: () -> Value?) -> Value? {
        lock.lock()
        if let v = values[key] { lock.unlock(); return v }
        lock.unlock()
        guard let v = compute() else { return nil }
        lock.lock()
        values[key] = v
        lock.unlock()
        return v
    }
}
