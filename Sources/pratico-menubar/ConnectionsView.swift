import AppKit
import PraticoCore
import SwiftUI

/// `GET /pratico/egress`: each container's flows past its networks, with the process that
/// opened each TCP one where the flight recorder saw it (D-51, D-57).
struct ContainerConnections: Decodable, Equatable, Sendable {
    struct Flow: Decodable, Equatable, Sendable {
        var Time: String
        var Proto: String
        var Address: String
        var Port: Int
        var SourcePort: Int?
        var Name: String?
        var Blocked: Bool
        var Reason: String?
        var Command: String?
        var Pid: Int?
    }
    var Id: String
    var Name: String
    var Flows: [Flow]
}

/// One table row: the same process reaching the same destination the same way, folded,
/// so a client retrying a hundred times is one line with its count.
struct ConnectionRow: Identifiable, Hashable {
    var container: String
    var process: String
    var destination: String
    var port: Int
    var proto: String
    var blocked: Bool
    var reason: String?
    var count = 0
    var first = Date.distantFuture
    var last = Date.distantPast
    var addresses: Set<String> = []
    var pids: Set<Int> = []
    var sourcePorts: Set<Int> = []

    var id: String { [container, process, destination, String(port), proto, blocked ? "refused" : "allowed"].joined(separator: "\u{1F}") }
    var result: String { blocked ? "Refused" : "Allowed" }

    /// Rows from flows, newest first. Flows are bounded by the daemon (2,000 per container).
    static func fold(_ all: [ContainerConnections]) -> [ConnectionRow] {
        var rows: [String: ConnectionRow] = [:]
        for c in all {
            for f in c.Flows {
                var row = ConnectionRow(container: c.Name, process: f.Command ?? "", destination: f.Name ?? f.Address,
                                        port: f.Port, proto: f.Proto, blocked: f.Blocked, reason: f.Reason)
                row = rows[row.id] ?? row
                let time = (try? Date(f.Time, strategy: .iso8601.year().month().day().time(includingFractionalSeconds: true))) ?? .distantPast
                row.count += 1
                row.first = min(row.first, time)
                row.last = max(row.last, time)
                row.addresses.insert(f.Address)
                if let pid = f.Pid { row.pids.insert(pid) }
                if let port = f.SourcePort, port > 0 { row.sourcePorts.insert(port) }
                if f.Reason != nil { row.reason = f.Reason }
                rows[row.id] = row
            }
        }
        return rows.values.sorted { $0.last > $1.last }
    }
}

/// Where containers connected: containers on the left, their connections in a table, the
/// selected one's details below it.
struct ConnectionsView: View {
    let daemon: DaemonController
    @State private var all: [ContainerConnections] = []
    @State private var container: String? = Self.everyContainer
    @State private var selection: ConnectionRow.ID?
    @State private var search = ""
    @State private var refusedOnly = false
    @State private var order = [KeyPathComparator(\ConnectionRow.last, order: .reverse)]

    static let everyContainer = "\u{0}all"
    /// How often an open window asks the daemon again: flows do not move its change counter.
    static let refresh: Duration = .seconds(2)

    private var rows: [ConnectionRow] {
        let shown = container == Self.everyContainer ? all : all.filter { $0.Id == container }
        let needle = search.lowercased()
        return ConnectionRow.fold(shown)
            .filter { !refusedOnly || $0.blocked }
            .filter { needle.isEmpty || [$0.container, $0.process, $0.destination, $0.addresses.joined(separator: " ")].contains { $0.lowercased().contains(needle) } }
            .sorted(using: order)
    }

