import XCTest

@MainActor
final class PresetStoreTests: XCTestCase {
    private var sandbox: Sandbox!

    override func setUp() async throws { sandbox = Sandbox() }
    override func tearDown() async throws { sandbox.cleanUp() }

    private func makeStore() -> PresetStore { PresetStore(directory: sandbox.directory, defaults: sandbox.defaults) }
    private func write(_ text: String) throws { try Data(text.utf8).write(to: sandbox.presetsFile) }
    private func fileText() throws -> String { try String(contentsOf: sandbox.presetsFile, encoding: .utf8) }
    private var backups: [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: sandbox.directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("presets.backup-") }
    }

    func testStartsWithTheBuiltInsAndAutomaticSelected() {
        let store = makeStore()
        XCTAssertEqual(store.presets, Preset.builtIns)
        XCTAssertEqual(store.active, .automatic)
        XCTAssertTrue(store.custom.isEmpty)
    }

    func testReadsThePresetsThat10Saved() throws {
        try write(legacyPresetsJSON)
        let store = makeStore()
        XCTAssertEqual(store.custom.map(\.name), ["Quiet work", "Render"])
        XCTAssertEqual(store.custom[0].mode, .fixedRPM(5000))
        XCTAssertEqual(store.custom[1].mode.curveSensor, .gpuMax)
        XCTAssertEqual(store.custom[1].perFan, [1: .auto])
        XCTAssertTrue(backups.isEmpty)
    }

    func testSavesInTheVersionedFormatWithoutABackupOfAGoodFile() throws {
        try write(legacyPresetsJSON)
        let store = makeStore()
        store.add()
        XCTAssertTrue(try fileText().contains("\"version\" : \(PresetFile.currentVersion)"))
        XCTAssertTrue(backups.isEmpty, "a file that was read completely needs no backup")
        XCTAssertEqual(makeStore().custom.map(\.name), ["Quiet work", "Render", "Custom"])
    }

    func testAnUnreadableFileIsKeptAsideBeforeItIsReplaced() throws {
        try write("{ this is not json")
        let store = makeStore()
        XCTAssertTrue(store.custom.isEmpty)
        XCTAssertEqual(try fileText(), "{ this is not json", "loading must not touch the file")

        store.add()
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try String(contentsOf: backups[0], encoding: .utf8), "{ this is not json")
        XCTAssertEqual(makeStore().custom.count, 1)
    }

    func testOnePresetItCannotReadDoesNotTakeTheOthersWithIt() throws {
        let unknownMode = #"{"id":"57984D2B-2C03-4D35-BAF1-BC3846CD5609","name":"Future","mode":{"hyperdrive":{}}}"#
        try write("[" + unknownMode + "," + String(legacyPresetsJSON.dropFirst()))
        let store = makeStore()
        XCTAssertEqual(store.custom.map(\.name), ["Quiet work", "Render"])

        store.delete(store.custom[0])
        XCTAssertEqual(backups.count, 1, "the preset that was skipped survives in the backup")
        XCTAssertTrue(try String(contentsOf: backups[0], encoding: .utf8).contains("hyperdrive"))
    }

    func testAFileFromANewerVersionIsBackedUpBeforeSaving() throws {
        try write(#"{"version":99,"presets":"# + legacyPresetsJSON + "}")
        let store = makeStore()
        XCTAssertEqual(store.custom.count, 2)
        store.add()
        XCTAssertEqual(backups.count, 1)
    }

    func testEditsWhileDraggingAreWrittenOnce() throws {
        let store = makeStore()
        var preset = store.add()
        let before = try fileText()

        for rpm in stride(from: 2000.0, through: 4000, by: 100) {
            preset.mode = .fixedRPM(rpm)
            store.update(preset)
        }
        XCTAssertEqual(store.presets.last?.mode, .fixedRPM(4000), "the store itself is always current")
        XCTAssertEqual(try fileText(), before, "nothing is written while the changes keep coming")

        store.flush()
        XCTAssertEqual(makeStore().custom.last?.mode, .fixedRPM(4000))
    }

    func testPendingEditsAreWrittenAfterAShortDelay() async throws {
        let store = makeStore()
        var preset = store.add()
        preset.name = "Renamed"
        store.update(preset)
        await eventually("the delayed save") { self.makeStore().custom.last?.name == "Renamed" }
    }

    func testBuiltInsCannotBeChangedOrDeleted() {
        let store = makeStore()
        var balanced = Preset.balanced
        balanced.mode = .fixedPercent(1)
        store.update(balanced)
        store.delete(.balanced)
        XCTAssertEqual(store.presets, Preset.builtIns)
    }

    func testCopiesGetTheirOwnIdentityAndAFreeName() {
        let store = makeStore()
        let first = store.add(basedOn: .balanced)
        let second = store.add(basedOn: .balanced)
        XCTAssertEqual(first.name, "Balanced copy")
        XCTAssertEqual(second.name, "Balanced copy 2")
        XCTAssertNotEqual(first.id, Preset.balanced.id)
        XCTAssertFalse(first.isBuiltIn)
        XCTAssertEqual(first.mode, Preset.balanced.mode)
    }

    func testDeletingTheActivePresetSelectsAutomatic() {
        let store = makeStore()
        let preset = store.add()
        store.activeID = preset.id
        store.delete(preset)
        XCTAssertEqual(store.activeID, Preset.automatic.id)
    }

    func testTheSelectionSurvivesARelaunchUnlessItsPresetIsGone() throws {
        let store = makeStore()
        store.activeID = store.add().id
        XCTAssertEqual(makeStore().activeID, store.activeID)

        try FileManager.default.removeItem(at: sandbox.presetsFile)
        XCTAssertEqual(makeStore().activeID, Preset.automatic.id)
    }

    func testExportedPresetsImportAsNewCopies() throws {
        let source = makeStore()
        var preset = source.add()
        preset.name = "Travel"
        preset.mode = .fixedRPM(2500)
        preset.perFan = [0: .curve(.performance)]
        source.update(preset)
        let exported = try source.exportData()

        let imported = try source.importPresets(from: exported)
        XCTAssertEqual(imported.map(\.name), ["Travel 2"])
        XCTAssertNotEqual(imported[0].id, preset.id)
        XCTAssertEqual(imported[0].mode, preset.mode)
        XCTAssertEqual(imported[0].perFan, preset.perFan)
        XCTAssertEqual(makeStore().custom.count, 2, "an import is saved straight away")
    }

    func testImportCleansWhatItTakesIn() throws {
        let hostile = #"[{"id":"57984D2B-2C03-4D35-BAF1-BC3846CD5607","name":"   ","isBuiltIn":false,"mode":{"fixedPercent":{"_0":40}}}]"#
        let imported = try makeStore().importPresets(from: Data(hostile.utf8))
        XCTAssertEqual(imported[0].name, "Imported")
        XCTAssertEqual(imported[0].mode, .fixedPercent(1))
    }

    func testImportRejectsFilesWithNothingToTake() throws {
        let store = makeStore()
        XCTAssertThrowsError(try store.importPresets(from: Data("hello".utf8))) {
            XCTAssertEqual($0 as? PresetFileError, .unreadable)
        }
        XCTAssertThrowsError(try store.importPresets(from: Data("[]".utf8))) {
            XCTAssertEqual($0 as? PresetFileError, .empty)
        }
        XCTAssertEqual(try store.importPresets(from: Data(legacyPresetsJSON.utf8)).count, 2, "a 1.0 presets.json imports too")
    }
}
