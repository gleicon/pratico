import Foundation
import PraticoCore

/// pratico's own endpoints under `/pratico/`, beside the Docker API on the same socket:
/// what the menubar reads and acts on. Each is listed in `examples/README.md`.
extension Daemon {
    func routePratico(_ m: String, _ p: [String], _ req: Request, _ conn: Connection) throws -> Disposition? {
        switch (m, p.count, p.first) {
        case ("GET", 1, "status"):
            let c = containers.counts
            conn.json(200, [
                "Version": .string(Pratico.version), "Pid": .int(Int64(getpid())), "StartedAt": .string(startedAt.ISO8601Format()),
                "Socket": .string(socketPath), "Containers": .int(Int64(c.total)), "ContainersRunning": .int(Int64(c.running)),
                "Changes": .int(Int64(events.generation)),
            ])
        case ("GET", 1, "containers"):
            conn.json(200, runningContainers())
        case ("GET", 1, "disk"):
            conn.json(200, disk.usage())
        case ("DELETE", 1, "alerts"):
            alerts.clear()
            conn.respond(204)
        case ("GET", 1, "registries"):
            conn.json(200, registries.state)
        case ("DELETE", 3, "registries") where p[1] == "logins":
            try registries.logout(p[2].removingPercentEncoding ?? p[2])
            conn.respond(204)
        case ("GET", 1, "scanners"):
            conn.json(200, scans.doctor())
        case ("GET", 1, "scans"):
            conn.json(200, scans.results())
        case ("POST", 1, "scans"):
            conn.json(202, scans.rescanAll())
        case ("GET", 2, "scans") where p[1] == "summary":
            conn.json(200, scans.summary())
        case ("GET", 3, "scans") where p[2] == "sbom":
            try sbom(p[1], format: req.query["format"] ?? "spdx", conn)
        case ("POST", 3, "scans") where p[2] == "allow":
            try scans.allow(p[1])
            conn.respond(204)
        case ("POST", 1, "snapshots"):
            conn.json(201, try snapshots.take())
        case ("GET", 1, "snapshots"):
            conn.json(200, snapshots.list())
        case ("POST", 2, "snapshots") where p[1] == "restore":
            guard let path = req.query["path"], !path.isEmpty else { throw APIError(400, "path is required") }
            conn.json(200, try snapshots.restore(path: path, dryRun: req.flag("dry_run"), start: req.flag("start")))
        default:
            return nil
        }
        return .keepAlive
    }

    private func sbom(_ ref: String, format raw: String, _ conn: Connection) throws {
        guard let img = images.resolve(ref)?.image else { throw APIError(404, "No such image: \(ref)") }
        guard let format = ScanService.SBOMFormat(rawValue: raw) else { throw APIError(400, "format is spdx or cyclonedx") }
        guard let data = try? Data(contentsOf: scans.sbomFile(img.id, format)) else {
            throw APIError(404, "no SBOM for \(img.displayName): install syft (brew install syft) and scan it again")
        }
        conn.respond(200, body: data, contentType: "application/json")
    }

    /// `GET /pratico/containers`: the menubar's list of running containers (FR-31, FR-40),
    /// with ports, health, and usage, in one call.
    func runningContainers() -> JSON {
        .array(containers.all().filter(\.state.running).map { rec in
            let use = stats.usage(rec.id)
            return [
                "Id": .string(rec.id), "Name": .string(rec.name), "Image": .string(ImageRef.familiar(ImageRef.normalize(rec.image))),
                "StartedAt": .string(rec.state.startedAt?.ISO8601Format() ?? ""),
                "Paused": .bool(containers.isPaused(rec.id)),
                "Health": containers.health.state(rec.id).map { .string($0.status) } ?? .null,
                "Ports": .array(containers.ports(rec).map { p in
                    ["IP": p["IP"] ?? "", "PublicPort": p["PublicPort"] ?? 0, "PrivatePort": p["PrivatePort"] ?? 0, "Type": p["Type"] ?? "tcp"]
                }),
                "CPU": .double(use?.cpu ?? 0), "Memory": .int(use?.memory ?? 0),
            ]
        })
    }

}
