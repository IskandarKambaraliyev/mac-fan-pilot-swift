import SwiftUI

struct MenuContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Temperatures
            VStack(spacing: 6) {
                HStack(spacing: 20) {
                    tempBlock(.cpu, model.cpuTemp)
                    tempBlock(.gpu, model.gpuTemp)
                    Spacer()
                }
                if model.history.count > 1 {
                    HistoryChart(samples: model.history, format: model.format(temp:))
                }
            }

            Divider()

            if model.hasFans {
                // Fans
                ForEach(model.snapshot.fans) { fan in
                    HStack {
                        Text(model.fanName(fan.id)).frame(width: 70, alignment: .leading)
                        Text("\(model.format(rpm: fan.rpm)) rpm").monospacedDigit().foregroundStyle(.secondary)
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
                                  isApplying: preset.id == model.applyingID,
                                  inEffect: model.isControlling || preset.isAllAuto) {
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
        .onAppear {
            model.popoverVisible = true
            model.helper.refreshStatus()
        }
        .onDisappear { model.popoverVisible = false }
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
            } else if model.emergency {
                warning("Very hot: every fan runs at full speed until it cools down.")
            } else if model.pausedOnBattery {
                Label("On battery, so the fans are on Automatic.", systemImage: "battery.75percent")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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

    /// The coloured mark matches the sensor's line in the history chart.
    private func tempBlock(_ series: HistorySeries, _ value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(series.rawValue).font(.caption).foregroundStyle(.secondary)
                Capsule().fill(series.color).frame(width: 10, height: 3)
            }
            Text(model.format(temp: value)).font(.title2.weight(.medium)).monospacedDigit()
        }
    }
}

struct PresetRow: View {
    let preset: Preset
    let isActive: Bool
    let isApplying: Bool
    /// false when the preset is selected but something keeps it from running.
    let inEffect: Bool
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
                    Image(systemName: "checkmark")
                        .foregroundStyle(inEffect ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                        .help(inEffect ? "" : "Selected, but not running right now")
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
