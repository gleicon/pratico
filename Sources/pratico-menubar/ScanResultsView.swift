import PraticoCore
import SwiftUI

/// `GET /pratico/scans`: each image's latest report and verdict.
struct ScanResult: Decodable, Identifiable, Equatable {
    struct Run: Decodable, Equatable {
        var name: String
        var ran: Bool
        var note: String
    }
    struct Finding: Decodable, Identifiable, Equatable {
        var advisory: String
        var sources: [String]
        var package: String
        var version: String
        var fixed: [String]
        var severity: String
        var cvss: Double?
        var malicious: Bool
        var kev: Bool
        /// One advisory often hits several packages; a row is the three together, which the
        /// daemon reports once each. Keyed by the advisory alone, the table repeated rows.
        var id: String { "\(advisory) \(package) \(version)" }

        enum CodingKeys: String, CodingKey {
            case advisory = "id"
            case sources, package, version, fixed, severity, cvss, malicious, kev
        }
    }
    struct Report: Decodable, Equatable {
        var time: Date
        var scanners: [Run]
        var findings: [Finding]
    }
    var Id: String
    var Name: String
    var Scanning: Bool
    var Verdict: String?
    var Reasons: [String]?
    var Blocked: Bool?
    var Report: Report?

    var id: String { Id }

    /// The finding's `sources` use short tags; runs use the scanner's name.
    static func scannerName(_ source: String) -> String { source == "osv" ? "osv-scanner" : source }
}

/// Which scanner found what: images on the left, their scanners and findings on the right.
struct ScanResultsView: View {
    let daemon: DaemonController
    @State private var results: [ScanResult] = []
    @State private var selection: String?

    var body: some View {
        // A plain split: NavigationSplitView came up blank in a window a menubar app opens.
        VStack(spacing: 0) {
        Text("⛔︎ blocked by scan_block   ⚠︎ critical or high vulnerabilities, malware, or exploited (KEV)   ✓ none of those (medium and low are still listed)   – not scanned")
            .font(.caption).foregroundStyle(.secondary).lineLimit(2).padding(8).frame(maxWidth: .infinity, alignment: .leading)
        Divider()
        HStack(spacing: 0) {
            List(results, selection: $selection) { r in
                HStack {
                    Text(badge(r))
                    Text(r.Name).lineLimit(1)
                }
                .tag(r.id)
            }
            .frame(width: 240)
            Divider()
            Group {
                if let r = results.first(where: { $0.id == selection }) {
                    detail(r)
                } else {
                    Text(results.isEmpty ? "No images yet" : "Select an image").foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        }
        .toolbar {
            Button {
                daemon.scanNow()
            } label: {
                Label(daemon.scanNowTitle, systemImage: "arrow.clockwise")
            }
            .labelStyle(.titleAndIcon)
            .disabled(!daemon.canScanNow)
            .help("Scan every image again with every installed scanner")
        }
        .frame(minWidth: 820, minHeight: 440)
        // Refetches whenever the daemon's change counter moves: a scan starting or
        // finishing, an image pulled or removed, from here, the menu, or the docker CLI.
        .task(id: daemon.status?.Changes) {
            let fresh = await Self.fetch()
            if fresh != results { results = fresh }
            if selection == nil || !results.contains(where: { $0.id == selection }) { selection = results.first?.id }
        }
    }

    /// Same rule as the menubar: ⚠︎ only for critical or high findings, malware, or KEV.
    private func badge(_ r: ScanResult) -> String {
        if r.Scanning { return "…" }
        if r.Blocked == true { return "⛔︎" }
        guard let findings = r.Report?.findings, r.Verdict != "unknown" else { return "–" }  // not scanned, or no scanner ran
        return findings.contains(where: Self.isSevere) ? "⚠︎" : "✓"
    }

    static func isSevere(_ f: ScanResult.Finding) -> Bool {
        f.severity == "critical" || f.severity == "high" || f.malicious || f.kev
    }

    @ViewBuilder private func detail(_ r: ScanResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(r.Name).font(.title2)
            if r.Scanning { Text("Scanning…").foregroundStyle(.secondary) }
            if let report = r.Report {
                Text("Scanned \(report.time.formatted(date: .abbreviated, time: .shortened))").foregroundStyle(.secondary)
                // By severity, so the flag's rule is visible next to the numbers.
                Text(["critical", "high", "medium", "low", "unknown"].map { sev in
                    "\(sev.capitalized) \(report.findings.filter { $0.severity == sev }.count)"
                }.joined(separator: " · "))
                // Each scanner: whether it ran, and how many findings it reported.
                HStack(spacing: 16) {
                    ForEach(report.scanners, id: \.name) { run in
                        let count = report.findings.filter { $0.sources.map(ScanResult.scannerName).contains(run.name) }.count
                        Text(run.ran ? "✓ \(run.name): \(count)" : "✗ \(run.name): \(run.note)")
                            .foregroundStyle(run.ran ? Color.primary : Color.secondary)
                            .lineLimit(1).truncationMode(.tail).help(run.note)
                    }
                }
                // A few reasons up top, the rest in the tooltip: the table below has them all.
                let reasons = r.Reasons ?? []
                ForEach(Array(reasons.prefix(3).enumerated()), id: \.offset) {
                    Text("⚠︎ " + $0.element).lineLimit(1).truncationMode(.tail)
                }
                .help(reasons.joined(separator: "\n"))
                if reasons.count > 3 {
                    Text("… and \(reasons.count - 3) more, in the table below").foregroundStyle(.secondary).help(reasons.joined(separator: "\n"))
                }
                Table(report.findings.sorted { rank($0) > rank($1) }) {
                    TableColumn("Advisory") { f in Text(f.advisory).textSelection(.enabled) }
                    TableColumn("Package") { f in Text("\(f.package) \(f.version)").lineLimit(1).help("\(f.package) \(f.version)") }
                    TableColumn("Severity") { f in Text(f.severity + (f.cvss.map { String(format: " %.1f", $0) } ?? "")) }
                        .width(90)
                    TableColumn("Found by") { f in Text(f.sources.map(ScanResult.scannerName).sorted().joined(separator: ", ")).lineLimit(1) }
                    TableColumn("Flags") { f in Text([f.malicious ? "malware" : nil, f.kev ? "exploited (KEV)" : nil].compactMap { $0 }.joined(separator: ", ")) }
                    TableColumn("Fixed in") { f in Text(f.fixed.joined(separator: ", ")).lineLimit(1).help(f.fixed.joined(separator: "\n")) }
                }
                .frame(maxHeight: .infinity)  // the table scrolls; the header above stays put
            } else if !r.Scanning {
                Text("Not scanned yet. Scan Now scans it with every installed scanner.").foregroundStyle(.secondary)
            }
        }
        .padding()
    }

    private func rank(_ f: ScanResult.Finding) -> Int {
        (f.malicious ? 100 : 0) + (f.kev ? 50 : 0) + (["critical": 4, "high": 3, "medium": 2, "low": 1][f.severity] ?? 0)
    }

    static func fetch() async -> [ScanResult] {
        await DaemonProbe.fetch("/pratico/scans", as: [ScanResult].self, timeout: 10) ?? []
    }
}
