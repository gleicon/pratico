import Foundation

/// `/var/run/docker.sock`, the path Docker tools assume: a symlink to pratico's socket,
/// made by the `pratico-socket-link` helper. The daemon stays unprivileged; only the link
/// needs root, because `/var/run` is root's and macOS empties it at every boot.
public enum DefaultSocket {
    public static let path = "/var/run/docker.sock"

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

    /// Links `link` to `target` unless something is there already; someone else's link or
    /// socket is left alone. `symlink(2)` fails rather than replace, so there is no race.
    @discardableResult
    public static func claim(link: String = path, target: String) -> State {
        if symlink(target, link) == 0 { return .ours }
        return state(link: link, target: target)
    }

    /// Removes the link only if it is pratico's.
    public static func release(link: String = path, target: String) {
        if state(link: link, target: target) == .ours { unlink(link) }
    }
}
