import Foundation

/// `docker network connect` and `disconnect` (D-27).
extension ContainerService {
    /// `POST /networks/{id}/connect`. A running container gets the network on a spare NIC
    /// slot at once; a stopped one gets it planned for its next start.
    func connect(_ ref: String, to net: NetworkRecord, aliases: [String]) throws {
        membership.lock()
        defer { membership.unlock() }
        let rec = try resolve(ref)
        var eps = networks.endpoints(rec)
        guard eps[net.id] == nil || eps[net.id]?.detached == true else {
            throw APIError(403, "endpoint with name \(rec.name) already exists in network \(net.name)")
        }
        if net.name == "none" || networks.active(rec).keys.contains(where: { (try? networks.resolve($0))?.name == "none" }) {
            throw APIError(400, "container cannot be connected to network none and other networks")
        }
        if rec.state.running { try hotConnect(rec, net) }
        eps[net.id] = Endpoint(aliases: aliases)
        update(rec.id) { $0.endpoints = eps }
        networks.emit(net, "connect", container: rec.id)
    }

    /// `POST /networks/{id}/disconnect`: traffic is cut at the switch at once.
    func disconnect(_ ref: String, from net: NetworkRecord) throws {
        membership.lock()
        defer { membership.unlock() }
        let rec = try resolve(ref)
        var eps = networks.endpoints(rec)
        guard eps[net.id] != nil else { throw APIError(403, "container \(rec.id) is not connected to network \(net.name)") }
        if rec.state.running { hotDisconnect(rec, net) }
        eps[net.id] = nil
        update(rec.id) { $0.endpoints = eps }
        networks.emit(net, "disconnect", container: rec.id)
    }

    /// Brings a spare NIC slot of the running VM up on `net`; see `NetworkService.hotConnect`.
    private func hotConnect(_ rec: ContainerRecord, _ net: NetworkRecord) throws {
        guard !isPaused(rec.id) else { throw APIError(409, "Container \(rec.id) is paused, unpause the container before connecting it") }
        let files = shimFiles(rec.id)
        try networks.hotConnect(rec, net) { [embedded] change in
            _ = try embedded.shim.request(files, "POST", "/nic", body: JSONEncoder().encode(change))
        }
        saveNICs(rec, files)
    }

    /// Cuts the NIC at the switch, then brings the guest's side down; see
    /// `NetworkService.hotDisconnect`.
    private func hotDisconnect(_ rec: ContainerRecord, _ net: NetworkRecord) {
        let files = shimFiles(rec.id)
        networks.hotDisconnect(rec, net) { [embedded] change in
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
}
