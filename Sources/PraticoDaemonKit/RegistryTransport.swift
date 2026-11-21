import Foundation
import PraticoCore

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Security)
import Security
#else
import AsyncHTTPClient
import NIOCore
import NIOHTTP1
import NIOSSL
#endif

/// A registry's answer as `RegistrySession` reads it, from either HTTP stack.
struct RegistryResponse: Sendable {
    let status: Int
    private let headers: [String: String]  // by lowercased name

    init(status: Int, headers: [String: String]) {
        self.status = status
        self.headers = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { a, _ in a })
    }

    func value(_ name: String) -> String? { headers[name.lowercased()] }
}

typealias RegistryBody = AsyncThrowingStream<Data, any Error>

/// A request as `RegistrySession` builds it, for either HTTP stack: Foundation's
/// `URLRequest` would pull FoundationNetworking, and with it libcurl, into the Linux build.
struct RegistryRequest: Sendable {
    var url: URL
    var httpMethod = "GET"
    private(set) var headers: [String: String] = [:]

    init(url: URL) { self.url = url }

    mutating func setValue(_ value: String?, forHTTPHeaderField name: String) {
        headers = headers.filter { $0.key.lowercased() != name.lowercased() }
        if let value { headers[name] = value }
    }

    func value(forHTTPHeaderField name: String) -> String? {
        headers.first { $0.key.lowercased() == name.lowercased() }?.value
    }
}

/// How `RegistrySession` reaches a registry: URLSession on the Mac, so the system's proxy,
/// PAC settings, and roots (MDM-installed ones included) apply; AsyncHTTPClient on Linux
/// hosts (docs/design/remote.md), with `HTTPS_PROXY`/`NO_PROXY` and the system's CA bundle.
/// Neither follows redirects: `RegistrySession` applies one redirect policy to both.
protocol RegistryTransport: Sendable {
    func send(_ request: RegistryRequest) async throws -> (RegistryResponse, RegistryBody)
    func upload(_ request: RegistryRequest, file: URL) async throws -> RegistryResponse
    /// TLS answered at `url`, whatever the status: true; no TLS there: false; no answer
    /// yet (refused, timed out): nil. A certificate the policy does not trust counts as
    /// TLS, so the request fails and says which CA to add, never a silent downgrade.
    func speaksTLS(_ url: URL) async -> Bool?
    func shutdown()
}

extension RegistryPolicy {
    /// The transport for one registry host; `note` gets trust messages (once per session).
    func transport(host: String, note: @escaping @Sendable (_ key: String, _ message: String) -> Void) -> any RegistryTransport {
        #if canImport(Security)
        URLSessionTransport(policy: self, note: note)
        #else
        HTTPClientTransport(policy: self, host: host)
        #endif
    }
}

#if canImport(Security)

final class URLSessionTransport: NSObject, RegistryTransport, URLSessionTaskDelegate, @unchecked Sendable {
    private let policy: RegistryPolicy
    private let note: @Sendable (String, String) -> Void
    private var session: URLSession!

