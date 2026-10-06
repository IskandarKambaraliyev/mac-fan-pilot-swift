import Foundation
import Observation

@MainActor
@Observable
final class PresetStore {
    private(set) var presets: [Preset] = Preset.builtIns
    var activeID: UUID {
        didSet { UserDefaults.standard.set(activeID.uuidString, forKey: "activePresetID") }
    }

    private let url: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(FP.appName, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("presets.json")
    }()

    init() {
        activeID = UserDefaults.standard.string(forKey: "activePresetID").flatMap(UUID.init) ?? Preset.automatic.id
        load()
    }

    var active: Preset { presets.first { $0.id == activeID } ?? .automatic }
    var custom: [Preset] { presets.filter { !$0.isBuiltIn } }

    func load() {
        let saved = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([Preset].self, from: $0) } ?? []
        presets = Preset.builtIns + saved.filter { !$0.isBuiltIn }
        if !presets.contains(where: { $0.id == activeID }) { activeID = Preset.automatic.id }
    }

    private func save() {
        let data = try? JSONEncoder().encode(custom)
        try? data?.write(to: url, options: .atomic)
    }

    @discardableResult
    func add(basedOn base: Preset? = nil) -> Preset {
        var p = base ?? Preset(id: UUID(), name: "Custom", symbol: "slider.horizontal.3",
                               isBuiltIn: false, mode: .curve(.balanced))
        p.id = UUID(); p.isBuiltIn = false
        p.name = uniqueName(base.map { "\($0.name) copy" } ?? "Custom")
        presets.append(p); save()
        return p
    }

    func update(_ p: Preset) {
        guard !p.isBuiltIn, let i = presets.firstIndex(where: { $0.id == p.id }), presets[i] != p else { return }
        presets[i] = p; save()
    }

    func delete(_ p: Preset) {
        guard !p.isBuiltIn else { return }
        presets.removeAll { $0.id == p.id }
        if activeID == p.id { activeID = Preset.automatic.id }
        save()
    }

    private func uniqueName(_ base: String) -> String {
        var n = 1, name = base
        while presets.contains(where: { $0.name == name }) { n += 1; name = "\(base) \(n)" }
        return name
    }
}
