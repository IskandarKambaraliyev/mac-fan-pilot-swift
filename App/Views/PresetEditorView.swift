import SwiftUI

struct PresetEditorView: View {
    @Environment(AppModel.self) private var model
    @State var preset: Preset
    @State private var liveApply: Task<Void, Never>?
    /// nil edits the mode for all fans; otherwise the override for that fan.
    @State private var fan: Int?

    var body: some View {
        VStack(spacing: 0) {
            form
            Divider()
            // Outside the scrolling form so it stays reachable under a tall curve.
            HStack {
                if preset.isBuiltIn {
                    // No vertical fixedSize here: the split view probes panes at zero width, where
                    // that makes this text (and so the whole pane) hundreds of points tall.
                    Text("Built-in presets are read-only. Duplicate to customize.")
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Button("Activate") { Task { await model.activate(preset) } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(preset.id == model.presets.activeID)
            }
            .padding(10)
        }
        .onChange(of: preset) { old, new in
            model.presets.update(new)
            // Editing the active preset re-applies it live, but only when what the fans do changed:
            // a new name is not worth restarting the control loop for.
            guard new.id == model.presets.activeID, old.mode != new.mode || old.perFan != new.perFan else { return }
            liveApply?.cancel()
            liveApply = Task {
                try? await Task.sleep(for: .milliseconds(300))   // wait for the drag to settle
                guard !Task.isCancelled else { return }
                await model.activate(new)
            }
        }
    }

    private var form: some View {
        Form {
            TextField("Name", text: $preset.name).disabled(preset.isBuiltIn)

            // Built-in presets treat every fan alike, so there is nothing per fan to show.
            if controllableFans.count > 1, !preset.isBuiltIn {
                Picker("Fans", selection: $fan) {
                    Text("All").tag(Int?.none)
                    ForEach(controllableFans) { Text(model.fanName($0.id)).tag(Int?.some($0.id)) }
                }
                .pickerStyle(.segmented)
                if let fan {
                    Toggle("Different from the other fans", isOn: overrideBinding(fan))
                }
            }

            if let fan, let override = preset.perFan[fan] {
                FanModeEditor(mode: Binding(get: { override }, set: { preset.perFan[fan] = $0 }),
                              editable: true, fans: controllableFans.filter { $0.id == fan }, isOverride: true)
            } else {
                // A fan without an override shows the shared mode, read-only.
                FanModeEditor(mode: $preset.mode, editable: !preset.isBuiltIn && fan == nil,
                              fans: controllableFans, isOverride: false)
            }
        }
        .formStyle(.grouped)
    }

    private var controllableFans: [FanReading] { model.snapshot.fans.filter { $0.max > $0.min } }

    /// Switching the override on starts it from the shared mode, so nothing changes until edited.
    private func overrideBinding(_ fan: Int) -> Binding<Bool> {
        Binding(get: { preset.perFan[fan] != nil },
                set: { preset.perFan[fan] = $0 ? preset.mode : nil })
    }
}

/// The mode picker and the controls of the chosen mode. It edits one `FanMode`, so the preset
/// editor can point it at the mode for all fans or at one fan's override.
struct FanModeEditor: View {
    @Environment(AppModel.self) private var model
    @Binding var mode: FanMode
    let editable: Bool
    /// The fans this mode drives. Their limits bound a fixed speed.
    let fans: [FanReading]
    let isOverride: Bool

    private enum Kind: String, CaseIterable { case auto = "Automatic", fixed = "Fixed", curve = "Curve" }

    var body: some View {
        Picker("Mode", selection: kindBinding) {
            ForEach(Kind.allCases, id: \.self) { Text($0.rawValue) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .disabled(!editable)

        switch mode {
        case .fixedPercent, .fixedRPM:
            LabeledContent("Speed") {
                RPMField(rpm: rpmBinding, range: rpmRange)
            }
            .disabled(!editable)
            if !fans.isEmpty {
                Text("\(fans.count == 1 ? "This fan runs" : "This Mac's fans run") from \(String(rpmRange.lowerBound)) to \(String(rpmRange.upperBound)) rpm.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .curve(let c):
            Picker("Sensor", selection: Binding(get: { c.sensor }, set: { var n = c; n.sensor = $0; mode = .curve(n) })) {
                ForEach(SensorGroup.allCases) { Text($0.title).tag($0) }
            }
            .disabled(!editable)
            CurveEditor(curve: Binding(get: { c }, set: { mode = .curve($0) }),
                        liveTemp: model.snapshot.groups[c.sensor],
                        editable: editable,
                        fahrenheit: model.useFahrenheit)
        case .auto:
            // Raising the unlock flag on M3 and later takes every fan away from macOS at once.
            Text(isOverride
                 ? "macOS controls this fan where it can. On M3 and later it can't while another fan is held, so this fan follows the Balanced curve instead."
                 : "macOS controls the fans.")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Fixed speed

    /// What the fans accept. The helper clamps to each fan's own limits regardless.
    private var rpmRange: ClosedRange<Int> {
        guard let lo = fans.map(\.min).min(), let hi = fans.map(\.max).max() else { return 0...20_000 }
        return Int(lo.rounded(.up))...Int(hi.rounded(.down))
    }

    /// A mode stored as a percentage (Full Blast, or one made before speeds were entered in rpm)
    /// is shown as the rpm it works out to here; editing it stores rpm.
    private var rpmBinding: Binding<Int> {
        Binding(get: {
            let range = rpmRange
            let rpm: Double
            switch mode {
            case .fixedRPM(let r): rpm = r
            case .fixedPercent(let p): rpm = Double(range.lowerBound) + Double(range.upperBound - range.lowerBound) * p
            default: rpm = Double(range.lowerBound)
            }
            return min(max(Int(rpm.rounded()), range.lowerBound), range.upperBound)
        }, set: { new in
            let range = rpmRange
            mode = .fixedRPM(Double(min(max(new, range.lowerBound), range.upperBound)))
        })
    }

    private var defaultRPM: Double {
        let range = rpmRange
        guard !fans.isEmpty else { return 3000 }
        return (Double(range.lowerBound + range.upperBound) / 200).rounded() * 100   // mid-range, to the nearest 100
    }

    private var kindBinding: Binding<Kind> {
        Binding(get: {
            switch mode {
            case .auto: .auto
            case .fixedPercent, .fixedRPM: .fixed
            case .curve: .curve
            }
        }, set: { k in
            switch k {
            case .auto: mode = .auto
            case .fixed: mode = .fixedRPM(defaultRPM)
            case .curve: mode = .curve(.balanced)
            }
        })
    }
}

/// Typed rpm entry with a stepper. A typed value takes effect as soon as it is within range, so
/// it never depends on the field giving up focus before Activate is clicked.
struct RPMField: View {
    @Binding var rpm: Int
    let range: ClosedRange<Int>
    @State private var text = ""
    @FocusState private var focused: Bool

    private var typed: Int? { Int(text.filter { !$0.isWhitespace }) }
    private var isValid: Bool { typed.map(range.contains) ?? false }

    var body: some View {
        HStack(spacing: 6) {
            TextField("Speed", text: $text)
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .foregroundStyle(isValid ? Color.primary : Color.red)
                .frame(width: 72)
                .focused($focused)
                .onSubmit { text = String(rpm) }
            Text("rpm").foregroundStyle(.secondary)
            Stepper("Speed", value: $rpm, in: range, step: 100).labelsHidden()
        }
        .onAppear { text = String(rpm) }
        .onChange(of: text) { _, _ in
            if let value = typed, range.contains(value), value != rpm { rpm = value }
        }
        .onChange(of: rpm) { _, new in
            if typed != new { text = String(new) }
        }
        .onChange(of: focused) { _, isFocused in
            if !isFocused { text = String(rpm) }   // drop a half-typed or out-of-range entry
        }
    }
}
