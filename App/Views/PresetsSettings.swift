import SwiftUI
import UniformTypeIdentifiers

struct PresetsSettings: View {
    @Environment(AppModel.self) private var model
    @State private var selection: UUID?
    @State private var transferError: String?

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
                    Menu {
                        Button("Import Presets…", action: importPresets)
                        Button("Export Custom Presets…", action: exportPresets)
                            .disabled(model.presets.custom.isEmpty)
                    } label: { Image(systemName: "ellipsis.circle") }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        .help("Import or export presets")
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
        .alert("Presets", isPresented: Binding(get: { transferError != nil }, set: { if !$0 { transferError = nil } })) {
            Button("OK") {}
        } message: {
            Text(transferError ?? "")
        }
    }

    private func exportPresets() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(FP.appName) Presets.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try model.presets.exportData().write(to: url, options: .atomic) }
        catch { transferError = error.localizedDescription }
    }

    private func importPresets() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { selection = try model.presets.importPresets(from: Data(contentsOf: url)).first?.id }
        catch { transferError = error.localizedDescription }
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
