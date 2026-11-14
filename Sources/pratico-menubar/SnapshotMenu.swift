import AppKit
import PraticoCore
import SwiftUI
import UniformTypeIdentifiers

/// `POST /pratico/snapshots/restore`: what was (or, in a dry run, would be) recreated.
struct RestoreReport: Decodable {
    struct Item: Decodable {
        var Kind: String
        var Name: String
        var Reason: String?
        var Error: String?
    }
    struct Names: Decodable {
        var Volumes: [String]
        var Networks: [String]
        var Containers: [String]
    }
    /// A container as the snapshot would make it, and what it could do to this Mac.
    struct Review: Decodable {
        var Name: String
        var Image: String
        var Command: String
        var Running: Bool
        var Risks: [String]
    }
    var Created: Names
    var Started: [String]
    var Skipped: [Item]
    var Failed: [Item]
    var Review: [Review]

    var lines: [String] {
        var out: [String] = []
        for (kind, names) in [("volume", Created.Volumes), ("network", Created.Networks), ("container", Created.Containers)] {
            out += names.map { "\(kind) \($0)" + (Started.contains($0) && kind == "container" ? " (started)" : "") }
        }
        out += Skipped.map { "skipped \($0.Kind) \($0.Name): \($0.Reason ?? "exists")" }
        out += Failed.map { "failed \($0.Kind) \($0.Name): \($0.Error ?? "")" }
        return out
    }
}

/// FR-32's snapshot and restore: definitions of every container, network, and volume, as
/// a `.tar.gz` of JSON in `~/.pratico/snapshots` (FR-35); restoring asks first, showing what
/// it would create and what it would skip.
struct SnapshotMenu: View {
    let daemon: DaemonController

    var body: some View {
        Menu("Snapshot") {
            Button("Take Snapshot") { daemon.takeSnapshot() }
            Button("Restore from Snapshot…") { daemon.restoreSnapshot() }
            Divider()
            Button("Show Snapshots in Finder") {
                let dir = Pratico.home().appending(path: "snapshots", directoryHint: .isDirectory)
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                NSWorkspace.shared.open(dir)
            }
        }
    }
}

extension DaemonController {
    func takeSnapshot() {
        Task {
            let r = await Task.detached { DaemonProbe.request("POST", "/pratico/snapshots", timeout: 60) }.value
            let body = r.flatMap { try? JSONSerialization.jsonObject(with: $0.body) as? [String: Any] } ?? [:]
            guard let r, r.status == 201, let path = body["Path"] as? String else {
                report("Snapshot failed", body["message"] as? String ?? "The daemon did not answer.")
                return
            }
            let counts = ["Containers", "Networks", "Volumes"].map { "\(body[$0] as? Int ?? 0) \($0.lowercased())" }
            let alert = NSAlert()
            alert.messageText = "Snapshot taken"
            alert.informativeText = "\(counts.joined(separator: ", ")) in \((path as NSString).abbreviatingWithTildeInPath).\n\nIt holds definitions only: images come back from their registries, and volume data is not copied."
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Show in Finder")
            NSApp.activate()
            if alert.runModal() == .alertSecondButtonReturn { NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: path)]) }
        }
    }

    /// Pick a file, see what it would do (a dry run), confirm, restore, see what it did.
    func restoreSnapshot() {
        let panel = NSOpenPanel()
        panel.directoryURL = Pratico.home().appending(path: "snapshots", directoryHint: .isDirectory)
        panel.allowedContentTypes = [UTType(filenameExtension: "gz") ?? .data]
        panel.message = "Choose a pratico snapshot to restore"
        NSApp.activate()
        guard panel.runModal() == .OK, let file = panel.url else { return }
        Task {
            guard let plan = await restore(file, dryRun: true) else { return }
            guard !plan.Created.Containers.isEmpty || !plan.Created.Networks.isEmpty || !plan.Created.Volumes.isEmpty else {
                report("Nothing to restore", (["Everything in this snapshot is already here."] + plan.lines).joined(separator: "\n"))
                return
            }
            guard let start = confirmRestore(file, plan) else { return }
            guard let done = await restore(file, dryRun: false, start: start) else { return }
            report(done.Failed.isEmpty ? "Restored" : "Restored, with problems", Self.listed(done.lines))
            await refreshContainers()
        }
    }

    /// Every container it would make, with its image, command, and anything that reaches
    /// beyond it (Mac folders, published ports, privileges): a snapshot can come from
    /// anywhere. Starting them is a separate choice. nil is Cancel, else whether to start.
    private func confirmRestore(_ file: URL, _ plan: RestoreReport) -> Bool? {
        var text = Self.listed(plan.lines.filter { !$0.hasPrefix("container ") })
        for c in plan.Review {
            text += "\n\ncontainer \(c.Name): \(c.Image) \(c.Command)"
            text += c.Risks.map { "\n⚠︎ \($0)" }.joined()
        }
        text += "\n\nExisting containers, networks, and volumes are left as they are. Only restore snapshots you trust."
        let running = plan.Review.filter(\.Running).count
        let alert = NSAlert()
        alert.messageText = "Restore \(file.lastPathComponent)?"
        alert.informativeText = text
        alert.alertStyle = plan.Review.contains { !$0.Risks.isEmpty } ? .warning : .informational
        alert.addButton(withTitle: "Restore")
        if running > 0 { alert.addButton(withTitle: "Restore and Start \(running)") }
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        switch alert.runModal() {
        case .alertFirstButtonReturn: return false
        case .alertSecondButtonReturn where running > 0: return true
        default: return nil
        }
    }

    private func restore(_ file: URL, dryRun: Bool, start: Bool = false) async -> RestoreReport? {
        let query = file.path.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        let flags = (dryRun ? "&dry_run=1" : "") + (start ? "&start=1" : "")
        let r = await Task.detached {
            DaemonProbe.request("POST", "/pratico/snapshots/restore?path=\(query)\(flags)", timeout: 300)
        }.value
        guard let r, r.status == 200, let report = try? JSONDecoder().decode(RestoreReport.self, from: r.body) else {
            let message = r.flatMap { try? JSONSerialization.jsonObject(with: $0.body) as? [String: Any] }?["message"] as? String
            self.report("Cannot restore \(file.lastPathComponent)", message ?? "The daemon did not answer.")
            return nil
        }
        return report
    }

    private static func listed(_ lines: [String]) -> String {
        lines.prefix(20).joined(separator: "\n") + (lines.count > 20 ? "\n… and \(lines.count - 20) more" : "")
    }

    private func report(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        NSApp.activate()
        alert.runModal()
    }
}
