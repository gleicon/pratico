import AppKit
import Foundation
import Observation
import PraticoCore
import UserNotifications

/// Starts, stops, and watches the bundled `pratico-daemon` helper (SPEC D-13).
@MainActor @Observable
final class DaemonController {
    enum State: Equatable {
        case stopped
        case starting
        case running(apiVersion: String)
        case stopping
    }

    private(set) var state: State = .stopped
    private(set) var error: String?
    private(set) var status: Status?
    private(set) var alerts: [Alert] = []
    private(set) var registries = Registries()
    /// Time of the newest alert the user has seen (menu opened or notified).
    private var seenUntil = UserDefaults.standard.string(forKey: "alertsSeenUntil") ?? ""
    let socketPath = Pratico.socketPath().path

    private let agent = LaunchAgent()
    /// Until when `starting` waits for the daemon before saying it did not come up.
    private var startDeadline = Date.distantPast
    private(set) var defaultSocket: DefaultSocket.State = .absent
    private var pollTask: Task<Void, Never>?

    var isRunning: Bool { if case .running = state { true } else { false } }

    var apiVersion: String? { if case .running(let v) = state { v } else { nil } }

    /// `GET /pratico/status`.
    struct Status: Decodable, Equatable {
        var Version: String
        var Runtime: String
        var StartedAt: Date
        var Socket: String
        var Containers: Int
        var ContainersRunning: Int
    }

    struct Alert: Decodable, Identifiable, Equatable {
        var time: String
        var level: String  // serious | warning
        var title: String
        var detail: String
        var id: String { time + title }
    }

    /// `registries.json`: what pratico trusts beyond HTTPS with the system's roots, and
    /// the logins it keeps, so none of it is a surprise.
    struct Registries: Decodable, Equatable {
        struct Login: Decodable, Equatable, Identifiable {
            var server: String
            var username: String
            var id: String { server }
        }
        struct Policy: Decodable, Equatable {
            var httpLoopback = true
            var systemRoots = true
        }
        var policy = Policy()
        var warnings: [String] = []
        var logins: [Login] = []
    }

    func removeLogin(_ server: String) {
        let path = "/pratico/registries/logins/" + (server.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? server)
        Task.detached { _ = DaemonProbe.request("DELETE", path) }
        registries.logins.removeAll { $0.server == server }
    }

    func openConfig() {
        let file = Pratico.home().appending(path: "config.toml")
        if !FileManager.default.fileExists(atPath: file.path) { FileManager.default.createFile(atPath: file.path, contents: nil) }
        NSWorkspace.shared.open(file)
    }

    private func refreshRegistries() {
        guard let data = try? Data(contentsOf: Pratico.registriesPath()),
            let r = try? JSONDecoder().decode(Registries.self, from: data), r != registries
        else { return }
        registries = r
    }

    var hasUnseenSerious: Bool { alerts.contains { $0.level == "serious" && $0.time > seenUntil } }

    func markAlertsSeen() {
        guard let newest = alerts.last?.time, newest > seenUntil else { return }
        seenUntil = newest
        UserDefaults.standard.set(newest, forKey: "alertsSeenUntil")
    }

    func clearAlerts() {
        try? FileManager.default.removeItem(at: Pratico.alertsPath())
        alerts = []
    }

