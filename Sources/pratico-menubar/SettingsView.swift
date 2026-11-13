import Observation
import PraticoCore
import SwiftUI

/// `config.toml` behind a standard Settings window (SPEC FR-34). A change is written at once
/// and only to its own key, so comments and the rest of the file stay.
@MainActor @Observable
final class SettingsModel {
    private(set) var file = Config()
    private(set) var text = ""
    private(set) var loadError: String?
    private(set) var saveError: String?
    /// Changed since the daemon started: it reads `config.toml` only at startup.
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
    }

    func value(_ name: String) -> Config.Value { file.value(name)! }
    func isOverridden(_ name: String) -> Bool { file.overrides[name] != nil }

    /// `nil` removes the key, back to its default.
    func set(_ name: String, _ value: Config.Value?) {
        guard value != file.overrides[name] else { return }
        do {
            try FileManager.default.createDirectory(at: Pratico.home(), withIntermediateDirectories: true)
            try Config.setting(name, to: value, in: text).write(to: Config.path(), atomically: true, encoding: .utf8)
            saveError = nil
            needsRestart = true
        } catch {
            saveError = "\(error)"
        }
        reload()
    }

    func restarted() { needsRestart = false }
}

struct SettingsView: View {
    @State private var model = SettingsModel()
    let daemon: DaemonController

    var body: some View {
        VStack(spacing: 0) {
            TabView {
                pane(["start_at_login", "default_cpus", "default_memory"])
                    .tabItem { Label("General", systemImage: "gearshape") }
                pane(["scan", "scan_block", "scan_allow"])
                    .tabItem { Label("Scanning", systemImage: "checkmark.shield") }
                pane(["registry_keep_logins", "registry_http_loopback", "registry_http", "registry_system_roots", "registry_ca"])
                    .tabItem { Label("Registries", systemImage: "shippingbox") }
            }
            status
        }
        .frame(width: 560)
        .disabled(model.loadError != nil)
        .onAppear { model.reload() }
    }

    private func pane(_ names: [String]) -> some View {
        Form {
            ForEach(names.compactMap { n in Config.keys.first { $0.name == n } }, id: \.name) { key in
                LabeledContent(Self.labels[key.name] ?? key.name) {
                    VStack(alignment: .leading, spacing: 2) {
                        control(key)
                        Text(key.summary).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        // FR-34: where the value comes from.
                        if model.isOverridden(key.name) {
                            HStack(spacing: 6) {
                                Text("Set in config.toml").font(.caption).foregroundStyle(.secondary)
                                Button("Use Default") { model.set(key.name, nil) }.buttonStyle(.link).font(.caption)
                            }
                        }
                    }
                }
                .padding(.bottom, 6)
            }
        }
        .formStyle(.columns)
        .padding(20)
    }

    @ViewBuilder private func control(_ key: Config.Key) -> some View {
        let name = key.name
        switch model.value(name) {
        case .bool(let v):
            Toggle(Self.toggleTitles[name] ?? "On", isOn: Binding(get: { v }, set: { model.set(name, .bool($0)) }))
        case .int(let v):
            let range = key.range ?? 0...Int.max
            Stepper(value: Binding(get: { v }, set: { model.set(name, .int($0)) }), in: range, step: name == "default_memory" ? 256 : 1) {
                Text(name == "default_memory" ? "\(v) MiB" : "\(v)").monospacedDigit()
            }
        case .string(let v):
            Picker("", selection: Binding(get: { v }, set: { model.set(name, .string($0)) })) {
                ForEach(key.choices ?? [v], id: \.self) { Text($0) }
            }
            .labelsHidden().fixedSize()
        case .strings(let v):
            ListField(entries: v) { model.set(name, .strings($0)) }
        }
    }

    @ViewBuilder private var status: some View {
        if let error = model.loadError {
            notice("config.toml has an error, so the daemon will not start: \(error)", color: .red)
        } else if let error = model.saveError {
            notice(error, color: .red)
        } else if model.needsRestart && daemon.isRunning {
            HStack {
                Text("The daemon reads these settings when it starts.").font(.callout)
                Spacer()
                Button("Restart Daemon") {
                    Task {
                        await daemon.restart()
                        model.restarted()
                    }
                }
            }
            .padding([.horizontal, .bottom], 20)
        }
    }

    private func notice(_ text: String, color: Color) -> some View {
        HStack {
            Text(text).foregroundStyle(color).font(.callout)
            Spacer()
            Button("Open config.toml") { daemon.openConfig() }
        }
        .padding([.horizontal, .bottom], 20)
    }

    private static let labels: [String: String] = [
        "start_at_login": "Startup:",
        "default_cpus": "CPUs:",
        "default_memory": "Memory:",
        "scan": "Image scanning:",
        "scan_block": "Block on:",
        "scan_allow": "Allowed images:",
        "registry_keep_logins": "Logins:",
        "registry_http_loopback": "Loopback:",
        "registry_http": "Plain HTTP:",
        "registry_system_roots": "Trust:",
        "registry_ca": "Extra CAs:",
    ]

    private static let toggleTitles: [String: String] = [
        "start_at_login": "Start the daemon at login",
        "scan": "Scan pulled images",
        "registry_keep_logins": "Keep docker login credentials",
        "registry_http_loopback": "Allow plain HTTP to localhost",
        "registry_system_roots": "Trust the system's roots",
    ]
}

/// A comma-separated list, written when the user presses Return or leaves the field.
private struct ListField: View {
    let entries: [String]
    let commit: ([String]) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("none", text: $text)
            .focused($focused)
            .onAppear { text = entries.joined(separator: ", ") }
            .onChange(of: entries) { if !focused { text = entries.joined(separator: ", ") } }
            .onChange(of: focused) { if !focused { save() } }
            .onSubmit(save)
    }

    private func save() {
        commit(text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
    }
}
