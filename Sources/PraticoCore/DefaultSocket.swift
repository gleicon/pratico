import Foundation

/// `/var/run/docker.sock`, the path Docker tools assume: a symlink to pratico's socket.
/// The daemon stays unprivileged; only the link needs root, because `/var/run` is root's
/// and macOS empties it at every boot. A root-owned launchd job in `/Library/LaunchDaemons`
/// remakes it at boot with `/bin/ln` and nothing else: no pratico code runs as root, and
/// nothing a user can write is ever run as root (the app bundle is the user's).
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

    /// Run as root, once, after an admin approves it: installs the job and links now. The
    /// plist travels inside the script, never through a file the user could swap.
    public static func installScript(target: String) -> String {
        """
        set -e
        /bin/cat > \(plistPath) <<'PRATICO_PLIST'
        \(launchdPlist(target: target))
        PRATICO_PLIST
        /usr/sbin/chown root:wheel \(plistPath)
        /bin/chmod 644 \(plistPath)
        /bin/launchctl bootout system/\(label) 2>/dev/null || true
        /bin/launchctl bootstrap system \(plistPath)
        """
    }

    /// Run as root: removes the job, and the link only if it is pratico's.
    public static func removeScript(target: String) -> String {
        """
        /bin/launchctl bootout system/\(label) 2>/dev/null
        /bin/rm -f \(plistPath)
        if [ "$(/usr/bin/readlink \(path))" = \(shellQuoted(target)) ]; then /bin/rm -f \(path); fi
        exit 0
        """
    }

    static func xmlEscaped(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\n", with: "&#10;")  // no line can end the heredoc
    }

    static func shellQuoted(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
