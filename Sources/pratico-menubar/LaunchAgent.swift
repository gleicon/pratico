import Foundation
import PraticoCore
import ServiceManagement

/// Runs the bundled daemon (SPEC D-13), natively: no `launchctl`, no shell. Start spawns it
/// in its own session, so it outlives the menubar. While it runs and `start_at_login` is
/// on, `~/Library/LaunchAgents/dev.pratico.daemon.plist` is there for launchd to read at
/// the next login (FR-4). Stop sends it SIGTERM (a clean `docker`-style shutdown) and
/// removes the plist.
/// Not `SMAppService`: with ad-hoc signing (D-10) its record pins the daemon's code
/// signature, and launchd refuses the daemon after any rebuild or update.
struct LaunchAgent {
    static let label = "dev.pratico.daemon"
    let plist = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/LaunchAgents/\(label).plist")
    private var daemon: String { Bundle.main.bundleURL.appending(path: "Contents/MacOS/pratico-daemon").path }

    /// nil on success.
    func start(atLogin: Bool) -> String? {
        // Agents registered through SMAppService by older builds hold the same label.
        try? SMAppService.agent(plistName: "\(Self.label).plist").unregister()
        rotateLog()
        if let failure = startAtLogin(atLogin) { return failure }
        return spawn(log: Pratico.logPath().path)
    }

    /// Writes or removes the login job; nil on success. Writing an unchanged job is skipped.
    @discardableResult
    func startAtLogin(_ on: Bool) -> String? {
        guard on else {
            try? FileManager.default.removeItem(at: plist)
            return nil
        }
        let log = Pratico.logPath().path
        let job: [String: Any] = [
            "Label": Self.label,
            "ProgramArguments": [daemon],
            // At login; no KeepAlive: a crashed daemon stays stopped and the menubar shows
            // it (SPEC AC-35).
            "RunAtLoad": true,
            "StandardOutPath": log,
            "StandardErrorPath": log,
            "AssociatedBundleIdentifiers": [Bundle.main.bundleIdentifier ?? "dev.pratico.menubar"],
        ]
        do {
            let data = try PropertyListSerialization.data(fromPropertyList: job, format: .xml, options: 0)
            if (try? Data(contentsOf: plist)) == data { return nil }
            try FileManager.default.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: Pratico.home(), withIntermediateDirectories: true)
            try data.write(to: plist, options: .atomic)
        } catch {
            return "cannot write \(plist.path): \(error.localizedDescription)"
        }
        return nil
    }

    /// SIGTERM to the running daemon, then no start at login.
    func stop(pid: Int32?) {
        if let pid, pid > 0 { kill(pid, SIGTERM) }
        try? FileManager.default.removeItem(at: plist)
    }

    /// The daemon in its own session, output appended to the log, nothing inherited.
    private func spawn(log: String) -> String? {
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, log, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        posix_spawn_file_actions_adddup2(&actions, 1, 2)
        var pid: pid_t = 0
        let argv: [UnsafeMutablePointer<CChar>?] = [strdup(daemon), nil]
        defer { argv.forEach { free($0) } }
        let rc = posix_spawn(&pid, daemon, &actions, &attr, argv, environ)
        guard rc == 0 else { return "cannot start \(daemon): \(String(cString: strerror(rc)))" }
        // Reaped here, or its exit would leave a zombie while the menubar runs.
        DispatchQueue.global().async { [pid] in
            var status: Int32 = 0
            waitpid(pid, &status, 0)
        }
        return nil
    }

    /// One old generation, so the log never grows past about 20 MB.
    private func rotateLog() {
        let log = Pratico.logPath()
        guard let size = try? FileManager.default.attributesOfItem(atPath: log.path)[.size] as? Int, size > 10 << 20 else { return }
        let old = log.appendingPathExtension("1")
        try? FileManager.default.removeItem(at: old)
        try? FileManager.default.moveItem(at: log, to: old)
    }
}