    init(policy: RegistryPolicy, note: @escaping @Sendable (String, String) -> Void) {
        self.policy = policy
        self.note = note
        super.init()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpAdditionalHeaders = ["User-Agent": "pratico/\(Pratico.version)"]
        configuration.connectionProxyDictionary = Self.environmentProxy()
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    func shutdown() { session.finishTasksAndInvalidate() }

    func send(_ request: RegistryRequest) async throws -> (RegistryResponse, RegistryBody) {
        let (bytes, response) = try await session.bytes(for: Self.urlRequest(request))
        let head = try Self.head(response)
        let body = RegistryBody { continuation in
            let task = Task {
                do {
                    var chunk = Data()
                    chunk.reserveCapacity(1 << 16)
                    for try await b in bytes {
                        chunk.append(b)
                        if chunk.count >= 1 << 16 {
                            continuation.yield(chunk)
                            chunk.removeAll(keepingCapacity: true)
                        }
                    }
                    if !chunk.isEmpty { continuation.yield(chunk) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return (head, body)
    }

    func upload(_ request: RegistryRequest, file: URL) async throws -> RegistryResponse {
        let (_, response) = try await session.upload(for: Self.urlRequest(request), fromFile: file)
        return try Self.head(response)
    }

    func speaksTLS(_ url: URL) async -> Bool? {
        do {
            _ = try await session.data(for: URLRequest(url: url, timeoutInterval: 5))
            return true
        } catch let e as URLError where e.code == .cannotConnectToHost || e.code == .timedOut || e.code == .networkConnectionLost {
            return nil
        } catch let e as URLError where e.code == .secureConnectionFailed {
            return false
        } catch {
            return true
        }
    }

    private static func urlRequest(_ r: RegistryRequest) -> URLRequest {
        var out = URLRequest(url: r.url)
        out.httpMethod = r.httpMethod
        for (k, v) in r.headers { out.setValue(v, forHTTPHeaderField: k) }
        return out
    }

    private static func head(_ response: URLResponse) throws -> RegistryResponse {
        guard let http = response as? HTTPURLResponse else { throw RegistryError(status: 502, description: "no HTTP response") }
        var headers: [String: String] = [:]
        for (k, v) in http.allHeaderFields { if let k = k as? String, let v = v as? String { headers[k] = v } }
        return RegistryResponse(status: http.statusCode, headers: headers)
    }

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
            note("ca-\(h)", "pratico: \(h)'s certificate is trusted through an extra CA, \"\(ca.subject)\" SHA-256 \(ca.sha256.prefix(16))… (registry_ca), not a system root")
            return (.useCredential, URLCredential(trust: trust))
        case .untrusted:
            return (.cancelAuthenticationChallenge, nil)
        }
    }

    /// The 3xx itself comes back: `RegistrySession.redirect` decides.
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? { nil }

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
}

#else

/// AsyncHTTPClient with BoringSSL: the system's CA bundle (unless `registry_system_roots =
/// false`) plus `registry_ca`, and `HTTPS_PROXY`/`HTTP_PROXY` unless `NO_PROXY` names the host.
final class HTTPClientTransport: RegistryTransport, @unchecked Sendable {
    private let client: HTTPClient
    static let deadline: TimeAmount = .hours(6)  // a large layer on a slow link

    init(policy: RegistryPolicy, host: String, env: [String: String] = ProcessInfo.processInfo.environment) {
        var tls = TLSConfiguration.makeClientConfiguration()
        tls.trustRoots = policy.systemRoots ? .default : .certificates([])
        if !policy.anchors.isEmpty { tls.additionalTrustRoots = [.certificates(policy.anchors)] }
        var configuration = HTTPClient.Configuration(tlsConfiguration: tls, redirectConfiguration: .disallow)
        configuration.timeout = .init(connect: .seconds(30), read: .seconds(300))
        configuration.proxy = Self.bypassesProxy(host, env) ? nil : Self.proxy(env)
        client = HTTPClient(eventLoopGroupProvider: .singleton, configuration: configuration)
    }

    func shutdown() { try? client.syncShutdown() }

    private static func proxy(_ env: [String: String]) -> HTTPClient.Configuration.Proxy? {
        func url(_ k: String) -> URL? { (env[k] ?? env[k.lowercased()]).flatMap { URL(string: $0) } }
        guard let p = url("HTTPS_PROXY") ?? url("HTTP_PROXY"), let h = p.host else { return nil }
        return .server(host: h, port: p.port ?? 3128)
    }

    /// `NO_PROXY` entries: exact hosts, `.suffix` or `suffix` domains, `*` for all.
    static func bypassesProxy(_ host: String, _ env: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        let h = RegistryPolicy.hostName(host).lowercased()
        for raw in (env["NO_PROXY"] ?? env["no_proxy"] ?? "").split(separator: ",") {
            let e = raw.trimmingCharacters(in: .whitespaces).lowercased()
            if e == "*" || e == h { return true }
            let suffix = e.hasPrefix(".") ? e : "." + e
            if !e.isEmpty, h.hasSuffix(suffix) { return true }
        }
        return false
    }

    private func request(_ r: RegistryRequest) -> HTTPClientRequest {
        var out = HTTPClientRequest(url: r.url.absoluteString)
        out.method = HTTPMethod(rawValue: r.httpMethod)
        out.headers.add(name: "User-Agent", value: "pratico/\(Pratico.version)")
        for (k, v) in r.headers { out.headers.replaceOrAdd(name: k, value: v) }
        return out
    }

    private static func head(_ r: HTTPClientResponse) -> RegistryResponse {
        var headers: [String: String] = [:]
        for (k, v) in r.headers where headers[k.lowercased()] == nil { headers[k.lowercased()] = v }
        return RegistryResponse(status: Int(r.status.code), headers: headers)
    }

    func send(_ r: RegistryRequest) async throws -> (RegistryResponse, RegistryBody) {
        let response = try await client.execute(request(r), timeout: Self.deadline)
        let body = RegistryBody { continuation in
            let task = Task {
                do {
                    for try await buf in response.body { continuation.yield(Data(buf.readableBytesView)) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return (Self.head(response), body)
    }

    func upload(_ r: RegistryRequest, file: URL) async throws -> RegistryResponse {
        var req = request(r)
        let size = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value ?? 0
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        // Read as the upload asks for it, never the whole blob in memory.
        let chunks = AsyncThrowingStream<ByteBuffer, any Error> {
            guard let data = try handle.read(upToCount: 1 << 16), !data.isEmpty else { return nil }
            return ByteBuffer(bytes: data)
        }
        req.body = .stream(chunks, length: .known(size))
        let response = try await client.execute(req, timeout: Self.deadline)
        for try await _ in response.body {}
        return Self.head(response)
    }

    func speaksTLS(_ url: URL) async -> Bool? {
        do {
            let response = try await client.execute(request(RegistryRequest(url: url)), timeout: .seconds(5))
            for try await _ in response.body {}
            return true
        } catch let e as NIOSSLError {
            // BoringSSL reads a plain-HTTP answer as a record of the wrong version.
            return "\(e)".contains("WRONG_VERSION_NUMBER") || "\(e)".contains("HTTP_REQUEST") ? false : true
        } catch let e as HTTPClientError where e == .connectTimeout || e == .deadlineExceeded || e == .remoteConnectionClosed {
            return nil
        } catch {
            return "\(error)".contains("WRONG_VERSION_NUMBER") ? false : nil
        }
    }
}

#endif
