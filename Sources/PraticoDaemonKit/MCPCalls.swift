import Foundation

/// The MCP tools' bodies (D-48), on the daemon's own services, not through the Docker API.
extension MCPTools {
    func status() -> JSON {
        let c = containers.counts
        return ["version": .string(DaemonInfo.version), "containers": .int(Int64(c.total)), "running": .int(Int64(c.running)),
                "scanners": scans.doctor()["scanners"] ?? []]
    }

    func imageCheck(_ args: JSON) throws -> JSON {
        let ref = try Self.required(args, "image")
        let img = (args["pull"]?.bool ?? true) ? try images.ensure(ref) : try Self.local(images, ref)
        if scans.report(img.id) == nil { scans.enqueue(img.id) }
        let wait = Self.bounded(args["wait_seconds"]?.int, default: 120, max: 600)
        let deadline = Date().addingTimeInterval(Double(wait))
        // A scan takes seconds to minutes: poll its state, bounded by the deadline.
        while scans.isScanning(img.id) && Date() < deadline { Thread.sleep(forTimeInterval: 0.5) }
        var out = scans.verdict(img, scanning: scans.isScanning(img.id))
        guard let r = scans.report(img.id) else {
            out["Note"] = .string(out["Scanning"] == .bool(true) ? "still scanning; ask again" : "no report: scanning is off or no scanner is installed")
            return .object(out)
        }
        let top = r.findings.sorted(by: Self.moreSerious).prefix(25)
        out["Counts"] = .object(Dictionary(grouping: r.findings, by: \.severity).mapValues { .int(Int64($0.count)) })
        out["KEV"] = .int(Int64(r.findings.filter(\.kev).count))
        out["Malware"] = .int(Int64(r.findings.filter(\.malicious).count))
        out["Scanners"] = JSON(r.scanners.filter(\.ran).map(\.name))
        out["Findings"] = .array(top.map(Self.finding))
        return .object(out)
    }

    func sbom(_ args: JSON) throws -> JSON {
        let img = try Self.local(images, try Self.required(args, "image"))
        guard let format = ScanService.SBOMFormat(rawValue: args["format"]?.string ?? "spdx") else { throw APIError(400, "format is spdx or cyclonedx") }
        let file = scans.sbomFile(img.id, format)
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size > 0, let data = try? Data(contentsOf: file) else {
            throw APIError(404, "no SBOM for \(img.displayName): install syft (brew install syft) and check the image again")
        }
        guard size <= 4 << 20, let json = JSON.parse(data) else {
            throw APIError(413, "the SBOM is \(size) bytes, too large to return here; export it from the menubar's Scan Results")
        }
        return json
    }

    func run(_ args: JSON) throws -> JSON {
        let timeout = Self.bounded(args["timeout_seconds"]?.int, default: 300, max: Self.maxTimeout)
        let rec = try create(args, autoRemove: false)
        defer { _ = try? containers.remove(rec.id, force: true, volumes: true) }
        let exit = containers.watchNextExit(rec.id)
        let started = Date()
        _ = try containers.start(rec.id)
        var code = exit.wait(seconds: Double(timeout))
        let timedOut = code == nil
        if timedOut {
            _ = try? containers.kill(rec.id, signal: "KILL")
            code = exit.wait(seconds: 10)
        }
        let lines = containers.logLines(rec.id)
        return ["exit_code": code.map { .int(Int64($0)) } ?? .null, "timed_out": .bool(timedOut),
                "seconds": .double((Date().timeIntervalSince(started) * 10).rounded() / 10),
                "stdout": .string(Self.tail(lines, stream: 1)), "stderr": .string(Self.tail(lines, stream: 2))]
    }

    func start(_ args: JSON) throws -> JSON {
        let rec = try create(args, autoRemove: false, name: args["name"]?.string, ports: args["ports"]?.strings ?? [])
        do { _ = try containers.start(rec.id) } catch {
            _ = try? containers.remove(rec.id, force: true, volumes: true)
            throw error
        }
        return ["id": .string(rec.id), "name": .string(rec.name)]
    }

