import Foundation

/// What Docker clients read about containers: `ps`, `inspect`, status text, ports.
extension ContainerService {
    func dockerState(_ rec: ContainerRecord) -> String {
        rec.state.running && isPaused(rec.id) ? "paused" : rec.state.status
    }

    func statusText(_ rec: ContainerRecord) -> String {
        switch rec.state.status {
        case "running":
            var suffix = ""
            if isPaused(rec.id) {
                suffix = " (Paused)"
            } else if let h = health.state(rec.id) {
                suffix = h.status == "starting" ? " (health: starting)" : " (\(h.status))"
            }
            return "Up \(Timestamp.human(since: rec.state.startedAt))\(suffix)"
        case "exited": return "Exited (\(rec.state.exitCode)) \(Timestamp.human(since: rec.state.finishedAt)) ago"
        default: return "Created"
        }
    }

    /// Bound host ports (`-p 80` gets a free port), else the request.
    private func bindings(_ rec: ContainerRecord) -> [String: JSON] {
        guard let bound = boundPorts(rec.id), rec.state.running else { return rec.hostConfig["PortBindings"]?.object ?? [:] }
        return bound.mapValues { list in .array(list.map { ["HostIp": .string($0.ip), "HostPort": .string($0.port)] }) }
    }

    func ports(_ rec: ContainerRecord) -> [JSON] {
        var out: [JSON] = []
        for (port, list) in bindings(rec).sorted(by: { $0.key < $1.key }) {
            let (num, proto) = port.splitOnce("/")
            for b in list.array ?? [] {
                let hp = b["HostPort"]?.string.flatMap { Int64($0) } ?? Int64(num) ?? 0
                out.append(["IP": .string(b["HostIp"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? "0.0.0.0"),
                            "PrivatePort": .int(Int64(num) ?? 0), "PublicPort": .int(hp),
                            "Type": .string(proto ?? "tcp")])
            }
        }
        return out
    }

    func summary(_ rec: ContainerRecord) -> JSON {
        [
            "Id": .string(rec.id),
            "Names": [.string("/\(rec.name)")],
            "Image": .string(rec.image),
            "ImageID": .string(rec.imageId),
            "Command": .string(([rec.path] + rec.args).joined(separator: " ")),
            "Created": .int(Int64(rec.created.timeIntervalSince1970)),
            "Ports": .array(ports(rec)),
            "Labels": JSON(rec.labels),
            "State": .string(dockerState(rec)),
            "Status": .string(statusText(rec)),
            "HostConfig": ["NetworkMode": rec.hostConfig["NetworkMode"] ?? "bridge"],
            "NetworkSettings": ["Networks": networks.containerNetworks(rec)],
            "Mounts": mountsJSON(rec),
        ]
    }

    func inspect(_ rec: ContainerRecord) -> JSON {
        let s = rec.state
        var portMap: [String: JSON] = [:]
        for (port, list) in bindings(rec) { portMap[port] = list }
        // Docker's top-level address fields describe the default bridge only.
        let bridge = s.running && networks.active(rec)[networks.bridge.id] != nil
            ? networks.address(rec.id, on: networks.bridge) : nil
        return [
            "Id": .string(rec.id),
            "Created": .string(Timestamp.format(rec.created)),
            "Path": .string(rec.path),
            "Args": JSON(rec.args),
            "State": [
                "Status": .string(dockerState(rec)),
                "Running": .bool(s.running),
                "Paused": .bool(s.running && isPaused(rec.id)),
                "Restarting": .bool(restarts.isPending(rec.id)),
                "OOMKilled": false,
                "Dead": false,
                "Pid": 0,
                "ExitCode": .int(Int64(s.exitCode)),
                "Error": .string(s.error),
                "StartedAt": .string(Timestamp.format(s.startedAt)),
                "FinishedAt": .string(Timestamp.format(s.finishedAt)),
                "Health": health.state(rec.id)?.json ?? .null,
            ],
            "Image": .string(rec.imageId),
            "Name": .string("/\(rec.name)"),
            "RestartCount": .int(Int64(rec.state.restartCount ?? 0)),
            "Driver": "pratico",
            "Platform": "linux",
            "HostConfig": rec.hostConfig,
            "Config": rec.config,
            "Mounts": mountsJSON(rec),
            "NetworkSettings": [
                "IPAddress": .string(bridge?.ip ?? ""),
                "IPPrefixLen": .int(Int64(bridge?.prefix ?? 0)),
                "Gateway": .string(bridge?.gateway ?? ""),
                "MacAddress": .string(bridge?.mac ?? ""),
                "Ports": .object(portMap),
                "Networks": networks.containerNetworks(rec),
            ],
        ]
    }

    /// Docker `filters` query: `{"label":{"a=1":true}}` or the older `{"label":["a=1"]}`.
    static func parseFilters(_ raw: String?) -> [String: [String]] {
        guard let raw, let json = JSON.parse(Data(raw.utf8))?.object else { return [:] }
        return json.mapValues { v in v.object.map { Array($0.keys) } ?? v.strings ?? [] }
    }

    func list(all: Bool, filters: [String: [String]]) -> [JSON] {
        self.all().filter { rec in
            if !all && !rec.state.running && filters["status"] == nil { return false }
            return Filters.pass(filters, labels: rec.labels) { key, v in
                    switch key {
                    case "name": return rec.name.contains(v.hasPrefix("/") ? String(v.dropFirst()) : v)
                    case "id": return rec.id.hasPrefix(v)
                    case "status": return dockerState(rec) == v
                    case "health": return (health.state(rec.id)?.status ?? "none") == v
                    case "ancestor": return ImageRef.normalize(rec.image) == ImageRef.normalize(v)
                    case "network":
                        return networks.active(rec).keys.contains { id in
                            id.hasPrefix(v) || (try? networks.resolve(id))?.name == v
                        }
                    default: return true
                    }
                }
        }.map(summary)
    }

    public var counts: (total: Int, running: Int, paused: Int) {
        let a = all()
        let paused = a.filter { $0.state.running && isPaused($0.id) }.count
        return (a.count, a.filter(\.state.running).count - paused, paused)
    }
}
