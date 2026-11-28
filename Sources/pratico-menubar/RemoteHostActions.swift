import AppKit
import PraticoCore
import PraticoRemote

/// What the Docker Host menu says about a Linux host, and what each problem offers. ssh's own
/// files stay the user's: pratico reads `~/.ssh/config` and `known_hosts` and never writes
/// them; the one thing kept here is the path of a key chosen for a host (HostKeys).
extension DaemonController {
    nonisolated static func summarize(_ endpoint: String, context: String) async -> RemoteSummary {
        do {
            var target = try SSHTarget.resolve(endpoint)
            if let chosen = HostKeys().identity(for: context) { target.identityFiles.insert(chosen, at: 0) }
            let r = try await RemoteHost.get(["/version", "/pratico/status", "/pratico/alerts"], on: target)
            let dec = JSONDecoder()
            dec.dateDecodingStrategy = .iso8601
            guard r[1].status == 200, let status = try? dec.decode(Status.self, from: r[1].body) else {
                let version = (try? JSONSerialization.jsonObject(with: r[0].body) as? [String: Any])?["Version"] as? String
                return RemoteSummary(line: RemoteHost.Failure.Kind.notPratico.headline ?? "", problem: .notPratico,
                                     detail: "\(target.alias) answers, but not as pratico\(version.map { " (Docker \($0))" } ?? "").")
            }
            let alerts = (try? JSONSerialization.jsonObject(with: r[2].body) as? [Any])?.count ?? 0
            var line = "pratico \(status.Version) · \(status.ContainersRunning) of \(status.Containers) running"
            if alerts > 0 { line += " · \(alerts) alert\(alerts == 1 ? "" : "s")" }
            return RemoteSummary(line: line)
        } catch let failure as RemoteHost.Failure {
            return RemoteSummary(line: failure.kind.headline ?? failure.description, problem: failure.kind, detail: failure.description)
        } catch {
            return RemoteSummary(line: "\(error)", problem: .other, detail: "\(error)")
        }
    }

    /// The key chosen in this menu for `context`, as `~/…`; nil when ssh's config decides.
    func chosenKey(for context: String) -> String? {
        HostKeys().identity(for: context).map { ($0 as NSString).abbreviatingWithTildeInPath }
    }

    /// The standard file panel, in `~/.ssh`. Only a key pratico can sign with is kept, and only
    /// its path.
    func chooseKey(for context: String) {
        let panel = NSOpenPanel()
        panel.message = "Choose the private key pratico signs in to \(context) with: ed25519 or ECDSA, without a passphrase"
        panel.prompt = "Use Key"
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".ssh")
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            _ = try OpenSSHKey.load(url.path)
            try HostKeys().setIdentity(url.path, for: context)
        } catch {
            Dialogs.report("pratico cannot use \(url.lastPathComponent)", "\(error)")
            return
        }
        Task { await refreshRemote() }
    }

    func forgetKey(for context: String) {
        guard let key = chosenKey(for: context),
              Dialogs.confirm("Stop using \(key) for \(context)?",
                              "pratico goes back to the keys ~/.ssh/config gives this host, as ssh does. The key file stays.",
                              button: "Stop Using") else { return }
        do {
            try HostKeys().setIdentity(nil, for: context)
        } catch {
            Dialogs.report("Could not forget the key", "\(error)")
        }
        Task { await refreshRemote() }
    }

    /// What fixes `summary.problem` on `context`, in the user's own Terminal.
    func explain(_ summary: RemoteSummary, context: String, endpoint: String) {
        guard let target = try? SSHTarget.resolve(endpoint), let problem = summary.problem else {
            Dialogs.report(context, summary.detail)
            return
        }
        let ssh = "ssh \(target.port == 22 ? "" : "-p \(target.port) ")\(target.user)@\(target.alias)"
        switch problem {
        case .unknownHostKey:
            showCommands(
                title: "Trust \(context)'s host key",
                text: """
                    pratico checks host keys against known_hosts, as ssh does, and never adds one itself. \
                    Connect once with ssh, compare the fingerprint it shows with the server's own \
                    (ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub there, or your provider's console), \
                    and answer yes only if they match.
                    """,
                commands: "\(ssh) true")
        case .changedHostKey:
            let entry = target.port == 22 ? target.hostName : "[\(target.hostName)]:\(target.port)"
            showCommands(
                title: "\(context)'s host key changed",
                text: """
                    The server's key is not the one known_hosts has: the server was reinstalled, or someone \
                    is between this Mac and it. pratico refuses it, as ssh does. Ask whoever runs the server \
                    for its new fingerprint; only when it matches, remove the old entry and trust the new one.
                    """,
                commands: """
                    # Only after checking the new fingerprint:
                    ssh-keygen -R '\(entry)'
                    \(ssh) true
                    """)
        case .noUsableKey:
            let name = "pratico_\(target.alias.filter { $0.isLetter || $0.isNumber || $0 == "-" })"
            showCommands(
                title: "No SSH key pratico can use for \(context)",
                text: """
                    \(summary.detail)

                    pratico's SSH signs with ed25519 or ECDSA key files that have no passphrase; RSA keys, \
                    passphrases and ssh-agent wait on swift-nio-ssh, the SSH library it uses. A key made for \
                    this host alone keeps that exposure small. Then choose it with Choose SSH Key…, or name \
                    it in ~/.ssh/config as IdentityFile.
                    """,
                commands: """
                    ssh-keygen -t ed25519 -N '' -C pratico -f ~/.ssh/\(name)
                    ssh-copy-id -i ~/.ssh/\(name).pub \(target.port == 22 ? "" : "-p \(target.port) ")\(target.user)@\(target.alias)
                    """)
        case .notPratico:
            Dialogs.report("\(context) is not running pratico for \(target.user)", """
                \(summary.detail)

                Install pratico there (Add a Linux Host… shows how). If it is installed, \(target.user) needs \
                the pratico group: the installer adds the user who ran sudo; open a new SSH session after.
                """)
        case .unreachable, .other:
            Dialogs.report("Cannot use \(context)", summary.detail)
        }
    }
}

extension RemoteHost.Failure.Kind {
    /// A few words for the menu; the full reason is a click away. nil: the reason itself.
    var headline: String? {
        switch self {
        case .unreachable: "Cannot reach the host"
        case .unknownHostKey: "Host key not trusted yet"
        case .changedHostKey: "Host key changed: refused"
        case .noUsableKey: "No SSH key pratico can use"
        case .notPratico: "pratico is not installed or not allowed"
        case .other: nil
        }
    }

    /// The menu item that explains the problem and what fixes it.
    var action: String {
        switch self {
        case .unknownHostKey: "Trust This Host…"
        case .changedHostKey: "Why the Host Key Changed…"
        case .noUsableKey: "Make an SSH Key…"
        case .notPratico: "Why pratico Does Not Answer…"
        case .unreachable, .other: "Show Details…"
        }
    }
}
