import SwiftUI

struct PresetsSettings: View {
    @Environment(AppModel.self) private var model
    @State private var selection: UUID?

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                List(model.presets.presets, selection: $selection) { p in
                    Label(p.name, systemImage: p.symbol).tag(p.id)
                }
                HStack {
                    Button { selection = model.presets.add().id } label: { Image(systemName: "plus") }
                        .help("New preset")
                    Button {
                        if let p = selectedPreset { selection = model.presets.add(basedOn: p).id }
                    } label: { Image(systemName: "plus.square.on.square") }
                        .help("Duplicate")
                        .disabled(selectedPreset == nil)
                    Button {
                        if let p = selectedPreset { delete(p) }
                    } label: { Image(systemName: "minus") }
                        .help("Delete")
                        .disabled(selectedPreset?.isBuiltIn ?? true)
                    Spacer()
                }
                .buttonStyle(.borderless).padding(6)
            }
            .frame(minWidth: 160, maxWidth: 200)

            Group {
                if let p = selectedPreset {
                    PresetEditorView(preset: p).id(p.id)
                } else {
                    Text("Select a preset").foregroundStyle(.secondary)
                }
            }
            // A sane floor for the split view's size probing, and fill whatever is left.
            .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { if selection == nil { selection = model.presets.activeID } }
    }

    private var selectedPreset: Preset? { model.presets.presets.first { $0.id == selection } }

    private func delete(_ p: Preset) {
        let wasActive = p.id == model.presets.activeID
        model.presets.delete(p)
        selection = nil
        // Deleting the active preset leaves Automatic selected; make the fans follow.
        if wasActive { Task { await model.activate(.automatic) } }
    }
}
