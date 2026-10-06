import Foundation
import Observation
import os

enum PresetFileError: LocalizedError {
    case unreadable, empty
    var errorDescription: String? {
        switch self {
        case .unreadable: "That file isn't a \(FP.appName) preset file."
        case .empty: "That file has no custom presets in it."
        }
    }
}

/// presets.json, and the format presets are exported in. 1.0 wrote a bare array of presets; the
/// wrapper lets the format change later without older files becoming unreadable.
struct PresetFile: Encodable {
    static let currentVersion = 2

    var version = PresetFile.currentVersion
    var presets: [Preset]

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    /// Decodes whatever it can; nil if the data isn't a preset file at all. `complete` is false
    /// when a preset had to be skipped or the file comes from a newer version.
    static func read(_ data: Data) -> (presets: [Preset], complete: Bool)? {
        struct Lossy: Decodable {
            let preset: Preset?
            init(from decoder: Decoder) throws { preset = try? Preset(from: decoder) }
        }
        struct Wrapper: Decodable { let version: Int; let presets: [Lossy] }

        let decoder = JSONDecoder()
        let version: Int, items: [Lossy]
        if let wrapper = try? decoder.decode(Wrapper.self, from: data) {
            (version, items) = (wrapper.version, wrapper.presets)
        } else if let legacy = try? decoder.decode([Lossy].self, from: data) {
            (version, items) = (1, legacy)
        } else {
            return nil
        }
        let presets = items.compactMap(\.preset)
        return (presets, presets.count == items.count && version <= currentVersion)
    }
}

@MainActor
@Observable
final class PresetStore {
    private static let saveDelay = Duration.milliseconds(500)
    private static let maxNameLength = 60

    private(set) var presets: [Preset] = Preset.builtIns
    /// The preset the user chose. Whether it is actually running is `AppModel`'s business.
    var activeID: UUID {
        didSet { defaults.set(activeID.uuidString, forKey: "activePresetID") }
    }

    @ObservationIgnored private let log = Logger(subsystem: FP.appBundleID, category: "presets")
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let url: URL
    @ObservationIgnored private var unsaved = false
    @ObservationIgnored private var pendingSave: Task<Void, Never>?
    /// The file holds something this version couldn't fully read, so it is copied aside before
    /// the first save replaces it.
    @ObservationIgnored private var backupBeforeSave = false

    init(directory: URL? = nil, defaults: UserDefaults = .standard) {
        let dir = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(FP.appName, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("presets.json")
        self.defaults = defaults
        activeID = defaults.string(forKey: "activePresetID").flatMap(UUID.init) ?? Preset.automatic.id
        load()
    }

    var active: Preset { presets.first { $0.id == activeID } ?? .automatic }
    var custom: [Preset] { presets.filter { !$0.isBuiltIn } }

    func load() {
        var saved: [Preset] = []
        if let data = try? Data(contentsOf: url) {
            let file = PresetFile.read(data)
            saved = file?.presets ?? []
            backupBeforeSave = !(file?.complete ?? false)
            if backupBeforeSave { log.error("presets.json is damaged or from a newer version; keeping a copy") }
        }
        var seen = Set(Preset.builtIns.map(\.id))
        presets = Preset.builtIns + saved.filter { !$0.isBuiltIn && seen.insert($0.id).inserted }
        if !presets.contains(where: { $0.id == activeID }) { activeID = Preset.automatic.id }
    }

    // MARK: Saving

    /// Writes pending changes now. Call before quitting.
    func flush() {
        pendingSave?.cancel()
        pendingSave = nil
        guard unsaved else { return }
        unsaved = false
        do {
            if backupBeforeSave {
                let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false)
                    .dateSeparator(.dash).timeSeparator(.omitted))
                try FileManager.default.copyItem(
                    at: url, to: url.deletingLastPathComponent().appendingPathComponent("presets.backup-\(stamp).json"))
                backupBeforeSave = false
            }
            try PresetFile(presets: custom).encoded().write(to: url, options: .atomic)
        } catch {
            log.error("couldn't save presets: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Dragging a curve point changes the preset many times a second; one write covers them all.
    private func saveSoon() {
        unsaved = true
        guard pendingSave == nil else { return }
        pendingSave = Task { [weak self] in
            try? await Task.sleep(for: Self.saveDelay)
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    private func saveNow() {
        unsaved = true
        flush()
    }

    // MARK: Editing

    @discardableResult
    func add(basedOn base: Preset? = nil) -> Preset {
        let p = insert(base ?? Preset(id: UUID(), name: "Custom", symbol: Preset.customSymbol,
                                      isBuiltIn: false, mode: .curve(.balanced)),
                       named: base.map { "\($0.name) copy" } ?? "Custom")
        saveNow()
        return p
    }

    func update(_ p: Preset) {
        guard !p.isBuiltIn, let i = presets.firstIndex(where: { $0.id == p.id }), presets[i] != p else { return }
        presets[i] = p
        saveSoon()
    }

    func delete(_ p: Preset) {
        guard !p.isBuiltIn else { return }
        presets.removeAll { $0.id == p.id }
        if activeID == p.id { activeID = Preset.automatic.id }
        saveNow()
    }

    // MARK: Import / export

    func exportData() throws -> Data { try PresetFile(presets: custom).encoded() }

    /// Adds the custom presets from an exported file as new presets, and returns them.
    @discardableResult
    func importPresets(from data: Data) throws -> [Preset] {
        guard let file = PresetFile.read(data) else { throw PresetFileError.unreadable }
        let incoming = file.presets.filter { !$0.isBuiltIn }
        guard !incoming.isEmpty else { throw PresetFileError.empty }
        let added = incoming.map { preset in
            let name = String(preset.name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maxNameLength))
            return insert(preset.sanitized, named: name.isEmpty ? "Imported" : name)
        }
        saveNow()
        return added
    }

    /// Appends a copy with its own identity and a name that isn't taken yet.
    private func insert(_ source: Preset, named name: String) -> Preset {
        var p = source
        p.id = UUID()
        p.isBuiltIn = false
        p.name = uniqueName(name)
        presets.append(p)
        return p
    }

    private func uniqueName(_ base: String) -> String {
        var n = 1, name = base
        while presets.contains(where: { $0.name == name }) { n += 1; name = "\(base) \(n)" }
        return name
    }
}
