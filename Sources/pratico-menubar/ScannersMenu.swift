import AppKit
import PraticoCore
import SwiftUI

/// `GET /pratico/scanners`: which image scanners pratico finds, like `flutter doctor`.
struct ScannerReport: Decodable, Equatable {
    struct Scanner: Decodable, Equatable, Identifiable {
        var name: String
        var builtin: Bool
        var path: String?
        var version: String?
        var brew: String?
        var homepage: String
        var id: String { name }
    }
    var enabled: Bool
    var brew: String?
    var scanners: [Scanner]

    var missing: [Scanner] { scanners.filter { $0.path == nil } }
}

/// The checkup and what to do about it: install with Homebrew, or bring your own scanner.
struct ScannersMenu: View {
    let daemon: DaemonController

    var body: some View {
        if let r = daemon.scanners {
            Menu(r.missing.isEmpty || !r.enabled ? "Scanners" : "Scanners ⚠︎") {
                if !r.enabled { Text("Scanning is off (Settings › Scanning)") }
                ForEach(r.scanners) { s in
                    if s.path != nil {
                        Text("✓ \(s.name)  \(s.version ?? "")").help(s.path ?? "")
                    } else {
                        Text("✗ \(s.name): \(s.builtin ? "not installed" : "not found or not executable")")
                    }
                }
                Divider()
                Button(daemon.scanNowTitle) { daemon.scanNow() }.disabled(!daemon.canScanNow)
                Divider()
                Button("Install Missing Scanners…") { daemon.showScannerInstall() }
                    .disabled(r.missing.allSatisfy { !$0.builtin })
                ManageScannersButton()
                Button("Check Again") { Task { await daemon.refreshScanners() } }
            }
        }
    }
}

/// Settings › Scanners, where your own scanners are added and removed.
struct ManageScannersButton: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button("Add or Remove Scanners…") {
            UserDefaults.standard.set("scanners", forKey: SettingsView.tabKey)
            NSApp.activate()
            openSettings()
        }
    }
}

/// Opens the Scan Results window in front: a menubar app is never frontmost on its own.
struct ScanResultsButton: View {
    var title = "Scan Results…"
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(title) {
            NSApp.activate()
            openWindow(id: "scan-results")
        }
    }
}

/// `GET /pratico/scans/summary`.
struct ScanSummary: Decodable, Equatable {
    var Images: Int
    var Blocked: Int
    var CriticalOrHigh: Int
    var Scanning: Int
    var Unscanned: Int
}

extension DaemonController {
    /// Every image, with every installed scanner, now. The menu and Scan Results share this
    /// and the summary it refreshes, so both show the scan the moment either starts it.
    func scanNow() {
        Task {
            _ = await Task.detached { DaemonProbe.request("POST", "/pratico/scans", timeout: 10) }.value
            await refreshScanSummary()
        }
    }

    var scanNowTitle: String {
        guard let n = scanSummary?.Scanning, n > 0 else { return "Scan All Images Now" }
        return "Scanning \(n) image\(n == 1 ? "" : "s")…"
    }

    /// Off while a scan runs (another would only queue the same images) or scanning is off.
    var canScanNow: Bool { scanners?.enabled != false && (scanSummary?.Scanning ?? 0) == 0 }

    /// Homebrew commands for what is missing, or how to get Homebrew, or each project's page.
    func showScannerInstall() {
        guard let r = scanners else { return }
        let missing = r.missing.filter(\.builtin)
        let brewLine = "brew install " + missing.compactMap(\.brew).joined(separator: " ")
        let pages = missing.map { "# \($0.name): \($0.homepage)" }.joined(separator: "\n")
        if r.brew != nil {
            showCommands(
                title: "Install image scanners",
                text: """
                    Pratico scans every image it pulls with the scanners it finds, and blocks images \
                    with malware or exploited vulnerabilities. Run this in Terminal, then Check Again.
                    """,
                commands: brewLine + "\n\n" + pages)
        } else {
            showCommands(
                title: "Install image scanners",
                text: """
                    Homebrew is not installed. It is the simplest way to get the scanners: install it \
                    from https://brew.sh (one command in Terminal), then run the second command. Or \
                    install each scanner from its own page.
                    """,
                commands: #"/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)""#
                    + "\n" + brewLine + "\n\n" + pages)
        }
    }

    /// The `scan_custom` contract, with a working example.
    func showCustomScannerHelp() {
        showCommands(
            title: "Add your own scanner",
            text: """
                Any executable can scan images: add it under Settings › Scanners (it is scan_custom \
                in config.toml). Pratico runs it as `<path> <image.tar>` (a Docker archive) \
                with PRATICO_IMAGE_ID and PRATICO_IMAGE_REFS set. It must exit 0 and print JSON \
                findings; severity is critical, high, medium, low, or unknown, and "malicious": true \
                marks malware. Its findings join the others and follow scan_block.
                """,
            commands: """
                #!/bin/sh
                # my-scanner: $1 is the image archive
                echo '{"findings": [
                  {"id": "CVE-2024-0001", "package": "openssl", "version": "3.0.1",
                   "severity": "high", "fixed": ["3.0.2"], "cvss": 7.5},
                  {"id": "MAL-ACME-7", "package": "evil-pkg", "version": "6.6.6",
                   "severity": "critical", "malicious": true}
                ]}'

                # config.toml
                scan_custom = ["~/bin/my-scanner"]
                """)
    }

    func refreshScanners() async {
        let report = await Task.detached { () -> ScannerReport? in
            guard let r = DaemonProbe.request("GET", "/pratico/scanners", timeout: 30), r.status == 200 else { return nil }
            return try? JSONDecoder().decode(ScannerReport.self, from: r.body)
        }.value
        if report != scanners { scanners = report }
    }
}
