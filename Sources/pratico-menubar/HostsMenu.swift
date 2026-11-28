import PraticoCore
import SwiftUI

/// The docker CLI's contexts as pratico's hosts (docs/design/remote.md): picking one is
/// `docker context use`, so the docker CLI, Compose, and tools that read contexts go to that
/// host. Hosts are added with `docker context create name --docker host=ssh://user@host`.
/// Each Linux host has its own submenu: its state, the key pratico signs in with, and what
/// fixes a problem.
struct HostsMenu: View {
    let daemon: DaemonController

    var body: some View {
        Menu("Docker Host: \(daemon.currentContext)") {
            ForEach(daemon.contexts) { context in
                Toggle(isOn: Binding(get: { daemon.currentContext == context.name },
                                     set: { if $0 { daemon.useContext(context.name) } })) {
                    Text(context.name)
                    Text(Self.where(context))
                    if let r = daemon.remote[context.name] { Text(r.problem == nil ? r.line : "⚠︎ \(r.line)") }
                }
            }
            let linux = daemon.contexts.filter { $0.sshTarget != nil }
            if !linux.isEmpty {
                Section("Linux Hosts") {
                    ForEach(linux) { context in
                        if let endpoint = context.sshTarget { host(context.name, endpoint: endpoint) }
                    }
                }
            }
            Divider()
            Button("Refresh Linux Hosts") { Task { await daemon.refreshRemote() } }
            Text("A shell with DOCKER_HOST or DOCKER_CONTEXT set goes there instead.")
            Button("Add a Linux Host…") { daemon.showAddHost() }
        }
    }

    @ViewBuilder private func host(_ name: String, endpoint: String) -> some View {
        Menu(name) {
            Text("ssh://\(endpoint)")
            if let r = daemon.remote[name] {
                Text(r.line)
                if let problem = r.problem {
                    Button(problem.action) { daemon.explain(r, context: name, endpoint: endpoint) }
                }
            } else {
                Text("Checking…")
            }
            Divider()
            if let key = daemon.chosenKey(for: name) {
                Text("Signs in with \(key)")
                Button("Choose Another SSH Key…") { daemon.chooseKey(for: name) }
                Button("Use the Keys ~/.ssh/config Gives…") { daemon.forgetKey(for: name) }
            } else {
                Text("Signs in with the keys ~/.ssh/config gives")
                Button("Choose SSH Key…") { daemon.chooseKey(for: name) }
            }
        }
    }

    static func `where`(_ c: DockerContexts.Context) -> String {
        if c.name == DockerContexts.defaultName { return "DOCKER_HOST, else /var/run/docker.sock" }
        if let target = c.sshTarget { return "ssh://\(target)" }
        if c.host == "unix://\(Pratico.socketPath().path)" { return "pratico on this Mac" }
        return c.host ?? "no docker endpoint"
    }
}
