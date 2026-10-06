import AppIntents

// "Set Fan Preset" for Shortcuts (and so for keyboard shortcuts and automations), and the same
// thing as a Focus filter. Both run inside the app and go through the same model as the popover.

struct PresetEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Fan Preset"
    static var defaultQuery = PresetQuery()

    let id: UUID
    let name: String
    let symbol: String

    init(_ preset: Preset) {
        id = preset.id
        name = preset.name
        symbol = preset.symbol
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", image: .init(systemName: symbol))
    }
}

struct PresetQuery: EntityQuery {
    @MainActor
    func entities(for identifiers: [UUID]) async throws -> [PresetEntity] {
        AppModel.shared.presets.presets.filter { identifiers.contains($0.id) }.map(PresetEntity.init)
    }

    @MainActor
    func suggestedEntities() async throws -> [PresetEntity] {
        AppModel.shared.presets.presets.map(PresetEntity.init)
    }
}

enum FanIntentError: Error, CustomLocalizedStringResourceConvertible {
    case presetGone, helperMissing, failed(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .presetGone: "That preset no longer exists."
        case .helperMissing: "Install the fan helper in MacFanPilot first."
        case .failed(let message): "\(message)"
        }
    }
}

struct SetFanPresetIntent: AppIntent {
    static var title: LocalizedStringResource = "Set Fan Preset"
    static var description = IntentDescription("Switches MacFanPilot to one of its presets.")

    @Parameter(title: "Preset")
    var preset: PresetEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Set the fans to \(\.$preset)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let model = AppModel.shared
        model.start()   // a shortcut can be what launches the app
        guard let chosen = model.presets.presets.first(where: { $0.id == preset.id }) else {
            throw FanIntentError.presetGone
        }
        await model.activate(chosen)
        guard model.helper.state == .ready || chosen.isAllAuto else { throw FanIntentError.helperMissing }
        if let error = model.lastError { throw FanIntentError.failed(error) }
        return .result()
    }
}

struct FanFocusFilter: SetFocusFilterIntent {
    static var title: LocalizedStringResource = "Set Fan Preset"
    static var description: IntentDescription? = "Switches to a fan preset while this Focus is on."

    @Parameter(title: "Preset")
    var preset: PresetEntity?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(preset?.name ?? "No preset")")
    }

    /// Called with the preset when the Focus comes on, and without one when it goes off.
    @MainActor
    func perform() async throws -> some IntentResult {
        let model = AppModel.shared
        model.start()
        await model.focusChanged(to: preset?.id)
        return .result()
    }
}

struct FanShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: SetFanPresetIntent(),
                    phrases: ["Set \(.applicationName) preset", "Change the fan preset in \(.applicationName)"],
                    shortTitle: "Set Fan Preset",
                    systemImageName: "fan")
    }
}
