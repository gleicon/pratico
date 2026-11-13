import Foundation
import PraticoCore
import ServiceManagement

/// The daemon's launch agent, `~/Library/LaunchAgents/dev.pratico.daemon.plist`, written by
/// the menubar with this bundle's daemon path (SPEC D-13). Not `SMAppService`: with ad-hoc
/// signing (D-10) its Background Task Management record pins the daemon's code signature,
/// and launchd refuses the daemon after any rebuild or update ("Launch Constraint
/// Violation"). A plain agent runs as the user, so nothing is gained by root or lost.
struct LaunchAgent {
    static let label = "dev.pratico.daemon"
    let plist = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/LaunchAgents/\(label).plist")
    private var domain: String { "gui/\(getuid())" }

    /// Writes the plist for this copy of the app and (re)starts the daemon; nil on success.
    func start() -> String? {
        // Agents registered through SMAppService by older builds hold the same label.
        try? SMAppService.agent(plistName: "\(Self.label).plist").unregister()
        rotateLog()
        let daemon = Bundle.main.bundleURL.appending(path: "Contents/MacOS/pratico-daemon").path
        let log = Pratico.logPath().path
        let job: [String: Any] = [
            "Label": Self.label,
            "ProgramArguments": [daemon],
            // At login too; no KeepAlive: a crashed daemon stays stopped and the menubar
            // shows it (SPEC AC-35).
            "RunAtLoad": true,
            "StandardOutPath": log,
            "StandardErrorPath": log,
            "AssociatedBundleIdentifiers": [Bundle.main.bundleIdentifier ?? "dev.pratico.menubar"],
        ]
        do {
            try FileManager.default.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: Pratico.home(), withIntermediateDirectories: true)
            try PropertyListSerialization.data(fromPropertyList: job, format: .xml, options: 0).write(to: plist, options: .atomic)
        } catch {
            return "cannot write \(plist.path): \(error.localizedDescription)"
        }
        _ = launchctl("bootout", "\(domain)/\(Self.label)")
        return launchctl("bootstrap", domain, plist.path)
    }

    /// Stops the daemon, if running, and removes the plist, so it does not start at login either.
    func stop() {
        _ = launchctl("bootout", "\(domain)/\(Self.label)")
        try? FileManager.default.removeItem(at: plist)
    }

    /// One old generation, so the log never grows past about 20 MB.
    private func rotateLog() {
        let log = Pratico.logPath()
        guard let size = try? FileManager.default.attributesOfItem(atPath: log.path)[.size] as? Int, size > 10 << 20 else { return }
        let old = log.appendingPathExtension("1")
        try? FileManager.default.removeItem(at: old)
        try? FileManager.default.moveItem(at: log, to: old)
    }

    private func launchctl(_ args: String...) -> String? {
        let p = Process()
        p.executableURL = URL(filePath: "/bin/launchctl")
        p.arguments = args
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        do { try p.run() } catch { return "\(error)" }
        p.waitUntilExit()
        if p.terminationStatus == 0 { return nil }
        let message = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return message.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
