import PraticoCore
import SwiftUI

@main
struct PraticoMenubarApp: App {
    @State private var daemon = DaemonController()

    var body: some Scene {
        MenuBarExtra {
            StatusMenu(daemon: daemon)
        } label: {
            Image(systemName: daemon.hasUnseenSerious ? "exclamationmark.shield.fill"
                  : daemon.isRunning ? "shippingbox.fill" : "shippingbox")
        }
    }
}

struct StatusMenu: View {
    let daemon: DaemonController

    var body: some View {
        // FR-5: state, socket path, API version.
        Text(statusLine)
        if let v = daemon.apiVersion {
            Text("Docker API \(v)")
            Text(daemon.socketPath)
        }
        if let error = daemon.error {
            Text("⚠︎ \(error)")
        }
        if daemon.needsApproval {
            Button("Open Login Items…") { daemon.openLoginItems() }
        }
        Toggle("Use \(DefaultSocket.path)", isOn: Binding(get: { daemon.usesDefaultSocket }, set: { daemon.setUseDefaultSocket($0) }))
        if let note = defaultSocketNote {
            Text(note)
        }
        // D-24: image scan alerts, newest first.
        if !daemon.alerts.isEmpty {
            Divider()
            Text("Image scan alerts")
            ForEach(daemon.alerts.suffix(5).reversed()) { a in
                Button((a.level == "serious" ? "⛔︎ " : "⚠︎ ") + a.title) {}
                    .help(a.detail)
            }
            Button("Clear Alerts") { daemon.clearAlerts() }
        }
        // D-29: trust beyond the system's roots, and kept logins, in plain view.
        if daemon.isRunning {
            Divider()
            Menu(daemon.registries.warnings.isEmpty ? "Registries" : "Registries ⚠︎") {
                Text(daemon.registries.policy.systemRoots ? "HTTPS, verified by the system's trusted roots" : "HTTPS, verified only by registry_ca")
                Text(daemon.registries.policy.httpLoopback ? "Loopback registries may use plain HTTP (as Docker)" : "Plain HTTP refused for loopback registries")
                ForEach(daemon.registries.warnings, id: \.self) { w in
                    Text("⚠︎ " + w.replacingOccurrences(of: "pratico: ", with: ""))
                }
                if !daemon.registries.logins.isEmpty { Divider() }
                ForEach(daemon.registries.logins) { l in
                    Button("Remove login \(l.username) @ \(l.server)") { daemon.removeLogin(l.server) }
                }
                Divider()
                Button("Edit config.toml…") { daemon.openConfig() }
            }
        }
        Divider()
        switch daemon.state {
        case .running:
            Button("Stop Daemon") { daemon.stop() }
        case .stopped:
            Button("Start Daemon") { daemon.start() }
        case .starting, .stopping:
            Button("Working…") {}.disabled(true)
        }
        Divider()
        Button("Quit Pratico") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
            .onAppear { daemon.markAlertsSeen() }
    }

    /// Why the toggle is on but the path is not pratico's.
    private var defaultSocketNote: String? {
        guard daemon.usesDefaultSocket else { return nil }
        switch daemon.defaultSocket {
        case .ours: return nil
        case .other(let owner): return "⚠︎ \(DefaultSocket.path) is taken: \(owner)"
        case .absent: return "⚠︎ \(DefaultSocket.path) is not linked; turn this off and on"
        }
    }

    private var statusLine: String {
        switch daemon.state {
        case .running: "Daemon running"
        case .starting: "Daemon starting…"
        case .stopping: "Daemon stopping…"
        case .stopped: "Daemon stopped"
        }
    }
}
