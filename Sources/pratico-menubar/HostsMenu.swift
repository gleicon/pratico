import PraticoCore
import SwiftUI

/// The docker CLI's contexts as pratico's hosts (docs/design/remote.md): picking one is
/// `docker context use`, so the docker CLI, Compose, and tools that read contexts go to that
/// host. Hosts are added with `docker context create name --docker host=ssh://user@host`.
struct HostsMenu: View {
    let daemon: DaemonController

    var body: some View {
        Menu("Docker Host: \(daemon.currentContext)") {
            ForEach(daemon.contexts) { context in
                Toggle(isOn: Binding(get: { daemon.currentContext == context.name },
                                     set: { if $0 { daemon.useContext(context.name) } })) {
                    Text(context.name)
                    Text(Self.where(context))
                }
            }
            Divider()
            Text("A shell with DOCKER_HOST or DOCKER_CONTEXT set goes there instead.")
            Button("Add a Linux Host…") { daemon.showAddHost() }
        }
    }

    static func `where`(_ c: DockerContexts.Context) -> String {
        if c.name == DockerContexts.defaultName { return "DOCKER_HOST, else /var/run/docker.sock" }
        if let target = c.sshTarget { return "ssh://\(target)" }
        if c.host == "unix://\(Pratico.socketPath().path)" { return "pratico on this Mac" }
        return c.host ?? "no docker endpoint"
    }
}
