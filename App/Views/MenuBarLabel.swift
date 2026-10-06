import SwiftUI

/// Menu bar labels render a single `Text`/`Image`/`Label`; avoid custom stacks here.
struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let state = model.controlState
        switch model.display {
        case .iconOnly:
            Image(systemName: state.symbol)
        case .temp:
            readout(model.format(temp: model.cpuTemp), state)
        case .rpm:
            Label(model.format(rpm: model.maxFanRPM), systemImage: state.symbol).labelStyle(.titleAndIcon)
        case .both:
            readout("\(model.format(temp: model.cpuTemp)) · \(model.format(rpm: model.maxFanRPM))", state)
        }
    }

    /// The text-only readouts gain an icon only while something needs attention.
    @ViewBuilder private func readout(_ text: String, _ state: ControlState) -> some View {
        if state.needsAttention {
            Label(text, systemImage: state.symbol).labelStyle(.titleAndIcon).monospacedDigit()
        } else {
            Text(text).monospacedDigit()
        }
    }
}
