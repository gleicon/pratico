import Foundation

/// Facts shared by the CLI, daemon, and menubar app.
public enum Pratico {
    public static let version = "0.1.0-alpha.2"

    /// Root of all pratico state: `~/.pratico`.
    public static func home(for user: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        user.appending(path: ".pratico", directoryHint: .isDirectory)
    }

    /// The daemon's own output, written by launchd: `~/.pratico/daemon.log`.
    public static func logPath(home: URL = home()) -> URL { home.appending(path: "daemon.log") }

    /// One timestamped line of the daemon log.
    public static func log(_ message: String) {
        FileHandle.standardError.write(Data("\(Date().ISO8601Format()) \(message)\n".utf8))
    }

    /// Docker Remote API socket: `~/.pratico/docker.sock`.
    public static func socketPath(home: URL = home()) -> URL {
        home.appending(path: "docker.sock", directoryHint: .notDirectory)
    }
}
