import ContainerizationError
import ContainerizationExtras
import ContainerizationOCI
import Crypto
import Foundation
import NIOCore
import PraticoCore
import Security

/// How the embedded runtime reaches registries (SPEC D-29), from `config.toml`:
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
    var cas: [CA] = []
    /// The CA certificates themselves, in `cas` order.
    var anchors: [SecCertificate] = []

    /// Loads and checks the CA files; an unreadable or empty one is a configuration error,
    /// so the daemon refuses to start rather than silently trusting less (or more).
    static func load(_ config: Config, environment: [String: String] = ProcessInfo.processInfo.environment) throws -> RegistryPolicy {
        var p = RegistryPolicy()
        p.httpHosts = config.registryHTTP.map { $0.lowercased() }
        p.httpLoopback = config.registryHTTPLoopback
        p.systemRoots = config.registrySystemRoots
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
                guard let cert = SecCertificateCreateWithData(nil, der as CFData) else {
                    throw ConfigError("registry_ca: \(file) holds a certificate macOS cannot read")
                }
                let subject = (SecCertificateCopySubjectSummary(cert) as String?) ?? "unnamed"
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
         "ca": .array(cas.map { ["file": .string($0.file), "subject": .string($0.subject), "sha256": .string($0.sha256)] })]
    }
}

/// Errors in Docker-like wording; `ImageService` prefixes them.
struct RegistryError: Error, CustomStringConvertible {
    var status: Int
    var description: String
    var unauthorized: Bool { status == 401 || status == 403 }
}

