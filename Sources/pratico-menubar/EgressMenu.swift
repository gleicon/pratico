import AppKit
import PraticoCore
import SwiftUI

/// `GET /pratico/egress/feeds`: the threat feeds egress protection matches (D-51).
struct EgressReport: Decodable, Equatable {
    struct Feed: Decodable, Equatable, Identifiable {
        var Name: String
        var NeedsKey: Bool
        var Entries: Int
        var Updated: String?
        var Error: String?
        var id: String { Name }
    }
    var Block: Bool
    var Key: Bool
    var Feeds: [Feed]
}

/// Threat feeds and the abuse.ch key; containers' connections are in Containers.
struct EgressMenu: View {
    let daemon: DaemonController

    var body: some View {
        if let r = daemon.egress {
            Menu("Threat Feeds") {
                Text(r.Block ? "Listed destinations are refused" : "Listed destinations alert only (egress_block = false)")
                ForEach(r.Feeds) { f in
                    if f.NeedsKey && !r.Key {
                        Text("○ \(f.Name): needs an abuse.ch key")
                    } else if let e = f.Error, f.Entries == 0 {
                        Text("✗ \(f.Name): \(e)")
                    } else {
                        Text("✓ \(f.Name): \(f.Entries) entries")
                    }
                }
                Divider()
                Button(r.Key ? "Replace abuse.ch Key…" : "Add abuse.ch Key…") { daemon.askEgressKey() }
                if r.Key { Button("Remove abuse.ch Key") { daemon.removeEgressKey() } }
            }
        }
    }
}

extension DaemonController {
    func refreshEgress() async {
        let report = await DaemonProbe.fetch("/pratico/egress/feeds", as: EgressReport.self, timeout: 5)
        if report != egress { egress = report }
    }

    /// The key goes to the daemon, which keeps it in the Keychain, never in config.toml.
    func askEgressKey() {
        let alert = NSAlert()
        alert.messageText = "abuse.ch Auth-Key"
        alert.informativeText = "URLhaus and ThreatFox (malware hosts, C2 servers) need a free key from auth.abuse.ch. Pratico keeps it in the Keychain and fetches the feeds on this Mac."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let key = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, let body = try? JSONSerialization.data(withJSONObject: ["key": key]) else { return }
        Task {
            if case .failure(let e) = await DaemonProbe.send("POST", "/pratico/egress/key", body: body) { show(error: e.description) }
            await refreshEgress()
        }
    }

    func removeEgressKey() {
        Task {
            if case .failure(let e) = await DaemonProbe.send("DELETE", "/pratico/egress/key") { show(error: e.description) }
            await refreshEgress()
        }
    }

    private func show(error: String) {
        let alert = NSAlert()
        alert.messageText = "abuse.ch key"
        alert.informativeText = error
        NSApp.activate()
        alert.runModal()
    }
}