    /// New serious alerts also become a notification: the daemon stopped containers.
    private func refreshAlerts() {
        let data = (try? Data(contentsOf: Pratico.alertsPath())) ?? Data("[]".utf8)
        let latest = (try? JSONDecoder().decode([Alert].self, from: data)) ?? []
        let known = Set(alerts.map(\.id))
        let fresh = latest.filter { $0.level == "serious" && !known.contains($0.id) && $0.time > seenUntil }
        update(\.alerts, latest)
        guard !fresh.isEmpty else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let center = UNUserNotificationCenter.current()
            for a in fresh {
                let content = UNMutableNotificationContent()
                content.title = "Pratico: \(a.title)"
                content.body = a.detail
                center.add(UNNotificationRequest(identifier: a.id, content: content, trigger: nil))
            }
        }
    }

    init() {
        poll()
        Task {
            // FR-1: launching the app starts the daemon when it is not running. Asked
            // directly: restarting a live daemon would cost its containers' supervision.
            let alive = await Task.detached { DaemonController.probeVersion() != nil }.value
            if !alive && !isRunning { start() }
        }
    }

    func start() {
        error = nil
        state = .starting
        startDeadline = Date() + 30
        try? FileManager.default.removeItem(at: Pratico.startupErrorPath())
        if let failure = agent.start() {
            error = "Could not start daemon: \(failure)"
            state = .stopped
        }
    }

    func stop() {
        state = .stopping
        agent.stop()
    }

    /// Console follows the file as it grows; no terminal needed.
    func openLog() {
        let log = Pratico.logPath()
        if !FileManager.default.fileExists(atPath: log.path) { FileManager.default.createFile(atPath: log.path, contents: nil) }
        NSWorkspace.shared.open([log], withApplicationAt: URL(filePath: "/System/Applications/Utilities/Console.app"),
                                configuration: NSWorkspace.OpenConfiguration())
    }

    /// Version, runtime, status, config, and the log's tail, for a bug report.
    func copyDiagnostics() {
        let log = (try? String(contentsOf: Pratico.logPath(), encoding: .utf8)) ?? ""
        let config = (try? String(contentsOf: Config.path(), encoding: .utf8)) ?? "(none)"
        let text = """
            Pratico \(Pratico.version), macOS \(ProcessInfo.processInfo.operatingSystemVersionString)
            Daemon: \(statusLine)\(error.map { " (\($0))" } ?? "")
            Runtime: \(status?.Runtime ?? "?"), containers: \(status.map { "\($0.ContainersRunning) running of \($0.Containers)" } ?? "?")
            \(DefaultSocket.path): \(defaultSocket)
            config.toml:
            \(config)
            daemon.log (last 50 lines):
            \(log.split(separator: "\n", omittingEmptySubsequences: false).suffix(50).joined(separator: "\n"))
            """
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    var statusLine: String {
        switch state {
        case .running: "Daemon running"
        case .starting: "Daemon starting…"
        case .stopping: "Daemon stopping…"
        case .stopped: "Daemon stopped"
        }
    }

    /// How to point `docker` at pratico without `-H`: a context, or `DOCKER_HOST`.
    func showDockerSetup() {
        showCommands(
            title: "Use Pratico with docker",
            text: """
                Pick one, once. A Docker context is remembered by the docker CLI, Compose, and \
                most tools that read its config. DOCKER_HOST works everywhere, including tools \
                that ignore contexts; add the line to ~/.zshrc to keep it.
                """,
            commands: """
                # A Docker context (remembered):
                docker context create pratico --docker host=unix://\(socketPath)
                docker context use pratico

                # Or an environment variable:
                export DOCKER_HOST=unix://\(socketPath)
                echo 'export DOCKER_HOST=unix://\(socketPath)' >> ~/.zshrc

                # Check:
                docker version --format '{{.Server.Version}}'
                """)
    }

    /// Help for `/var/run/docker.sock`: why it needs root, and the commands to run.
    func showDefaultSocketHelp() {
        showCommands(
            title: "Use \(DefaultSocket.path)",
            text: """
                Pratico serves Docker at \(socketPath). That needs no password and works with \
                DOCKER_HOST or a Docker context (Use with docker…).

                Some tools only look at \(DefaultSocket.path). That folder belongs to the system, \
                so a link there needs an administrator: run these commands in Terminal yourself. \
                Pratico never asks for your password. macOS empties /var/run at every restart; the \
                optional startup job only runs /bin/ln. If Docker Desktop or Colima already uses the \
                path, leave it to them.
                """,
            commands: """
                # Link it now (until the next restart):
                \(DefaultSocket.linkCommand(target: socketPath))

                # Optional: link it at every startup:
                \(DefaultSocket.persistCommands(target: socketPath))

                # Undo both:
                \(DefaultSocket.removeCommands)
                """)
        refreshDefaultSocket()
    }

    /// An explanation and Terminal commands the user runs themselves, with a Copy button.
    private func showCommands(title: String, text: String, commands: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 520, height: 220))
        view.string = commands
        view.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        view.isEditable = false
        let scroll = NSScrollView(frame: view.frame)
        scroll.documentView = view
        scroll.hasVerticalScroller = true
        alert.accessoryView = scroll
        alert.addButton(withTitle: "Copy Commands")
        alert.addButton(withTitle: "Close")
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(commands, forType: .string)
        }
    }

    private func refreshDefaultSocket() {
        update(\.defaultSocket, DefaultSocket.state(target: socketPath))
    }

    /// Refreshes once a second, so state changes show within 2 s (SPEC FR-30).
    private func poll() {
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                let (version, status) = await Task.detached { (DaemonController.probeVersion(), DaemonController.probeStatus()) }.value
                guard let self else { return }
                self.apply(version)
                self.update(\.status, status)
                self.refreshAlerts()
                self.refreshRegistries()
                self.refreshDefaultSocket()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// Writes only changes: every write re-renders the open menu, which closes its submenus.
    private func update<T: Equatable>(_ field: ReferenceWritableKeyPath<DaemonController, T>, _ value: T) {
        if self[keyPath: field] != value { self[keyPath: field] = value }
    }

    private func apply(_ version: String?) {
        if let version {
            update(\.state, .running(apiVersion: version))
            update(\.error, nil)
            return
        }
        if let reason = try? String(contentsOf: Pratico.startupErrorPath(), encoding: .utf8) {
            update(\.error, reason.trimmingCharacters(in: .whitespacesAndNewlines))
            update(\.state, .stopped)
            return
        }
        switch state {
        case .starting where Date() < startDeadline:
            break  // still coming up
        case .starting:
            error = "The daemon did not start in 30 s. View Daemon Log for why."
            state = .stopped
        default:
            update(\.state, .stopped)
        }
    }

    nonisolated static func probeStatus() -> Status? {
        guard let r = DaemonProbe.get("/pratico/status"), r.status == 200 else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(Status.self, from: r.body)
    }

    nonisolated static func probeVersion() -> String? {
        guard let r = DaemonProbe.get("/version"), r.status == 200,
            let obj = try? JSONSerialization.jsonObject(with: r.body) as? [String: Any]
        else { return nil }
        return obj["ApiVersion"] as? String
    }
}
