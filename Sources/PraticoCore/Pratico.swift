import Foundation

/// Facts shared by the CLI, daemon, and menubar app.
public enum Pratico {
    public static let version = "0.1.0"

    /// Root of all pratico state: `~/.pratico`.
    public static func home(for user: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        user.appending(path: ".pratico", directoryHint: .isDirectory)
    }

    /// Docker Remote API socket: `~/.pratico/docker.sock`.
    public static func socketPath(home: URL = home()) -> URL {
        home.appending(path: "docker.sock", directoryHint: .notDirectory)
    }
}