    func exec(_ args: JSON) throws -> JSON {
        let rec = try owned(args)
        guard rec.state.running else { throw APIError(409, "\(rec.name) is not running") }
        guard let command = args["command"]?.strings, !command.isEmpty else { throw APIError(400, "command is required") }
        let timeout = Self.bounded(args["timeout_seconds"]?.int, default: 60, max: Self.maxTimeout)
        let body: JSON = ["args": JSON(command), "timeout": .int(Int64(timeout)), "limit": .int(Int64(2 * Self.outputBytes))]
        let r = try containers.embedded.shim.request(containers.shimFiles(rec.id), "POST", "/exec", body: body.encoded())
        let j = JSON.parse(r.body) ?? [:]
        guard r.status == 200 else { throw APIError(r.status, j["message"]?.string ?? "exec failed") }
        return ["exit_code": j["exitCode"] ?? .null, "output": .string(String((j["output"]?.string ?? "").suffix(Self.outputBytes)))]
    }

    func logs(_ args: JSON) throws -> JSON {
        let rec = try containers.resolve(try Self.required(args, "container"))
        let tail = Self.bounded(args["tail"]?.int, default: 200, max: 5000)
        let lines = containers.logLines(rec.id).suffix(tail)
        return ["lines": .array(lines.map { ["stream": .string($0.stream == 2 ? "stderr" : "stdout"), "text": .string(String(decoding: $0.data, as: UTF8.self))] })]
    }

    func list(_ args: JSON) -> JSON {
        let all = args["all"]?.bool ?? true
        return .array(containers.all().filter { all || $0.state.running }.map { rec in
            ["id": .string(rec.id), "name": .string(rec.name), "image": .string(rec.image), "state": .string(containers.dockerState(rec)),
             "status": .string(containers.statusText(rec)), "ports": .array(containers.ports(rec)), "mcp": .bool(rec.labels[Self.label] == "true")]
        })
    }

    func stop(_ args: JSON) throws -> JSON {
        let rec = try owned(args)
        return ["stopped": .bool(try containers.stop(rec.id, timeout: nil))]
    }

    func remove(_ args: JSON) throws -> JSON {
        let rec = try owned(args)
        try containers.remove(rec.id, force: true, volumes: true)
        return ["removed": .string(rec.id)]
    }

    // MARK: Helpers

    private static let severityRank = ["critical": 0, "high": 1, "medium": 2, "low": 3]

    /// Malware first, then exploited CVEs, then severity, then EPSS.
    private static func moreSerious(_ a: ScanFinding, _ b: ScanFinding) -> Bool {
        if a.malicious != b.malicious { return a.malicious }
        if a.kev != b.kev { return a.kev }
        let ra = severityRank[a.severity] ?? 4, rb = severityRank[b.severity] ?? 4
        if ra != rb { return ra < rb }
        return (a.epss ?? 0) > (b.epss ?? 0)
    }

    private static func finding(_ f: ScanFinding) -> JSON {
        var j: [String: JSON] = ["id": .string(f.id), "package": .string(f.package), "version": .string(f.version)]
        j["severity"] = .string(f.severity)
        j["fixed"] = JSON(f.fixed)
        j["kev"] = .bool(f.kev)
        j["malicious"] = .bool(f.malicious)
        j["epss"] = f.epss.map(JSON.double) ?? .null
        return .object(j)
    }

