import SwiftUI

struct SettingsView: View {
    enum Tab { case general, presets, sensors }
    @State var tab = Tab.general

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }.tag(Tab.general)
            PresetsSettings().tabItem { Label("Presets", systemImage: "slider.horizontal.3") }.tag(Tab.presets)
            SensorsView().tabItem { Label("Sensors", systemImage: "thermometer.medium") }.tag(Tab.sensors)
        }
        .padding(.top, 8)
        .frame(width: 580, height: 540)   // tall enough for the curve editor without scrolling
    }
}

struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var copied = false

    var body: some View {
        @Bindable var model = model
        Form {
            Toggle("Launch at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, v in
                    guard v != LoginItem.isEnabled else { return }
                    LoginItem.set(v)
                    launchAtLogin = LoginItem.isEnabled
                }

            Picker("Menu bar shows", selection: $model.display) {
                ForEach(MenuBarDisplay.allCases) { Text($0.title).tag($0) }
            }
            Picker("Units", selection: $model.useFahrenheit) {
                Text("Celsius").tag(false); Text("Fahrenheit").tag(true)
            }
            Picker("Refresh every", selection: $model.refreshInterval) {
                Text("1 s").tag(1.0); Text("2 s").tag(2.0); Text("5 s").tag(5.0)
            }

            Section {
                if model.hasBattery {
                    Toggle("Use Automatic on battery", isOn: $model.autoOnBattery)
                }
                Toggle("Notify when fan control stops", isOn: $model.notificationsEnabled)
            }

            Section("Fan control helper") {
                LabeledContent("Status") { Text(statusText).multilineTextAlignment(.trailing) }
                HStack {
                    if model.helper.state == .ready {
                        Button("Uninstall") { Task { await model.uninstallHelper() } }
                    } else {
                        Button("Install…") { model.helper.install() }
                    }
                    Button("Refresh") { model.helper.refreshStatus() }
                }
            }

            Section {
                LabeledContent("Version", value: Self.version)
                HStack {
                    Button("Copy Diagnostics") { copyDiagnostics() }
                        .help("Copies versions, fan limits and sensor ranges, for a bug report")
                    if copied { Text("Copied").foregroundStyle(.secondary) }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { model.helper.refreshStatus() }
    }

    private func copyDiagnostics() {
        Task {
            let text = await model.diagnostics()
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }

    private var statusText: String {
        switch model.helper.state {
        case .ready: "Installed"
        case .needsApproval: "Waiting for approval in System Settings → Login Items"
        case .notInstalled: "Not installed (monitoring only)"
        case .error(let e): e
        }
    }

    private static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–"
}
