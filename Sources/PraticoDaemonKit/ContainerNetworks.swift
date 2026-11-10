import Foundation

/// `docker network connect` and `disconnect` (D-25, D-27).
extension ContainerService {
    /// `POST /networks/{id}/connect`. Apple fixes a container's networks at create, so a
    /// container that never ran is recreated on the new set; one that has run can only
    /// rejoin a network it was disconnected from, whose interface it still has (D-25).
    func connect(_ ref: String, to net: NetworkRecord, aliases: [String]) throws {
        membership.lock()
        defer { membership.unlock() }
        let rec = try resolve(ref)
        var eps = networks.endpoints(rec)
        if let embedded {
            guard eps[net.id] == nil || eps[net.id]?.detached == true else {
                throw APIError(403, "endpoint with name \(rec.name) already exists in network \(net.name)")
            }
            if net.name == "none" || networks.active(rec).keys.contains(where: { (try? networks.resolve($0))?.name == "none" }) {
                throw APIError(400, "container cannot be connected to network none and other networks")
            }
            // A stopped container gets the network planned at its next start.
            if rec.state.running { try hotConnect(rec, net, embedded) }
            eps[net.id] = Endpoint(aliases: aliases)
            update(rec.id) { $0.endpoints = eps }
            networks.emit(net, "connect", container: rec.id)
            return
        }
        if let ep = eps[net.id], !ep.detached {
            throw APIError(403, "endpoint with name \(rec.name) already exists in network \(net.name)")
        }
        let onNone = networks.active(rec).keys.contains { (try? networks.resolve($0))?.name == "none" }
        if net.name == "none" || onNone {
            throw APIError(400, "container cannot be connected to network none and other networks")
        }
        if let ep = eps[net.id] {
            eps[net.id] = Endpoint(aliases: aliases.isEmpty ? ep.aliases : aliases)
            update(rec.id) { $0.endpoints = eps }
        } else if rec.state.startedAt == nil {
            eps[net.id] = Endpoint(aliases: aliases)
            try recreate(rec, eps)
        } else {
            throw APIError(409, "pratico: cannot connect \(rec.name) to \(net.name): the Apple runtime fixes a container's networks when it is created, and this container has already run; recreate it with --network \(net.name)")
        }
        networks.emit(net, "connect", container: rec.id)
        networks.sync([net.id], wait: true)
    }

    /// `POST /networks/{id}/disconnect`. A container that has run keeps its interface
    /// (the guest cannot bring it down), but leaves Docker's view and name resolution.
    func disconnect(_ ref: String, from net: NetworkRecord) throws {
        membership.lock()
        defer { membership.unlock() }
        let rec = try resolve(ref)
        var eps = networks.endpoints(rec)
        if let embedded {
            guard eps[net.id] != nil else { throw APIError(403, "container \(rec.id) is not connected to network \(net.name)") }
            if rec.state.running { hotDisconnect(rec, net, embedded) }
            eps[net.id] = nil
            update(rec.id) { $0.endpoints = eps }
            networks.emit(net, "disconnect", container: rec.id)
            return
        }
        guard let ep = eps[net.id], !ep.detached else {
            throw APIError(403, "container \(rec.id) is not connected to network \(net.name)")
        }
        if rec.state.startedAt == nil {
            eps[net.id] = nil
            try recreate(rec, eps)
        } else {
            eps[net.id] = Endpoint(aliases: ep.aliases, detached: true)
            update(rec.id) { $0.endpoints = eps }
        }
        networks.emit(net, "disconnect", container: rec.id)
        networks.sync([net.id], wait: true)
    }

    /// Brings a spare NIC slot of the running VM up on `net`; see `NetworkService.hotConnect`.
    private func hotConnect(_ rec: ContainerRecord, _ net: NetworkRecord, _ embedded: EmbeddedContainers) throws {
        guard !isPaused(rec.id) else { throw APIError(409, "Container \(rec.id) is paused, unpause the container before connecting it") }
        let files = shimFiles(rec.id)
        try networks.hotConnect(rec, net) { change in
            _ = try embedded.shim.request(files, "POST", "/nic", body: JSONEncoder().encode(change))
        }
        saveNICs(rec, files)
    }

    /// Cuts the NIC at the switch, then brings the guest's side down; see
    /// `NetworkService.hotDisconnect`.
    private func hotDisconnect(_ rec: ContainerRecord, _ net: NetworkRecord, _ embedded: EmbeddedContainers) {
        let files = shimFiles(rec.id)
        networks.hotDisconnect(rec, net) { change in
            _ = try? embedded.shim.request(files, "POST", "/nic", body: (try? JSONEncoder().encode(change)) ?? Data())
        }
        saveNICs(rec, files)
    }

    /// The spec records the slots, so a restarted daemon re-registers what is plugged now.
    private func saveNICs(_ rec: ContainerRecord, _ files: ShimFiles) {
        guard let data = try? Data(contentsOf: files.spec), var spec = try? JSONDecoder().decode(ShimSpec.self, from: data) else { return }
        spec.nics = networks.nics(rec.id)
        try? JSONEncoder().encode(spec).write(to: files.spec, options: .atomic)
    }

    /// Replaces a never-started Apple container with one on other networks. Nothing is
    /// lost: its filesystem is still the image's.
    private func recreate(_ rec: ContainerRecord, _ eps: [String: Endpoint]) throws {
        guard let base = rec.createArgs else {
            throw APIError(409, "pratico: container \(rec.name) predates network support; recreate it")
        }
        _ = runtime.run(["delete", "--force", rec.appleId])
        let r = runtime.run(Self.withNetworks(base, appleNetworks(rec, eps)))
        guard r.ok else {
            _ = runtime.run(Self.withNetworks(base, appleNetworks(rec, networks.endpoints(rec))))
            throw APIError(500, "cannot change the networks of \(rec.name): \(r.errorText)")
        }
        update(rec.id) { $0.endpoints = eps }
    }

    /// Apple network names, `NetworkMode` first; no networks at all means Apple's `none`.
    private func appleNetworks(_ rec: ContainerRecord, _ eps: [String: Endpoint]) -> [String] {
        let nets = eps.keys.compactMap { try? networks.resolve($0) }
        guard !nets.isEmpty else { return ["none"] }
        let mode = rec.hostConfig["NetworkMode"]?.string ?? ""
        func primary(_ n: NetworkRecord) -> Bool { n.name == mode || n.id == mode }
        return nets.sorted { primary($0) != primary($1) ? primary($0) : $0.name < $1.name }.map(\.appleName)
    }
}