    /// A container from `run` or `start`, labeled as this server's; the scan gate and every
    /// run option apply as for `docker run`.
    private func create(_ args: JSON, autoRemove: Bool, name: String? = nil, ports: [String] = []) throws -> ContainerRecord {
        let ref = try Self.required(args, "image")
        _ = try images.ensure(ref)
        let network = args["network"]?.string ?? "none"
        var host: [String: JSON] = ["NetworkMode": .string(network), "AutoRemove": .bool(autoRemove)]
        host["Binds"] = JSON(try (args["mounts"]?.array ?? []).map(Self.bind))
        if let cpus = args["cpus"]?.double { host["NanoCpus"] = .int(Int64(cpus * 1e9)) }
        if let mib = args["memory_mib"]?.int { host["Memory"] = .int(mib * 1_048_576) }
        let (bindings, exposed) = try Self.portBindings(ports)
        if !bindings.isEmpty {
            guard network != "none" else { throw APIError(400, "published ports need a network: set network to bridge") }
            host["PortBindings"] = .object(bindings)
        }
        var body: [String: JSON] = ["Image": .string(ref), "HostConfig": .object(host), "Labels": [Self.label: "true"]]
        if let cmd = args["command"]?.strings, !cmd.isEmpty { body["Cmd"] = JSON(cmd) }
        if let env = args["env"]?.strings { body["Env"] = JSON(env) }
        if let dir = args["workdir"]?.string { body["WorkingDir"] = .string(dir) }
        if !exposed.isEmpty { body["ExposedPorts"] = .object(Dictionary(uniqueKeysWithValues: exposed.map { ($0, JSON.object([:])) })) }
        return try containers.create(name: name, body: .object(body))
    }

    /// `host:container[:ro]` from a mount object; read-only unless asked otherwise.
    private static func bind(_ m: JSON) throws -> String {
        guard let host = m["host"]?.string, host.hasPrefix("/"), let dest = m["container"]?.string, dest.hasPrefix("/") else {
            throw APIError(400, "a mount needs absolute host and container paths")
        }
        guard FileManager.default.fileExists(atPath: host) else { throw APIError(400, "no such folder on the Mac: \(host)") }
        return "\(host):\(dest)" + ((m["read_only"]?.bool ?? true) ? ":ro" : "")
    }

    /// Docker's `-p` forms: `80`, `8080:80`, `127.0.0.1:8080:80`, each with `/tcp` or `/udp`.
    static func portBindings(_ specs: [String]) throws -> (bindings: [String: JSON], exposed: [String]) {
        var bindings: [String: [JSON]] = [:]
        for spec in specs {
            let (addr, proto) = spec.splitOnce("/")
            let parts = addr.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            guard (1...3).contains(parts.count), let container = UInt16(parts.last!), container > 0,
                ["tcp", "udp"].contains(proto ?? "tcp")
            else { throw APIError(400, "invalid port \(spec)") }
            let ip = parts.count == 3 ? parts[0] : ""
            let hostPort = parts.count >= 2 ? parts[parts.count - 2] : ""
            guard hostPort.isEmpty || UInt16(hostPort) != nil else { throw APIError(400, "invalid port \(spec)") }
            bindings["\(container)/\(proto ?? "tcp")", default: []].append(["HostIp": .string(ip), "HostPort": .string(hostPort)])
        }
        return (bindings.mapValues(JSON.array), Array(bindings.keys))
    }

    /// A container this server made: changes to the user's own are refused.
    private func owned(_ args: JSON) throws -> ContainerRecord {
        let rec = try containers.resolve(try Self.required(args, "container"))
        guard rec.labels[Self.label] == "true" else {
            throw APIError(403, "\(rec.name) was not made through pratico's MCP server; agents may read it, not change it")
        }
        return rec
    }

    private static func required(_ args: JSON, _ key: String) throws -> String {
        guard let v = args[key]?.string, !v.isEmpty else { throw APIError(400, "\(key) is required") }
        return v
    }

    private static func local(_ images: ImageService, _ ref: String) throws -> LocalImage {
        guard let img = images.resolve(ref)?.image else { throw APIError(404, "No such image: \(ref)") }
        return img
    }

    private static func bounded(_ v: Int64?, default d: Int, max m: Int) -> Int { min(max(Int(v ?? Int64(d)), 1), m) }

    /// The last `outputBytes` of one stream, as text.
    private static func tail(_ lines: [LogLine], stream: UInt8) -> String {
        var data = Data()
        for l in lines where l.stream == stream { data.append(l.data) }
        return String(decoding: data.suffix(outputBytes), as: UTF8.self)
    }
}
