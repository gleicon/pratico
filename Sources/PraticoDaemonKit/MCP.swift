import Foundation
import PraticoCore

/// pratico for agents (D-48): a Model Context Protocol server, Streamable HTTP without
/// streams, on 127.0.0.1 only. Whoever holds the token controls containers as the
/// Docker socket does, so every request must carry it, and a request a browser could
/// forge (another Host, a foreign Origin) is refused before the token is looked at.
final class MCPServer: @unchecked Sendable {
    let port: UInt16
    private let token: String
    private let tools: MCPTools
    private var server: HTTPServer?

    static let protocolVersions = ["2025-11-25", "2025-06-18", "2025-03-26"]
    static let maxBody = 1 << 20

    init(port: UInt16, token: String, tools: MCPTools) {
        precondition(token.count >= 32, "an MCP token too short to be secret")
        self.port = port
        self.token = token
        self.tools = tools
    }

    func start() throws {
        let s = HTTPServer(loopbackPort: port) { [self] req, conn in handle(req, conn) }
        try s.start()
        server = s
    }

    func stop() { server?.stop() }

    /// `~/.pratico/mcp-token`: made once, readable by the user only.
    static func token(home: URL) throws -> String {
        let file = home.appending(path: "mcp-token")
        if let t = try? String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), t.count >= 32 {
            return t
        }
        let t = randomHexID()
        precondition(t.count == 64, "a token of 32 random bytes")
        try Data(t.utf8).write(to: file, options: [.atomic])
        chmod(file.path, 0o600)
        return t
    }

    private func handle(_ req: Request, _ conn: Connection) -> Disposition {
        if let refusal = refusal(req) {
            conn.error(refusal.status, refusal.message)
            return .close
        }
        guard req.method == "POST" else {
            conn.error(405, "the MCP endpoint takes POST; it opens no event stream")
            return .close
        }
        guard req.body.count <= Self.maxBody, let message = JSON.parse(req.body), message.object != nil else {
            conn.json(400, Self.failure(.null, -32700, "not a JSON-RPC message"))
            return .close
        }
        guard let method = message["method"]?.string else {
            conn.json(400, Self.failure(message["id"] ?? .null, -32600, "no method"))
            return .close
        }
        guard let id = message["id"], id != .null else {
            conn.respond(202)  // a notification: nothing to answer
            return .keepAlive
        }
        conn.json(200, dispatch(method, id: id, params: message["params"] ?? [:]))
        return .keepAlive
    }

    /// Checks that hold before anything is read: path, Host, Origin, version, token.
    private func refusal(_ req: Request) -> APIError? {
        guard req.path == "/mcp" else { return APIError(404, "the MCP endpoint is /mcp") }
        let hosts = ["127.0.0.1:\(port)", "localhost:\(port)"]
        guard let host = req.headers["host"], hosts.contains(host.lowercased()) else {
            return APIError(403, "pratico answers MCP for 127.0.0.1 only")
        }
        if let origin = req.headers["origin"], !hosts.map({ "http://" + $0 }).contains(origin.lowercased()) {
            return APIError(403, "requests from web pages are refused")
        }
        if let v = req.headers["mcp-protocol-version"], !Self.protocolVersions.contains(v) {
            return APIError(400, "unsupported MCP protocol version \(v)")
        }
        let given = req.headers["authorization"].map { $0.hasPrefix("Bearer ") ? String($0.dropFirst(7)) : "" } ?? ""
        guard Self.same(given, token) else { return APIError(401, "a bearer token is required (~/.pratico/mcp-token)") }
        return nil
    }

    /// Compares in time that does not depend on where the strings differ.
    static func same(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        return zip(x, y).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    private func dispatch(_ method: String, id: JSON, params: JSON) -> JSON {
        switch method {
        case "initialize":
            let asked = params["protocolVersion"]?.string ?? ""
            return Self.success(id, [
                "protocolVersion": .string(Self.protocolVersions.contains(asked) ? asked : Self.protocolVersions[0]),
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "pratico", "version": .string(Pratico.version)],
                "instructions": .string(MCPTools.instructions),
            ])
        case "ping":
            return Self.success(id, [:])
        case "tools/list":
            return Self.success(id, ["tools": .array(MCPTools.catalog)])
        case "tools/call":
            guard let name = params["name"]?.string else { return Self.failure(id, -32602, "tools/call needs a name") }
            guard MCPTools.catalog.contains(where: { $0["name"]?.string == name }) else {
                return Self.failure(id, -32602, "no tool \(name)")
            }
            do {
                let result = try tools.call(name, params["arguments"] ?? [:])
                return Self.success(id, ["content": [["type": "text", "text": .string(String(decoding: result.encoded(), as: UTF8.self))]],
                                         "structuredContent": result, "isError": false])
            } catch let e as APIError {
                return Self.success(id, ["content": [["type": "text", "text": .string(e.message)]], "isError": true])
            } catch {
                return Self.success(id, ["content": [["type": "text", "text": .string("\(error)")]], "isError": true])
            }
        default:
            return Self.failure(id, -32601, "no method \(method)")
        }
    }

    static func success(_ id: JSON, _ result: JSON) -> JSON { ["jsonrpc": "2.0", "id": id, "result": result] }

    static func failure(_ id: JSON, _ code: Int, _ message: String) -> JSON {
        ["jsonrpc": "2.0", "id": id, "error": ["code": .int(Int64(code)), "message": .string(message)]]
    }
}
