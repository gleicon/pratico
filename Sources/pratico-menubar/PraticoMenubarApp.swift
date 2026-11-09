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

    private var statusLine: String {
        switch daemon.state {
        case .running: "Daemon running"
        case .starting: "Daemon starting…"
        case .stopping: "Daemon stopping…"
        case .stopped: "Daemon stopped"
        }
    }
}
