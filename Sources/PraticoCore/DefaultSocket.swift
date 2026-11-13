import Foundation

/// `/var/run/docker.sock`, the path Docker tools assume: a symlink to pratico's socket.
/// The daemon stays unprivileged; only the link needs root, because `/var/run` is root's
/// and macOS empties it at every boot. pratico never runs anything as root: the menubar
/// shows the commands, and the user runs them. The optional boot job is root-owned and runs
/// `/bin/ln` and nothing else.
public enum DefaultSocket {
    public static let path = "/var/run/docker.sock"
    public static let label = "dev.pratico.socket"
    public static let plistPath = "/Library/LaunchDaemons/\(label).plist"

    public enum State: Equatable, Sendable {
        case absent
        /// A link to pratico's socket.
        case ours
        /// Someone else's: a link elsewhere (Docker Desktop, Colima), or not a link at all.
        case other(String)
    }

    public static func state(link: String = path, target: String) -> State {
        var st = stat()
        guard lstat(link, &st) == 0 else { return .absent }
        guard st.st_mode & S_IFMT == S_IFLNK else { return .other("a file that is not a link") }
        let dest = (try? FileManager.default.destinationOfSymbolicLink(atPath: link)) ?? ""
        return dest == target ? .ours : .other(dest)
    }

    /// The launchd job: `ln -s` without `-f` fails rather than replace someone else's link.
    /// `target` is fixed here, for the user who turned the option on.
    public static func launchdPlist(target: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
        \t<key>Label</key>
        \t<string>\(label)</string>
        \t<key>ProgramArguments</key>
        \t<array>
        \t\t<string>/bin/ln</string>
        \t\t<string>-s</string>
        \t\t<string>\(xmlEscaped(target))</string>
        \t\t<string>\(path)</string>
        \t</array>
        \t<key>RunAtLoad</key>
        \t<true/>
        </dict>
        </plist>
        """
    }

    /// pratico's socket as the user's shell writes it: each user's own home, no fixed path.
    public static let shellTarget = "$HOME/.pratico/docker.sock"

    /// What the menubar's help shows the user to paste into Terminal; pratico itself never
    /// asks for root.
    public static let linkCommand = "sudo ln -s \"\(shellTarget)\" \(path)"

    /// Keeps the link after restarts: a root-owned job that runs only `/bin/ln -s` at boot.
    /// The heredoc is unquoted so the user's shell writes their own home into the plist,
    /// which launchd needs as an absolute path.
    public static let persistCommands = """
        sudo tee \(plistPath) >/dev/null <<PRATICO_PLIST
        \(launchdPlist(target: shellTarget))
        PRATICO_PLIST
        sudo launchctl bootstrap system \(plistPath)
        """

    public static let removeCommands = """
        sudo launchctl bootout system/\(label) 2>/dev/null; sudo rm -f \(plistPath) \(path)
        """

    static func xmlEscaped(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\n", with: "&#10;")  // no line can end the heredoc
    }

}
