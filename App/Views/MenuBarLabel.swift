import SwiftUI

/// Menu bar labels render a single `Text`/`Image`/`Label`; avoid custom stacks here.
struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        switch model.display {
        case .iconOnly:
            Image(systemName: "fan")
        case .temp:
            Text(model.format(temp: model.cpuTemp)).monospacedDigit()
        case .rpm:
            Label(model.format(rpm: model.maxFanRPM), systemImage: "fan").labelStyle(.titleAndIcon)
        case .both:
            Text("\(model.format(temp: model.cpuTemp)) · \(model.format(rpm: model.maxFanRPM))").monospacedDigit()
        }
    }
}
