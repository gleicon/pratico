import Observation
import PraticoCore
import SwiftUI

/// `config.toml` as a form (SPEC FR-34): each key's effective value and where it comes from.
/// Saving rewrites only the keys changed here, so comments and the rest of the file stay.
@MainActor @Observable
final class SettingsModel {
    private(set) var file = Config()
    private(set) var text = ""
    /// Values on screen, by key; saved ones equal `file`'s effective values.
    var values: [String: Config.Value] = [:]
    /// List keys as typed, one entry per line; re-joining the parsed list would eat the
    /// newline that starts the next entry.
    private var drafts: [String: String] = [:]
    private(set) var loadError: String?
    private(set) var saveError: String?
    /// Saved since the daemon started: it reads `config.toml` only at startup.
    private(set) var needsRestart = false

    init() { reload() }

    func reload() {
        text = (try? String(contentsOf: Config.path(), encoding: .utf8)) ?? ""
        do {
            file = try Config.parse(text)
            loadError = nil
        } catch {
            file = Config()
            loadError = "\(error)"
        }
        values = Dictionary(uniqueKeysWithValues: Config.keys.map { ($0.name, file.value($0.name)!) })
        drafts = values.compactMapValues { if case .strings(let v) = $0 { v.joined(separator: "\n") } else { nil } }
        saveError = nil
    }

    func list(_ name: String) -> Binding<String> {
        Binding(get: { self.drafts[name] ?? "" }, set: {
            self.drafts[name] = $0
            self.values[name] = .strings($0.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
        })
    }

    func isOverridden(_ key: Config.Key) -> Bool { file.overrides[key.name] != nil }
    func isEdited(_ key: Config.Key) -> Bool { values[key.name] != file.value(key.name) }
    var hasEdits: Bool { Config.keys.contains(where: isEdited) }

    func save() {
        do {
            var out = text
            for key in Config.keys where isEdited(key) { out = try Config.setting(key.name, to: values[key.name], in: out) }
            try FileManager.default.createDirectory(at: Pratico.home(), withIntermediateDirectories: true)
            try out.write(to: Config.path(), atomically: true, encoding: .utf8)
            reload()
            needsRestart = true
        } catch {
            saveError = "\(error)"
        }
    }

    /// Removes the key from the file, back to its default.
    func reset(_ key: Config.Key) {
        do {
            try Config.setting(key.name, to: nil, in: text).write(to: Config.path(), atomically: true, encoding: .utf8)
            reload()
            needsRestart = true
        } catch {
            saveError = "\(error)"
        }
    }

    func restarted() { needsRestart = false }
}

struct SettingsView: View {
    @State private var model = SettingsModel()
    let daemon: DaemonController

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let error = model.loadError {
                Label("config.toml has an error, so the daemon will not start: \(error)", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red).padding()
            }
            Form {
                ForEach(Config.keys, id: \.name) { key in
                    row(key)
                }
            }
            .formStyle(.grouped)
            .disabled(model.loadError != nil)
            footer.padding()
        }
        .frame(minWidth: 620, minHeight: 520)
        .onAppear { model.reload() }
    }

    @ViewBuilder private func row(_ key: Config.Key) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(key.name).font(.body.monospaced())
                Spacer()
                if model.isEdited(key) {
                    Text("edited").foregroundStyle(.orange)
                } else if model.isOverridden(key) {
                    Text("config.toml").foregroundStyle(.secondary)
                    Button("Reset") { model.reset(key) }.buttonStyle(.link)
                } else {
                    Text("default").foregroundStyle(.secondary)
                }
            }
            control(key)
            Text(key.summary).font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func control(_ key: Config.Key) -> some View {
        switch key.defaultValue {
        case .bool:
            Toggle("On", isOn: Binding(
                get: { if case .bool(let v) = model.values[key.name] { v } else { false } },
                set: { model.values[key.name] = .bool($0) }))
        case .int:
            let range = key.range ?? Int.min...Int.max
            HStack {
                TextField("", value: Binding(
                    get: { if case .int(let v) = model.values[key.name] { v } else { 0 } },
                    set: { model.values[key.name] = .int(min(max($0, range.lowerBound), range.upperBound)) }),
                    format: .number.grouping(.never))
                    .frame(width: 120)
                if let r = key.range { Text("\(r.lowerBound)–\(r.upperBound)").foregroundStyle(.secondary) }
            }
        case .string:
            if let choices = key.choices {
                Picker("", selection: Binding(
                    get: { if case .string(let v) = model.values[key.name] { v } else { "" } },
                    set: { model.values[key.name] = .string($0) })) {
                    ForEach(choices, id: \.self) { Text($0) }
                }
                .labelsHidden().pickerStyle(.segmented)
            } else {
                TextField("", text: Binding(
                    get: { if case .string(let v) = model.values[key.name] { v } else { "" } },
                    set: { model.values[key.name] = .string($0) }))
            }
        case .strings:
            // One entry per line.
            TextEditor(text: model.list(key.name))
                .font(.body.monospaced())
                .frame(height: 48)
        }
    }

    private var footer: some View {
        HStack {
            if let error = model.saveError {
                Text(error).foregroundStyle(.red).lineLimit(2)
            } else if model.needsRestart && daemon.isRunning {
                Text("Saved. The daemon reads config.toml when it starts.")
                Button("Restart Daemon") {
                    daemon.stop()
                    Task {
                        try? await Task.sleep(for: .seconds(1))
                        daemon.start()
                        model.restarted()
                    }
                }
            }
            Spacer()
            Button("Open config.toml") { daemon.openConfig() }
            Button("Revert") { model.reload() }.disabled(!model.hasEdits)
            Button("Save") { model.save() }
                .keyboardShortcut("s")
                .disabled(!model.hasEdits)
        }
    }
}
