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
        var id: String
        var sources: [String]
        var package: String
        var version: String
        var fixed: [String]
        var severity: String
        var cvss: Double?
        var malicious: Bool
        var kev: Bool
        var rowID: String { id + package + version }
    }
    struct Report: Decodable, Equatable {
        var time: Date
        var scanners: [Run]
        var findings: [Finding]
    }
    var Id: String
    var Tags: [String]
    var Scanning: Bool
    var Verdict: String?
    var Reasons: [String]?
    var Blocked: Bool?
    var Report: Report?

    var id: String { Id }
    var name: String { Tags.first ?? String(Id.dropFirst(7).prefix(12)) }

    /// The finding's `sources` use short tags; runs use the scanner's name.
    static func scannerName(_ source: String) -> String { source == "osv" ? "osv-scanner" : source }
}

/// Which scanner found what: images on the left, their scanners and findings on the right.
struct ScanResultsView: View {
    let daemon: DaemonController
    @State private var results: [ScanResult] = []
    @State private var selection: String?

    var body: some View {
        NavigationSplitView {
            List(results, selection: $selection) { r in
                HStack {
                    Text(badge(r))
                    Text(r.name).lineLimit(1)
                }
                .tag(r.id)
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        } detail: {
            if let r = results.first(where: { $0.id == selection }) {
                detail(r)
            } else {
                Text(results.isEmpty ? "No images yet" : "Select an image").foregroundStyle(.secondary)
            }
        }
        .toolbar {
            Button {
                daemon.scanNow()
            } label: {
                Label("Scan Now", systemImage: "arrow.clockwise")
            }
            .help("Scan every image again with every installed scanner")
        }
        .frame(minWidth: 820, minHeight: 440)
        .task {
            // Refreshes while open, so queued scans show their results as they finish.
            while !Task.isCancelled {
                let fresh = await Self.fetch()
                if fresh != results { results = fresh }
                if selection == nil { selection = results.first?.id }
                try? await Task.sleep(for: .seconds(results.contains(where: \.Scanning) ? 2 : 10))
            }
        }
    }

    private func badge(_ r: ScanResult) -> String {
        if r.Scanning { return "…" }
        if r.Blocked == true { return "⛔︎" }
        switch r.Verdict {
        case "serious", "warning": return "⚠︎"
        case "ok": return "✓"
        default: return "–"  // never scanned, or no scanner ran
        }
    }

    @ViewBuilder private func detail(_ r: ScanResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(r.name).font(.title2)
            if r.Scanning { Text("Scanning…").foregroundStyle(.secondary) }
            if let report = r.Report {
                Text("Scanned \(report.time.formatted(date: .abbreviated, time: .shortened))").foregroundStyle(.secondary)
                // Each scanner: whether it ran, and how many findings it reported.
                HStack(spacing: 16) {
                    ForEach(report.scanners, id: \.name) { run in
                        let count = report.findings.filter { $0.sources.map(ScanResult.scannerName).contains(run.name) }.count
                        Text(run.ran ? "✓ \(run.name): \(count)" : "✗ \(run.name): \(run.note)")
                            .foregroundStyle(run.ran ? Color.primary : Color.secondary)
                    }
                }
                ForEach(r.Reasons ?? [], id: \.self) { Text("⚠︎ " + $0) }
                Table(report.findings.sorted { rank($0) > rank($1) }) {
                    TableColumn("Advisory") { f in Text(f.id).textSelection(.enabled) }
                    TableColumn("Package") { f in Text("\(f.package) \(f.version)") }
                    TableColumn("Severity") { f in Text(f.severity + (f.cvss.map { String(format: " %.1f", $0) } ?? "")) }
                        .width(90)
                    TableColumn("Found by") { f in Text(f.sources.map(ScanResult.scannerName).sorted().joined(separator: ", ")) }
                    TableColumn("Flags") { f in Text([f.malicious ? "malware" : nil, f.kev ? "exploited (KEV)" : nil].compactMap { $0 }.joined(separator: ", ")) }
                    TableColumn("Fixed in") { f in Text(f.fixed.joined(separator: ", ")) }
                }
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
        await Task.detached {
            guard let r = DaemonProbe.request("GET", "/pratico/scans", timeout: 10), r.status == 200 else { return [] }
            let dec = JSONDecoder()
            dec.dateDecodingStrategy = .iso8601
            return (try? dec.decode([ScanResult].self, from: r.body)) ?? []
        }.value
    }
}
