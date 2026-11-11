import Foundation
import PraticoCore
import os

// Root helper (launchd daemon dev.pratico.socket, registered by Pratico.app through
// SMAppService): keeps /var/run/docker.sock linked to pratico's socket while it is
// registered, and removes the link when unregistered. It never opens the socket; it only
// makes or removes one symlink in /var/run.
let log = Logger(subsystem: "dev.pratico.socket", category: "link")

// The link serves the user who owns the app bundle; pratico is a per-user app.
let bundle = Bundle.main.bundleURL
var st = stat()
guard bundle.pathExtension == "app", stat(bundle.path, &st) == 0, st.st_uid != 0, let pw = getpwuid(st.st_uid) else {
    log.error("pratico-socket-link: \(bundle.path, privacy: .public) is not a user's Pratico.app; not linking")
    exit(1)
}
let target = Pratico.socketPath(home: Pratico.home(for: URL(filePath: String(cString: pw.pointee.pw_dir), directoryHint: .isDirectory))).path

func claim() {
    switch DefaultSocket.claim(target: target) {
    case .ours: break
    case .absent: log.error("pratico-socket-link: cannot link \(DefaultSocket.path, privacy: .public)")
    case .other(let owner): log.info("pratico-socket-link: \(DefaultSocket.path, privacy: .public) is taken (\(owner, privacy: .public))")
    }
}

// Unregistering (the menubar toggle) or shutdown sends SIGTERM.
signal(SIGTERM, SIG_IGN)
let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
term.setEventHandler {
    DefaultSocket.release(target: target)
    exit(0)
}
term.resume()

// Retakes the path when someone else's link goes away (Docker Desktop quits) or the link
// is deleted.
let timer = DispatchSource.makeTimerSource(queue: .main)
timer.schedule(deadline: .now(), repeating: .seconds(30))
timer.setEventHandler(handler: claim)
timer.resume()
dispatchMain()
