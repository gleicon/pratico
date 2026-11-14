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
    private(set) var disk: DiskUsage?
    var scanners: ScannerReport?
    private(set) var scanSummary: ScanSummary?
    private(set) var alerts: [Alert] = []
    private(set) var registries = Registries()
    /// Time of the newest alert already notified, so a relaunch does not repeat it.
    private var seenUntil = UserDefaults.standard.string(forKey: "alertsSeenUntil") ?? ""
    let socketPath = Pratico.socketPath().path
    /// The socket as people read it: `~/.pratico/docker.sock`, not one user's home.
    var socketDisplay: String { (socketPath as NSString).abbreviatingWithTildeInPath }

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
        var Pid: Int32
        var StartedAt: Date
        var Socket: String
        var Containers: Int
        var ContainersRunning: Int
        /// Moves on any change to images, containers, or scans, from the menu or the CLI.
        var Changes: Int
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
            var keepLogins = true
        }
        var policy = Policy()
        var warnings: [String] = []
        var logins: [Login] = []
    }

    func removeLogin(_ server: String) {
        guard confirm("Remove the login for \(server)?", "Pratico forgets the credentials it kept for \(server). Docker's own login, if any, stays.", button: "Remove") else { return }
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

    /// The menubar icon: a blocked image, then images with critical or high vulnerabilities,
    /// then the daemon. Medium and low findings do not change it.
    var menubarSymbol: String {
        if let s = scanSummary, s.Blocked > 0 { return "exclamationmark.shield.fill" }
        if let s = scanSummary, s.CriticalOrHigh > 0 { return "exclamationmark.shield" }
        return isRunning ? "shippingbox.fill" : "shippingbox"
    }

    /// "Scan Results…" with what needs a look beside it.
    var scanResultsTitle: String {
        guard let s = scanSummary else { return "Scan Results…" }
        var parts: [String] = []
        if s.Blocked > 0 { parts.append("⛔︎ \(s.Blocked) blocked") }
        if s.CriticalOrHigh > 0 { parts.append("⚠︎ \(s.CriticalOrHigh) with critical or high vulnerabilities") }
        if s.Scanning > 0 { parts.append("\(s.Scanning) scanning") }
        return parts.isEmpty ? "Scan Results…" : "Scan Results…   " + parts.joined(separator: " · ")
    }

    func refreshScanSummary() async {
        update(\.scanSummary, await DaemonProbe.fetch("/pratico/scans/summary", as: ScanSummary.self))
    }

    /// New serious alerts also become a notification: the daemon stopped containers.
    private func refreshAlerts() {
        let data = (try? Data(contentsOf: Pratico.alertsPath())) ?? Data("[]".utf8)
        let latest = (try? JSONDecoder().decode([Alert].self, from: data)) ?? []
        let known = Set(alerts.map(\.id))
        let fresh = latest.filter { $0.level == "serious" && !known.contains($0.id) && $0.time > seenUntil }
        update(\.alerts, latest)
        guard !fresh.isEmpty else { return }
        if let newest = fresh.map(\.time).max(), newest > seenUntil {
            seenUntil = newest
            UserDefaults.standard.set(newest, forKey: "alertsSeenUntil")
        }
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
        agent.stop(pid: status?.Pid)
    }

    /// Stop, wait until the old daemon has let go of the socket (it stops its containers'
    /// supervision cleanly first), then start.
    func restart() async {
        stop()
        for _ in 0..<60 {
            if await Task.detached(operation: { DaemonController.probeVersion() == nil }).value { break }
            try? await Task.sleep(for: .milliseconds(250))
        }
        start()
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
            Engine: Virtualization.framework, containers: \(status.map { "\($0.ContainersRunning) running of \($0.Containers)" } ?? "?")
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
                docker context create pratico --docker host=unix://\(DefaultSocket.shellTarget)
                docker context use pratico

                # Or an environment variable:
                export DOCKER_HOST=unix://\(DefaultSocket.shellTarget)
                echo 'export DOCKER_HOST=unix://\(DefaultSocket.shellTarget)' >> ~/.zshrc

                # Check:
                docker version --format '{{.Server.Version}}'
                """)
    }

    /// Help for `/var/run/docker.sock`: why it needs root, and the commands to run.
    func showDefaultSocketHelp() {
        showCommands(
            title: "Use \(DefaultSocket.path)",
            text: """
                Pratico serves Docker at \(socketDisplay). That needs no password and works with \
                DOCKER_HOST or a Docker context (Use with docker…).

                Some tools only look at \(DefaultSocket.path). That folder belongs to the system, \
                so a link there needs an administrator: run these commands in Terminal yourself. \
                Pratico never asks for your password. macOS empties /var/run at every restart; the \
                optional startup job only runs /bin/ln. If Docker Desktop or Colima already uses the \
                path, leave it to them.
                """,
            commands: """
                # Link it now (until the next restart):
                \(DefaultSocket.linkCommand)

                # Optional: link it at every startup:
                \(DefaultSocket.persistCommands)

                # Undo both:
                \(DefaultSocket.removeCommands)
                """)
        refreshDefaultSocket()
    }

    /// Every removal asks first.
    private func confirm(_ title: String, _ text: String, button: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.alertStyle = .warning
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// An explanation and Terminal commands the user runs themselves, with a Copy button.
    func showCommands(title: String, text: String, commands: String) {
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

    /// Lists what goes and what it frees, asks, then uses Docker's own prune endpoints.
    func cleanUp(_ kind: CleanupKind) {
        guard let c = disk?.Cleanup[kind], !c.isEmpty else { return }
        var lines = c.Containers.map { "container \($0.Name)  \(bytes($0.Size))" }  // with its logs
        lines += c.Images.map { "image \($0.Name)  \(bytes($0.Size))" }
        lines += c.Volumes.map { "volume \($0.Name)  \(bytes($0.Size))" }
        if c.Leftover > 0 { lines.append("leftover image data  \(bytes(c.Leftover))") }
        let alert = NSAlert()
        alert.messageText = "Remove \(lines.count) item\(lines.count == 1 ? "" : "s"), freeing \(bytes(c.Bytes))?"
        alert.informativeText = lines.prefix(15).joined(separator: "\n") + (lines.count > 15 ? "\n… and \(lines.count - 15) more" : "")
            + "\n\n" + kind.note
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        alert.buttons.first?.hasDestructiveAction = true
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task {
            let freed = await Task.detached {
                kind.prunes.reduce(Int64(0)) { $0 + Self.reclaimed(DaemonProbe.request("POST", $1, timeout: 300)) }
            }.value
            await refreshAfterChange()
            let done = NSAlert()
            done.messageText = "Freed \(bytes(freed))"
            done.informativeText = "\(bytes(disk?.Total ?? 0)) used, \(bytes(disk?.Free ?? 0)) free on this Mac."
            NSApp.activate()
            done.runModal()
        }
    }

    nonisolated private static func reclaimed(_ r: DaemonProbe.Response?) -> Int64 {
        guard let r, let obj = try? JSONSerialization.jsonObject(with: r.body) as? [String: Any] else { return 0 }
        return (obj["SpaceReclaimed"] as? NSNumber)?.int64Value ?? 0
    }

    /// Disk use and the scan summary, together: the slow disk walk does not hold up the other.
    func refreshAfterChange() async {
        async let usage = DaemonProbe.fetch("/pratico/disk", as: DiskUsage.self, timeout: 30)
        async let summary = DaemonProbe.fetch("/pratico/scans/summary", as: ScanSummary.self)
        let (u, s) = await (usage, summary)
        update(\.disk, u)
        update(\.scanSummary, s)
    }

    /// Refreshes once a second, so state changes show within 2 s (SPEC FR-30). Disk use and
    /// scan results follow the daemon's change counter, so every indicator moves together
    /// whether the change came from this menu, Scan Results, or the docker CLI; disk use
    /// also every 30 s, for logs that grow.
    private func poll() {
        pollTask = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                let (version, status) = await Task.detached { (DaemonController.probeVersion(), DaemonController.probeStatus()) }.value
                guard let self else { return }
                self.apply(version)
                let changed = status?.Changes != self.status?.Changes
                self.update(\.status, status)
                self.refreshAlerts()
                self.refreshRegistries()
                self.refreshDefaultSocket()
                if changed || tick % 30 == 0 { await self.refreshAfterChange() }
                // Each check runs every scanner's --version: once a minute is plenty.
                if tick % 60 == 0 { await self.refreshScanners() }
                tick += 1
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

    nonisolated static func probeStatus() -> Status? { DaemonProbe.decode("/pratico/status") }

    nonisolated static func probeVersion() -> String? {
        guard let r = DaemonProbe.get("/version"), r.status == 200,
            let obj = try? JSONSerialization.jsonObject(with: r.body) as? [String: Any]
        else { return nil }
        return obj["ApiVersion"] as? String
    }
}

/// The menubar's reads of the daemon's JSON: one decoder (dates are ISO 8601), off the main actor.
extension DaemonProbe {
    static func fetch<T: Decodable & Sendable>(_ path: String, as type: T.Type, timeout: Int = 5) async -> T? {
        await Task.detached { decode(path, as: type, timeout: timeout) }.value
    }

    /// `GET path`, decoded; nil when the daemon does not answer or the body does not decode.
    nonisolated static func decode<T: Decodable>(_ path: String, as type: T.Type = T.self, timeout: Int = 1) -> T? {
        guard let r = get(path, timeout: timeout), r.status == 200 else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(type, from: r.body)
    }
}