/// pratico's registry client (OCI distribution), on URLSession: the system's proxy and
/// PAC settings and its trusted roots (MDM-installed ones included) apply, plus the
/// policy above. It is the `ContentClient` Containerization's import and export use.
///
/// It keeps Containerization's guards: digests are verified, a pinned digest cannot be
/// substituted, sizes are bounded, and tokens are only fetched from the registry's own
/// domain. Credentials never leave over plain HTTP unless the policy allows that host,
/// and never follow a redirect to another host.
final class RegistrySession: NSObject, ContentClient, URLSessionTaskDelegate, @unchecked Sendable {
    let host: String  // as in the reference: docker.io, ghcr.io, 127.0.0.1:5000
    let base: URL
    private let credentials: (username: String, password: String)?
    private let policy: RegistryPolicy
    private let note: @Sendable (String) -> Void
    private var session: URLSession!
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
        self.credentials = credentials
        self.policy = policy
        self.note = note
        super.init()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpAdditionalHeaders = ["User-Agent": "pratico/\(Pratico.version)"]
        configuration.connectionProxyDictionary = Self.environmentProxy()
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        if base.scheme == "http", let why = policy.plainHTTPReason(self.host) {
            say("plain-http", "pratico: \(self.host) answers plain HTTP; pratico uses it (\(why)), so this traffic is not encrypted")
        }
    }

    deinit { session?.finishTasksAndInvalidate() }

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
            let request = URLRequest(url: url, timeoutInterval: 5)
            let probe = URLSession(configuration: .ephemeral, delegate: ProbeTrust(policy: policy), delegateQueue: nil)
            defer { probe.finishTasksAndInvalidate() }
            do {
                _ = try blocking { try await probe.data(for: request) }
                return "https"  // any HTTP status: TLS works
            } catch let e as URLError where e.code == .cannotConnectToHost || e.code == .timedOut || e.code == .networkConnectionLost {
                return nil  // not up yet: ask again next time
            } catch let e as URLError where e.code == .secureConnectionFailed {
                return "http"  // no TLS there
            } catch {
                // TLS with a certificate pratico does not trust: no silent downgrade; the
                // request fails and says which CA to add.
                return "https"
            }
        } ?? "https"
    }

    private static let schemes = Memo<String, String>()

    /// Docker's daemon honours HTTPS_PROXY/HTTP_PROXY/NO_PROXY; without them the system's
    /// proxy settings (and PAC) apply.
    static func environmentProxy(_ env: [String: String] = ProcessInfo.processInfo.environment) -> [AnyHashable: Any]? {
        func url(_ k: String) -> URL? { (env[k] ?? env[k.lowercased()]).flatMap { URL(string: $0) } }
        let https = url("HTTPS_PROXY"), http = url("HTTP_PROXY")
        guard https != nil || http != nil else { return nil }
        var d: [AnyHashable: Any] = [:]
        if let p = https, let h = p.host {
            d[kCFNetworkProxiesHTTPSEnable] = 1
            d[kCFNetworkProxiesHTTPSProxy] = h
            d[kCFNetworkProxiesHTTPSPort] = p.port ?? 443
        }
        if let p = http, let h = p.host {
            d[kCFNetworkProxiesHTTPEnable] = 1
            d[kCFNetworkProxiesHTTPProxy] = h
            d[kCFNetworkProxiesHTTPPort] = p.port ?? 80
        }
        if let no = env["NO_PROXY"] ?? env["no_proxy"] {
            d["ExceptionsList"] = no.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        }
        return d
    }

    // MARK: Trust and redirects

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge)
        async -> (URLSession.AuthChallengeDisposition, URLCredential?)
    {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
            let trust = challenge.protectionSpace.serverTrust
        else { return (.performDefaultHandling, nil) }
        switch Self.evaluate(trust, policy) {
        case .system:
            return (.useCredential, URLCredential(trust: trust))
        case .extra(let ca):
            let h = challenge.protectionSpace.host
            say("ca-\(h)", "pratico: \(h)'s certificate is trusted through an extra CA, \"\(ca.subject)\" SHA-256 \(ca.sha256.prefix(16))… (registry_ca), not a system root")
            return (.useCredential, URLCredential(trust: trust))
        case .untrusted:
            return (.cancelAuthenticationChallenge, nil)
        }
    }

    enum Verdict { case system, extra(RegistryPolicy.CA), untrusted }

    /// The system's roots first (unless disabled), then each extra CA, so pratico can say
    /// which one vouched for the registry.
    static func evaluate(_ trust: SecTrust, _ policy: RegistryPolicy) -> Verdict {
        if policy.systemRoots {
            SecTrustSetAnchorCertificates(trust, nil)
            SecTrustSetAnchorCertificatesOnly(trust, false)
            if SecTrustEvaluateWithError(trust, nil) { return .system }
        }
        for (i, anchor) in policy.anchors.enumerated() {
            SecTrustSetAnchorCertificates(trust, [anchor] as CFArray)
            SecTrustSetAnchorCertificatesOnly(trust, true)
            if SecTrustEvaluateWithError(trust, nil) { return .extra(policy.cas[i]) }
        }
        return .untrusted
    }

    /// No downgrade to plain HTTP, and no credentials to another host (blobs commonly
    /// redirect to a CDN, which gets none).
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest?
    {
        guard let from = task.originalRequest?.url, let to = request.url else { return nil }
        if from.scheme == "https" && to.scheme != "https" { return nil }
        var next = request
        if from.host?.lowercased() != to.host?.lowercased() || from.port != to.port {
            next.setValue(nil, forHTTPHeaderField: "Authorization")
        }
        return next
    }

    // MARK: Requests

    private func url(_ path: String, query: [URLQueryItem]? = nil) -> URL {
        var c = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        c.percentEncodedPath = path
        c.queryItems = query
        return c.url!
    }

    /// Sends `make()` with what the registry asked for: a cached Bearer token for `scope`,
    /// or Basic. A 401 with a challenge is answered once.
    private func send(_ scope: String?, _ make: () throws -> URLRequest) async throws -> (URLSession.AsyncBytes, HTTPURLResponse) {
        var answered = false
        while true {
            var request = try make()
            if let header = authorization(scope) { request.setValue(header, forHTTPHeaderField: "Authorization") }
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw RegistryError(status: 502, description: "no HTTP response from \(host)") }
            guard http.statusCode == 401, !answered, let challenge = http.value(forHTTPHeaderField: "WWW-Authenticate") else {
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
        var request = URLRequest(url: url)
        if let creds = credentials { request.setValue(Self.basicHeader(creds), forHTTPHeaderField: "Authorization") }
        let (data, response) = try await session.data(for: request, delegate: NoRedirects())
        guard let http = response as? HTTPURLResponse else { throw RegistryError(status: 502, description: "no response from \(realm)") }
        guard http.statusCode == 200 else {
            // A refusal, or a token server asking for credentials again: wrong ones.
            if [401, 403].contains(http.statusCode) || http.value(forHTTPHeaderField: "WWW-Authenticate") != nil {
                throw Self.wrongCredentials(host)
            }
            throw RegistryError(status: http.statusCode, description: "token request to \(realm) failed with response: \(http.statusCode)")
        }
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

    private static func collect(_ bytes: URLSession.AsyncBytes, limit: Int) async throws -> Data {
        var data = Data()
        for try await b in bytes {
            data.append(b)
            guard data.count <= limit else { throw RegistryError(status: 502, description: "response larger than \(limit) bytes") }
        }
        return data
    }

    private func failure(_ http: HTTPURLResponse, _ bytes: URLSession.AsyncBytes, _ what: String) async -> RegistryError {
        let body = (try? await Self.collect(bytes, limit: 64 << 10)).flatMap { JSON.parse($0) }
        let reason = body?["errors"]?.array?.first?["message"]?.string ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
        if http.statusCode == 401 || http.statusCode == 403 {
            return RegistryError(status: http.statusCode, description: "\(what): unauthorized: \(reason)")
        }
        return RegistryError(status: http.statusCode, description: "\(what) failed with response: \(http.statusCode) \(reason)")
    }

    // MARK: Login

    /// `GET /v2/` with the credentials: a 401 after answering the challenge means wrong
    /// credentials. A registry without authentication accepts any.
    func ping() async throws {
        let (bytes, http) = try await send(nil) { URLRequest(url: url("/v2/")) }
        guard http.statusCode == 200 else {
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
            var r = URLRequest(url: target)
            r.httpMethod = "HEAD"
            r.setValue(accept, forHTTPHeaderField: "Accept")
            return r
        }
        guard http.statusCode == 200 else { throw await failure(http, bytes, "HEAD \(target.absoluteString)") }
        guard let header = http.value(forHTTPHeaderField: "Docker-Content-Digest"),
            let digest = try? ParsedDigest(parsing: header).description
        else { throw RegistryError(status: 502, description: "\(host) sent no valid Docker-Content-Digest for \(name):\(tag)") }
        guard let type = http.value(forHTTPHeaderField: "Content-Type"),
            let size = http.value(forHTTPHeaderField: "Content-Length").flatMap(Int64.init), size >= 0
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
            var r = URLRequest(url: target)
            r.setValue(descriptor.mediaType, forHTTPHeaderField: "Accept")
            return r
        }
        guard http.statusCode == 200 else { throw await failure(http, bytes, "GET \(target.absoluteString)") }
        let data = try await Self.collect(bytes, limit: Int(min(descriptor.size, Int64(Self.manifestLimit * 16))))
        try Self.verify(SHA256.hash(data: data), descriptor)
        return data
    }

    func fetchBlob(name: String, descriptor: Descriptor, into file: URL, progress: ProgressHandler?) async throws -> (Int64, SHA256Digest) {
        let target = url("/v2/\(name)/blobs/\(descriptor.digest)")
        let (bytes, http) = try await send(Self.scope(name)) {
            var r = URLRequest(url: target)
            r.setValue(descriptor.mediaType.isEmpty ? "*/*" : descriptor.mediaType, forHTTPHeaderField: "Accept")
            return r
        }
        guard http.statusCode == 200 else { throw await failure(http, bytes, "GET \(target.absoluteString)") }
        guard FileManager.default.createFile(atPath: file.path, contents: nil), let out = try? FileHandle(forWritingTo: file) else {
            throw RegistryError(status: 500, description: "cannot create \(file.path)")
        }
        defer { try? out.close() }
        var hasher = SHA256()
        var received: Int64 = 0
        var chunk = Data()
        chunk.reserveCapacity(1 << 16)
        func flush() async throws {
            guard !chunk.isEmpty else { return }
            try out.write(contentsOf: chunk)
            hasher.update(data: chunk)
            await progress?([.addSize(Int64(chunk.count))])
            chunk.removeAll(keepingCapacity: true)
        }
        for try await b in bytes {
            chunk.append(b)
            received += 1
            guard received <= descriptor.size else {
                throw RegistryError(status: 502, description: "blob download exceeded expected size \(descriptor.size) for \(descriptor.digest)")
            }
            if chunk.count >= 1 << 16 { try await flush() }
        }
        try await flush()
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
            var r = URLRequest(url: check)
            r.httpMethod = "HEAD"
            r.setValue("\(descriptor.mediaType), */*", forHTTPHeaderField: "Accept")
            return r
        }
        if head.statusCode == 200, !isManifest || object == descriptor.digest
            || head.value(forHTTPHeaderField: "Docker-Content-Digest") == descriptor.digest
        {
            throw ContainerizationError(.exists, message: "content already exists \(descriptor.digest)")
        } else if head.statusCode != 200 && head.statusCode != 404 {
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
                var r = URLRequest(url: start)
                r.httpMethod = "POST"
                return r
            }
            if http.statusCode == 201 { throw ContainerizationError(.exists, message: "content already exists \(descriptor.digest)") }
            guard [200, 202, 204].contains(http.statusCode), let location = http.value(forHTTPHeaderField: "Location"),
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
        var put = URLRequest(url: target)
        put.httpMethod = "PUT"
        put.setValue(contentType, forHTTPHeaderField: "Content-Type")
        put.setValue(String(descriptor.size), forHTTPHeaderField: "Content-Length")
        if let header = authorization(scope) { put.setValue(header, forHTTPHeaderField: "Authorization") }
        let (_, response) = try await session.upload(for: put, fromFile: staged)
        guard let http = response as? HTTPURLResponse, [200, 201, 204].contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw RegistryError(status: code, description: "PUT \(target.absoluteString) failed with response: \(code)")
        }
        guard http.value(forHTTPHeaderField: "Docker-Content-Digest") == descriptor.digest else {
            throw RegistryError(status: 502, description: "\(host) stored \(descriptor.digest) under another digest")
        }
    }
}

/// Token requests do not follow redirects (Containerization refuses them too).
private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? { nil }
}

/// The scheme probe verifies certificates by the same policy as real requests.
private final class ProbeTrust: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let policy: RegistryPolicy
    init(policy: RegistryPolicy) { self.policy = policy }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge)
        async -> (URLSession.AuthChallengeDisposition, URLCredential?)
    {
        guard let trust = challenge.protectionSpace.serverTrust else { return (.performDefaultHandling, nil) }
        if case .untrusted = RegistrySession.evaluate(trust, policy) { return (.cancelAuthenticationChallenge, nil) }
        return (.useCredential, URLCredential(trust: trust))
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
