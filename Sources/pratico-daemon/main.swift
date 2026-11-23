import Foundation
import PraticoCore
import PraticoDaemonKit

// Started by Pratico.app's launch agent, never by the user directly (SPEC D-13); its
// output goes to `~/.pratico/daemon.log`.
// `--home <dir>` relocates all state (the e2e suite uses a temporary home).
// On a Linux host, `install` and `uninstall` set up the systemd service (HostInstall), which
// runs the daemon with `--socket`, shared with the `pratico` group.

var home = Pratico.home()
var socketPath: String?

/// Exits, leaving the reason in `daemon.err` for the menubar to show (SPEC FR-3).
@MainActor func fail(_ message: String, code: Int32 = 1) -> Never {
    Pratico.log("pratico-daemon: \(message)")
    try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    try? Data((message + "\n").utf8).write(to: Pratico.startupErrorPath(home: home))
    exit(code)
}

var args = Array(CommandLine.arguments.dropFirst())

#if os(Linux)
if let verb = args.first, verb == "install" || verb == "uninstall" {
    var options = HostInstall.Options()
    var flags = Array(args.dropFirst())
    while !flags.isEmpty {
        let flag = flags.removeFirst()
        switch flag {
        case "--yes": options.yes = true
        case "--files-only" where verb == "install": options.filesOnly = true
        case "--no-harden" where verb == "install": options.noHarden = true
        case "--allow-port" where verb == "install" && flags.first.flatMap({ Int($0) }).map({ (1...65535).contains($0) }) == true:
            options.allowPorts.append(Int(flags.removeFirst())!)
        case "--purge" where verb == "uninstall": options.purge = true
        default:
            print("usage: pratico-daemon install [--yes] [--files-only] [--no-harden] [--allow-port N]… | uninstall [--yes] [--purge]")
            exit(2)
        }
    }
    let source = Bundle.main.executableURL?.resolvingSymlinksInPath().deletingLastPathComponent().path ?? "."
    do {
        if verb == "install" { try HostInstall.install(source: source, options: options) } else { try HostInstall.uninstall(options: options) }
    } catch {
        FileHandle.standardError.write(Data("pratico-daemon \(verb): \(error)\n".utf8))
        exit(1)
    }
    exit(0)
}
#endif

while let arg = args.first {
    args.removeFirst()
    switch arg {
    case "--version":
        print("pratico-daemon \(Pratico.version)")
        exit(0)
    case "--home":
        guard let v = args.first else { fail("--home needs a directory", code: 2) }
        args.removeFirst()
        home = URL(filePath: v, directoryHint: .isDirectory)
    case "--socket":
        guard let v = args.first else { fail("--socket needs a path", code: 2) }
        args.removeFirst()
        socketPath = v
    default:
        fail("unknown argument \(arg)", code: 2)
    }
}

Pratico.log("pratico-daemon: \(Pratico.version) starting, home \(home.path)")

// FR-37/FR-38: defaults when absent; refuse to start on unknown keys or bad values.
let config: Config
do { config = try Config.load(home: home) } catch { fail("\(error)", code: 4) }

// A child that exits before reading its stdin must not take the daemon down with it.
signal(SIGPIPE, SIG_IGN)

let daemon: Daemon
// A socket of its own is the Linux service's, shared with its group (the users it serves).
do { daemon = try Daemon(home: home, config: config, socketPath: socketPath, socketMode: socketPath == nil ? 0o600 : 0o660) } catch let e as RuntimeUnavailable { fail("\(e)", code: 3) } catch { fail("\(error)", code: 4) }
do { try daemon.start() } catch let e as DaemonError {
    // A second copy says why in the log, but leaves no startup error: the first is fine.
    if case .alreadyServing = e { Pratico.log("pratico-daemon: \(e)"); exit(1) }
    fail("\(e)")
} catch { fail("\(error)") }
try? FileManager.default.removeItem(at: Pratico.startupErrorPath(home: home))
Pratico.log("pratico-daemon: listening on \(daemon.socketPath)")

// Clean shutdown removes the socket (SPEC FR-2, NFR-6).
var sources: [DispatchSourceSignal] = []
for sig in [SIGTERM, SIGINT] {
    signal(sig, SIG_IGN)
    let s = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    s.setEventHandler {
        daemon.stop()
        exit(0)
    }
    s.resume()
    sources.append(s)
}
dispatchMain()
