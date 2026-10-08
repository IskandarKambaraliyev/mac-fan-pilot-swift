import SwiftUI

/// Menu bar labels render a single `Text`/`Image`/`Label`; avoid custom stacks here.
struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let state = model.controlState
        switch model.display {
        case .iconOnly:
            state.icon
        case .temp:
            readout(model.format(temp: model.cpuTemp), state)
        case .rpm:
            Label { Text(model.format(rpm: model.maxFanRPM)) } icon: { state.icon }.labelStyle(.titleAndIcon)
        case .both:
            readout("\(model.format(temp: model.cpuTemp)) · \(model.format(rpm: model.maxFanRPM))", state)
        }
    }

    /// The text-only readouts gain an icon only while something needs attention.
    @ViewBuilder private func readout(_ text: String, _ state: ControlState) -> some View {
        if state.needsAttention {
            Label { Text(text) } icon: { state.icon }.labelStyle(.titleAndIcon).monospacedDigit()
        } else {
            Text(text).monospacedDigit()
        }
    }
}

private extension ControlState {
    /// The app's own fan, outlined while macOS has the fans and filled while a preset runs. Both are
    /// template images in the asset catalog, so the menu bar tints them. The two states that need
    /// attention keep system symbols, which read as warnings at a glance.
    var icon: Image {
        switch self {
        case .automatic: Image("MenuBarFan", bundle: .glyphs, label: Text(FP.appName))
        case .controlling: Image("MenuBarFanFilled", bundle: .glyphs, label: Text(FP.appName))
        case .emergency: Image(systemName: "thermometer.high")
        case .stopped: Image(systemName: "exclamationmark.triangle")
        }
    }
}

private extension Bundle {
    /// The bundle these views were compiled into: the app, or the test bundle, which builds the
    /// same sources and carries its own copy of the asset catalog.
    static let glyphs = Bundle(for: AppModel.self)
}
