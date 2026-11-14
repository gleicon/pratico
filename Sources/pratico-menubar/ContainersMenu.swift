import AppKit
import PraticoCore
import SwiftUI

/// `GET /pratico/containers`: one running container, its ports, health, and usage.
struct RunningContainer: Decodable, Equatable, Identifiable {
    struct Port: Decodable, Equatable, Hashable {
        var IP: String
        var PublicPort: Int
        var PrivatePort: Int
        var `Type`: String

        /// Other machines can reach it: the alert FR-33.a raises.
        var exposed: Bool { !(IP.hasPrefix("127.") || IP == "::1") }
        var line: String { "\(IP):\(PublicPort) → \(PrivatePort)/\(self.Type)" }
    }
    var Id: String
    var Name: String
    var Image: String
    var Paused: Bool
    var Health: String?
    var Ports: [Port]
    /// 100 is one busy CPU, as in `docker stats`.
    var CPU: Double
    var Memory: Int64

    var id: String { Id }
    var withoutUsage: RunningContainer {
        var c = self
        (c.CPU, c.Memory) = (0, 0)
        return c
    }
}

/// Running containers, with what they use (FR-31, FR-40) and what each can do: open a
/// published port, stop, restart. Nothing here removes anything.
struct ContainersMenu: View {
    let daemon: DaemonController

    var body: some View {
        let running = daemon.containers
        Menu(running.isEmpty ? "Containers: none running" : "Containers: \(running.count) running") {
            if running.isEmpty {
                Text("No container is running")
            } else {
                Text("Using \(Self.cpu(running.reduce(0) { $0 + $1.CPU })) CPU, \(bytes(running.reduce(0) { $0 + $1.Memory })) memory")
                Divider()
                ForEach(running) { c in
                    Menu(Self.title(c)) { ContainerItems(daemon: daemon, container: c) }
                }
            }
        }
    }

    static func cpu(_ percent: Double) -> String { String(format: "%.0f%%", percent) }

    private static func title(_ c: RunningContainer) -> String {
        let flag = c.Health == "unhealthy" ? "⚠︎ " : ""
        return "\(flag)\(c.Name)  \(c.Image)"
    }
}

private struct ContainerItems: View {
    let daemon: DaemonController
    let container: RunningContainer

    var body: some View {
        let c = container
        Text("\(ContainersMenu.cpu(c.CPU)) CPU, \(bytes(c.Memory)) memory\(c.Paused ? ", paused" : "")")
        if let health = c.Health { Text("Health: \(health)") }
        if c.Ports.isEmpty {
            Text("No published ports")
        } else {
            ForEach(c.Ports, id: \.self) { p in
                Text(p.exposed ? "⚠︎ \(p.line), reachable from other machines" : p.line)
            }
        }
        Divider()
        ForEach(c.Ports.filter { $0.Type == "tcp" }, id: \.self) { p in
            Button("Open localhost:\(p.PublicPort)") {
                if let url = URL(string: "http://localhost:\(p.PublicPort)") { NSWorkspace.shared.open(url) }
            }
        }
        Button("Stop") { daemon.containerAction(c, "stop") }
        Button("Restart") { daemon.containerAction(c, "restart") }
        Button("Copy ID") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(c.Id, forType: .string)
        }
    }
}

/// Recent alerts, newest first (FR-32 "view alerts"); each also became a notification.
struct AlertsMenu: View {
    let daemon: DaemonController

    var body: some View {
        let recent = daemon.alerts.reversed().prefix(10)
        Menu(daemon.alerts.isEmpty ? "Alerts" : "Alerts (\(daemon.alerts.count))") {
            if recent.isEmpty { Text("No alerts") }
            ForEach(Array(recent)) { a in
                Menu("\(a.level == "serious" ? "⛔︎" : "⚠︎") \(a.title)") {
                    ForEach(a.detail.split(separator: "\n").map(String.init), id: \.self) { Text($0) }
                    Text(a.time).foregroundStyle(.secondary)
                }
            }
            if !daemon.alerts.isEmpty {
                Divider()
                Button("Clear Alerts…") { daemon.clearAlerts() }
            }
        }
    }
}

extension DaemonController {
    /// `POST /containers/{id}/stop|restart`, then a refresh so the list follows at once.
    func containerAction(_ c: RunningContainer, _ action: String) {
        Task {
            let r = await Task.detached { DaemonProbe.request("POST", "/containers/\(c.Id)/\(action)", timeout: 30) }.value
            if let r, r.status >= 400 { error = "\(action.capitalized) \(c.Name): " + String(decoding: r.body, as: UTF8.self) }
            await refreshContainers()
        }
    }

    func clearAlerts() {
        guard confirm("Clear \(alerts.count) alert\(alerts.count == 1 ? "" : "s")?",
                      "They are removed from this list. Blocked images stay blocked until scan_allow or a rescan clears them.",
                      button: "Clear")
        else { return }
        Task.detached { _ = DaemonProbe.request("DELETE", "/pratico/alerts", timeout: 5) }
    }
}
