import Foundation

/// How a container's run options become its VM's (D-45): what the daemon resolves before
/// the shim starts, from the record and what is running now.
extension ContainerService {
    /// The record's options, as `create` checked them.
    func runOptions(_ rec: ContainerRecord) throws -> RunOptions {
        try RunOptions.parse(host: rec.hostConfig, config: rec.config, defaultCPUs: config.defaultCPUs, defaultMemoryMiB: config.defaultMemoryMiB)
    }

    /// `-P`: every exposed port without a binding gets one on a free host port.
    static func publishingAll(_ host: JSON, exposed: JSON?) throws -> JSON {
        guard host["PublishAllPorts"]?.bool == true, var fields = host.object else { return host }
        var bindings = host["PortBindings"]?.object ?? [:]
        for port in (exposed?.object ?? [:]).keys where bindings[port] == nil {
            bindings[port] = [["HostIp": "", "HostPort": ""]]
        }
        fields["PortBindings"] = .object(bindings)
        return .object(fields)
    }

    struct Link: Equatable {
        var target: String
        var alias: String
    }

    /// `--link target[:alias]`, from `HostConfig.Links` (`/target:/self/alias` or
    /// `target:alias`) and from each endpoint's.
    static func links(_ host: JSON, _ endpoints: [Endpoint]) throws -> [Link] {
        try ((host["Links"]?.strings ?? []) + endpoints.flatMap { $0.links ?? [] }).map { raw in
            let (target, alias) = raw.splitOnce(":")
            let t = target.hasPrefix("/") ? String(target.dropFirst()) : target
            let a = alias.map { $0.split(separator: "/").last.map(String.init) ?? $0 } ?? t
            guard !t.isEmpty, !a.isEmpty else { throw APIError(400, "invalid link: \(raw)") }
            return Link(target: t, alias: a)
        }
    }

    /// What the shim needs beyond the record: `host-gateway`, links, and group names
    /// resolved against what runs now and against the image's `/etc/group`.
    func resolved(_ options: RunOptions, _ rec: ContainerRecord, nics: NICSlots, rootfs: URL) throws -> RunOptions {
        var o = options
        let gateway = nics.primaryNIC?.gateway
        o.extraHosts = try o.extraHosts.map { e in
            guard e.address == "host-gateway" else { return e }
            guard let gateway else { throw APIError(400, "pratico: --add-host \(e.name):host-gateway needs a network") }
            return .init(name: e.name, address: gateway)
        }
        let mine = Set(networks.active(rec).keys)
        for link in try Self.links(rec.hostConfig, Array(networks.active(rec).values)) {
            let target = try resolve(link.target)
            guard target.state.running else {
                throw APIError(400, "Cannot link to a non running container: /\(target.name) AS /\(rec.name)/\(link.alias)")
            }
            guard let shared = networks.active(target).keys.first(where: mine.contains),
                let net = try? networks.resolve(shared), let ip = networks.address(target.id, on: net)?.ip
            else { throw APIError(400, "pratico: --link \(link.target) needs a network the two containers share") }
            o.extraHosts.append(.init(name: link.alias, address: ip))
            if link.alias != target.name { o.extraHosts.append(.init(name: target.name, address: ip)) }
        }
        let named = o.groups.filter { UInt32($0) == nil }
        if !named.isEmpty {
            let table = CopyUp.read(rootfs: rootfs, path: "/etc/group").map { String(decoding: $0, as: UTF8.self) } ?? ""
            var gids: [String: String] = [:]
            for line in table.split(separator: "\n") {
                let f = line.split(separator: ":", omittingEmptySubsequences: false)
                if f.count >= 3 { gids[String(f[0])] = String(f[2]) }
            }
            o.groups = try o.groups.map { g in
                if UInt32(g) != nil { return g }
                guard let gid = gids[g] else { throw APIError(400, "Unable to find group \(g): no matching entries in group file") }
                return gid
            }
        }
        return o
    }
}
