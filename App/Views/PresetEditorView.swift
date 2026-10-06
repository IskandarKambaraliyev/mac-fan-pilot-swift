import SwiftUI

struct PresetEditorView: View {
    @Environment(AppModel.self) private var model
    @State var preset: Preset
    @State private var liveApply: Task<Void, Never>?

    private enum Kind: String, CaseIterable { case auto = "Automatic", fixed = "Fixed", curve = "Curve" }

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
        .onChange(of: preset) { _, new in
            model.presets.update(new)
            guard new.id == model.presets.activeID else { return }
            // Editing the active preset re-applies it live; wait for the drag to settle first.
            liveApply?.cancel()
            liveApply = Task {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                await model.activate(new)
            }
        }
    }

    private var form: some View {
        Form {
            TextField("Name", text: $preset.name).disabled(preset.isBuiltIn)

            Picker("Mode", selection: kindBinding) {
                ForEach(Kind.allCases, id: \.self) { Text($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(preset.isBuiltIn)

            switch preset.mode {
            case .fixedPercent, .fixedRPM:
                LabeledContent("Speed") {
                    RPMField(rpm: rpmBinding, range: rpmRange)
                }
                .disabled(preset.isBuiltIn)
                if hasFanLimits {
                    Text("This Mac's fans run from \(String(rpmRange.lowerBound)) to \(String(rpmRange.upperBound)) rpm.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            case .curve(let c):
                Picker("Sensor", selection: Binding(get: { c.sensor }, set: { var n = c; n.sensor = $0; preset.mode = .curve(n) })) {
                    ForEach(SensorGroup.allCases) { Text($0.title).tag($0) }
                }
                .disabled(preset.isBuiltIn)
                CurveEditor(curve: Binding(get: { c }, set: { preset.mode = .curve($0) }),
                            liveTemp: model.snapshot.groups[c.sensor],
                            editable: !preset.isBuiltIn)
            case .auto:
                Text("macOS controls the fans.").foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Fixed speed

    private var hasFanLimits: Bool { model.snapshot.fans.contains { $0.max > $0.min } }

    /// What the fans on this Mac accept. The helper clamps to each fan's own limits regardless.
    private var rpmRange: ClosedRange<Int> {
        let fans = model.snapshot.fans.filter { $0.max > $0.min }
        guard let lo = fans.map(\.min).min(), let hi = fans.map(\.max).max() else { return 0...20_000 }
        return Int(lo.rounded(.up))...Int(hi.rounded(.down))
    }

    /// A preset stored as a percentage (Full Blast, or one made before speeds were entered in rpm)
    /// is shown as the rpm it works out to here; editing it stores rpm.
    private var rpmBinding: Binding<Int> {
        Binding(get: {
            let range = rpmRange
            let rpm: Double
            switch preset.mode {
            case .fixedRPM(let r): rpm = r
            case .fixedPercent(let p): rpm = Double(range.lowerBound) + Double(range.upperBound - range.lowerBound) * p
            default: rpm = Double(range.lowerBound)
            }
            return min(max(Int(rpm.rounded()), range.lowerBound), range.upperBound)
        }, set: { new in
            let range = rpmRange
            preset.mode = .fixedRPM(Double(min(max(new, range.lowerBound), range.upperBound)))
        })
    }

    private var defaultRPM: Double {
        let range = rpmRange
        guard hasFanLimits else { return 3000 }
        return (Double(range.lowerBound + range.upperBound) / 200).rounded() * 100   // mid-range, to the nearest 100
    }

    private var kindBinding: Binding<Kind> {
        Binding(get: {
            switch preset.mode {
            case .auto: .auto
            case .fixedPercent, .fixedRPM: .fixed
            case .curve: .curve
            }
        }, set: { k in
            switch k {
            case .auto: preset.mode = .auto
            case .fixed: preset.mode = .fixedRPM(defaultRPM)
            case .curve: preset.mode = .curve(.balanced)
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
