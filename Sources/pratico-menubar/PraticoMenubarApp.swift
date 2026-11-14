import PraticoCore
import SwiftUI

@main
struct PraticoMenubarApp: App {
    @State private var daemon = DaemonController()

    var body: some Scene {
        MenuBarExtra {
            StatusMenu(daemon: daemon)
        } label: {
            // The running-container count beside the icon (FR-29), none when nothing runs.
            let n = daemon.containers.count
            Text(n > 0 ? "\(Image(systemName: daemon.menubarSymbol)) \(n)" : "\(Image(systemName: daemon.menubarSymbol))")
        }
        // Which scanner found what, per image.
        Window("Scan Results", id: "scan-results") {
            ScanResultsView(daemon: daemon)
        }
        .defaultLaunchBehavior(.suppressed)  // only from the menu
        // ⌘, (SPEC FR-34): config.toml as a form.
        Settings {
            SettingsView(daemon: daemon)
        }
    }
}

struct StatusMenu: View {
    let daemon: DaemonController
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        // FR-5: state, socket path, API version.
        Text(daemon.statusLine)
        if let error = daemon.error {
            Text("⚠︎ \(error)")
        }
        Menu("Status") {
            if let s = daemon.status {
                Text("Up since \(s.StartedAt.formatted(date: .abbreviated, time: .shortened))")
                Text("Engine: built in (Virtualization.framework)")
                Text("Containers: \(s.ContainersRunning) running, \(s.Containers) in all")
            }
            if let v = daemon.apiVersion { Text("Docker API \(v)") }
            Text("Socket: \(daemon.socketDisplay)")
            switch daemon.defaultSocket {
            case .ours: Text("Also at \(DefaultSocket.path)")
            case .other(let owner): Text("\(DefaultSocket.path) is another daemon's: \(owner)")
            case .absent: EmptyView()
            }
            Divider()
            Button("View Daemon Log…") { daemon.openLog() }
            Button("Copy Diagnostics") { daemon.copyDiagnostics() }
        }
        // Space used and cleanup, better than `docker system df` and `prune`.
        if daemon.isRunning {
            ContainersMenu(daemon: daemon)
            AlertsMenu(daemon: daemon)
            SnapshotMenu(daemon: daemon)
            Divider()
            DiskMenu(daemon: daemon)
            ScannersMenu(daemon: daemon)
        }
        // ~/.pratico/docker.sock is the default; this path needs root, which pratico never asks for.
        Button("Use with docker…") { daemon.showDockerSetup() }
        Button("Use \(DefaultSocket.path)…") { daemon.showDefaultSocketHelp() }
        // D-24: one line however many images; the details are in the Scan Results window.
        if daemon.isRunning {
            Divider()
            ScanResultsButton(title: daemon.scanResultsTitle)
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
                Text(daemon.registries.policy.keepLogins ? "docker login is kept for clients that send none" : "docker login is checked, not kept (as dockerd)")
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
        // A menubar app is never frontmost on its own; bring the window forward.
        Button("Settings…") {
            NSApp.activate()
            openSettings()
        }
        .keyboardShortcut(",")
        Button("Quit Pratico") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }
}
