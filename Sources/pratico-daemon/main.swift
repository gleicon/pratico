import Foundation
import PraticoCore
import PraticoDaemonKit

// Started by Pratico.app's launch agent, never by the user directly (SPEC D-13); its
// output goes to `~/.pratico/daemon.log`.
// `--home <dir>` relocates all state (the e2e suite uses a temporary home).

var home = Pratico.home()

/// Exits, leaving the reason in `daemon.err` for the menubar to show (SPEC FR-3).
@MainActor func fail(_ message: String, code: Int32 = 1) -> Never {
    Pratico.log("pratico-daemon: \(message)")
    try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    try? Data((message + "\n").utf8).write(to: Pratico.startupErrorPath(home: home))
    exit(code)
}

var args = Array(CommandLine.arguments.dropFirst())

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
    default:
        fail("unknown argument \(arg)", code: 2)
    }
}

Pratico.log("pratico-daemon: \(Pratico.version) starting, home \(home.path)")

// FR-37/FR-38: defaults when absent; refuse to start on unknown keys or bad values.
let config: Config
do { config = try Config.load(home: home) } catch { fail("\(error)", code: 4) }

let runtime = AppleContainer()
// The embedded runtime (docs/design/runtime.md) needs no Apple `container` install.
let embedded = ProcessInfo.processInfo.environment["PRATICO_RUNTIME"] == "embedded"
if !embedded {
    guard runtime.isInstalled else { fail("Apple container runtime not installed (\(runtime.binary))", code: 3) }
    guard runtime.serviceRunning else { fail("Apple container runtime is not running; run `container system start`", code: 3) }
}

// A child that exits before reading its stdin must not take the daemon down with it.
signal(SIGPIPE, SIG_IGN)

let daemon: Daemon
do { daemon = try Daemon(home: home, config: config, runtime: runtime) } catch { fail("\(error)", code: 4) }
do { try daemon.start() } catch { fail("\(error)") }
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