    var body: some View {
        let rows = rows
        HStack(spacing: 0) {
            List(selection: $container) {
                Label("All containers", systemImage: "square.grid.2x2").tag(Self.everyContainer)
                Section("Containers") {
                    ForEach(all, id: \.Id) { c in
                        let refused = c.Flows.filter(\.Blocked).count
                        HStack {
                            Text(c.Name).lineLimit(1)
                            Spacer()
                            if refused > 0 { Text("⛔︎ \(refused)").foregroundStyle(.secondary).help("\(refused) refused") }
                        }
                        .tag(c.Id)
                    }
                }
            }
            .frame(width: 220)
            Divider()
            VStack(spacing: 0) {
                if rows.isEmpty {
                    Text(all.allSatisfy(\.Flows.isEmpty) ? "No connections past the containers' networks yet" : "No connections match")
                        .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    table(rows)
                }
                if let row = rows.first(where: { $0.id == selection }) {
                    Divider()
                    detail(row)
                }
            }
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Container, process, or host")
        .toolbar {
            Toggle(isOn: $refusedOnly) { Label("Refused Only", systemImage: "hand.raised") }
                .help("Only connections pratico refused")
        }
        .frame(minWidth: 960, minHeight: 480)
        .onAppear { if let focus = daemon.connectionsFocus { container = focus } }
        .onChange(of: daemon.connectionsFocus) { if let focus = daemon.connectionsFocus { container = focus } }
        .task {
            while !Task.isCancelled {
                let fresh = await DaemonProbe.fetch("/pratico/egress", as: [ContainerConnections].self, timeout: 5) ?? []
                if fresh != all { all = fresh }
                try? await Task.sleep(for: Self.refresh)
            }
        }
    }

    private func table(_ rows: [ConnectionRow]) -> some View {
        Table(rows, selection: $selection, sortOrder: $order) {
            TableColumn("Last seen", value: \.last) { r in
                Text(r.last.formatted(date: .omitted, time: .standard)).monospacedDigit()
            }
            .width(min: 64, ideal: 72)
            TableColumn("Result", value: \.result) { r in
                Text(r.blocked ? "⛔︎ Refused" : "✓ Allowed").foregroundStyle(r.blocked ? .red : .secondary)
            }
            .width(min: 76, ideal: 84)
            TableColumn("Container", value: \.container)
                .width(min: 60, ideal: 90)
            TableColumn("Process", value: \.process) { r in
                Text(r.process.isEmpty ? "—" : r.process).foregroundStyle(r.process.isEmpty ? .secondary : .primary)
                    .help(r.process.isEmpty ? "The flight recorder records TCP connections only" : r.process)
            }
            .width(min: 60, ideal: 90)
            TableColumn("Destination", value: \.destination) { r in
                Text(verbatim: "\(r.destination):\(r.port)").lineLimit(1).truncationMode(.middle)
                    .help(r.addresses.sorted().joined(separator: ", "))
            }
            .width(min: 140, ideal: 180)
            TableColumn("Protocol", value: \.proto) { r in Text(r.proto) }
                .width(min: 44, ideal: 52)
            TableColumn("Count", value: \.count) { r in Text(r.count, format: .number).monospacedDigit() }
                .width(min: 40, ideal: 46)
        }
    }

    private func detail(_ r: ConnectionRow) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
            if let reason = r.reason {
                GridRow { Text("Refused").foregroundStyle(.secondary); Text(reason).textSelection(.enabled) }
            }
            GridRow { Text("Addresses").foregroundStyle(.secondary); Text(verbatim: r.addresses.sorted().joined(separator: ", ")).textSelection(.enabled) }
            if !r.pids.isEmpty {
                GridRow { Text("Process").foregroundStyle(.secondary); Text(verbatim: "\(r.process), PID \(r.pids.sorted().map(String.init).joined(separator: ", "))") }
            }
            if !r.sourcePorts.isEmpty {
                GridRow { Text("Source ports").foregroundStyle(.secondary); Text(verbatim: r.sourcePorts.sorted().prefix(20).map(String.init).joined(separator: ", ")) }
            }
            GridRow {
                Text("Seen").foregroundStyle(.secondary)
                Text(r.count == 1 ? r.last.formatted(date: .abbreviated, time: .standard)
                     : "\(r.count) times, \(r.first.formatted(date: .abbreviated, time: .standard)) to \(r.last.formatted(date: .omitted, time: .standard))")
            }
        }
        .font(.callout)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Opens the Connections window in front, on one container when given.
struct ConnectionsButton: View {
    let daemon: DaemonController
    var title = "Connections…"
    var container: String?
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(title) {
            daemon.connectionsFocus = container ?? ConnectionsView.everyContainer
            NSApp.activate()
            openWindow(id: "connections")
        }
    }
}
