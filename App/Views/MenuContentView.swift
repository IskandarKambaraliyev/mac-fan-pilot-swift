import SwiftUI

struct MenuContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Temperatures
            HStack(spacing: 20) {
                tempBlock("CPU", model.cpuTemp)
                tempBlock("GPU", model.gpuTemp)
                Spacer()
            }

            Divider()

            if model.hasFans {
                // Fans
                ForEach(model.snapshot.fans) { fan in
                    HStack {
                        Text(fanName(fan.id)).frame(width: 70, alignment: .leading)
                        Text("\(Int(fan.rpm)) rpm").monospacedDigit().foregroundStyle(.secondary)
                            .frame(width: 80, alignment: .trailing)
                        ProgressView(value: min(max(fan.fraction, 0), 1)).progressViewStyle(.linear)
                    }
                    .font(.callout)
                }

                Divider()

                // Presets
                VStack(spacing: 2) {
                    ForEach(model.presets.presets) { preset in
                        PresetRow(preset: preset,
                                  isActive: preset.id == model.presets.activeID,
                                  isApplying: preset.id == model.applyingID) {
                            Task { await model.activate(preset) }
                        }
                    }
                }

                notice
            } else {
                Text("This Mac has no fans, so there is nothing to control.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            HStack {
                Button("Settings…") { SettingsWindow.show(model: model) }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
            .buttonStyle(.borderless)
        }
        .padding(14)
        .frame(width: 280)
        .onAppear { model.helper.refreshStatus() }
    }

    /// At most one line of status under the presets, most important first.
    @ViewBuilder private var notice: some View {
        switch model.helper.state {
        case .notInstalled:
            Button("Install helper to control fans…") { model.helper.install() }
                .buttonStyle(.link)
        case .needsApproval:
            Button("Allow \(FP.appName) in Login Items to control fans…") { model.helper.openApprovalSettings() }
                .buttonStyle(.link)
        case .error(let message):
            warning(message)
            Button("Try again") { model.helper.install() }
                .buttonStyle(.link)
        case .ready:
            if model.externalControl {
                warning("Another app is controlling the fans. Quit it before choosing a preset here.")
            } else if let err = model.lastError {
                warning(err)
            }
        }
    }

    private func warning(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle")
            .font(.caption).foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func tempBlock(_ title: String, _ value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(model.format(temp: value)).font(.title2.weight(.medium)).monospacedDigit()
        }
    }

    private func fanName(_ i: Int) -> String {
        model.snapshot.fans.count == 2 ? (i == 0 ? "Left" : "Right") : "Fan \(i + 1)"
    }
}

struct PresetRow: View {
    let preset: Preset
    let isActive: Bool
    let isApplying: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack {
                Image(systemName: preset.symbol).frame(width: 18)
                Text(preset.name)
                Spacer()
                if isApplying {
                    ProgressView().controlSize(.small)
                } else if isActive {
                    Image(systemName: "checkmark").foregroundStyle(.tint)
                }
            }
            .padding(.horizontal, 6).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 5).fill(hover ? Color.primary.opacity(0.08) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}
