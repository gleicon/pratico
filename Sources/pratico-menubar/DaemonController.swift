import Foundation
import Observation
import PraticoCore
import ServiceManagement
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
    private(set) var needsApproval = false
    private(set) var alerts: [Alert] = []
    /// Time of the newest alert the user has seen (menu opened or notified).
    private var seenUntil = UserDefaults.standard.string(forKey: "alertsSeenUntil") ?? ""
    let socketPath = Pratico.socketPath().path

    private let service = SMAppService.agent(plistName: "dev.pratico.daemon.plist")
    private var pollTask: Task<Void, Never>?

    var isRunning: Bool { if case .running = state { true } else { false } }

    var apiVersion: String? { if case .running(let v) = state { v } else { nil } }

    struct Alert: Decodable, Identifiable {
        var time: String
        var level: String  // serious | warning
        var title: String
        var detail: String
        var id: String { time + title }
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
        alerts = latest
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
            // FR-1: launching the app starts the daemon when it is not running.
            try? await Task.sleep(for: .milliseconds(300))
            if !isRunning { start() }
        }
    }

    func start() {
        error = nil
        state = .starting
        try? FileManager.default.removeItem(at: Pratico.startupErrorPath())
        do {
            // Re-registering kicks a registered-but-dead agent (RunAtLoad).
            if service.status == .enabled { try service.unregister() }
            try service.register()
        } catch {
            if service.status == .requiresApproval {
                needsApproval = true
                self.error = "Allow Pratico in System Settings › General › Login Items."
            } else {
                self.error = "Could not start daemon: \(error.localizedDescription)"
            }
            state = .stopped
        }
    }

    func stop() {
        state = .stopping
        Task {
            do { try await service.unregister() } catch { self.error = "Could not stop daemon: \(error.localizedDescription)" }
        }
    }

    func openLoginItems() { SMAppService.openSystemSettingsLoginItems() }

    /// Refreshes once a second, so state changes show within 2 s (SPEC FR-30).
    private func poll() {
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                let version = await Task.detached { DaemonController.probeVersion() }.value
                guard let self else { return }
                self.apply(version)
                self.refreshAlerts()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func apply(_ version: String?) {
        if let version {
            state = .running(apiVersion: version)
            error = nil
            needsApproval = false
            return
        }
        if let reason = try? String(contentsOf: Pratico.startupErrorPath(), encoding: .utf8) {
            error = reason.trimmingCharacters(in: .whitespacesAndNewlines)
            state = .stopped
            return
        }
        switch state {
        case .starting where service.status == .enabled:
            break  // still coming up
        default:
            state = .stopped
        }
    }

    nonisolated static func probeVersion() -> String? {
        guard let r = DaemonProbe.get("/version"), r.status == 200,
            let obj = try? JSONSerialization.jsonObject(with: r.body) as? [String: Any]
        else { return nil }
        return obj["ApiVersion"] as? String
    }
}
