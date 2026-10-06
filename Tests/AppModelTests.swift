import XCTest

@MainActor
final class AppModelTests: XCTestCase {
    private var sandbox: Sandbox!
    private var helper: FakeHelper!
    private var power: FakePower!
    private var notifications: [String] = []

    override func setUp() async throws {
        sandbox = Sandbox()
        helper = FakeHelper()
        power = FakePower()
        notifications = []
    }

    override func tearDown() async throws { sandbox.cleanUp() }

    /// Retries come quickly here so the tests don't wait for the real delays.
    private func makeModel(retryDelays: [Double] = [0.02, 0.02]) -> AppModel {
        let store = PresetStore(directory: sandbox.directory, defaults: sandbox.defaults)
        let model = AppModel(presets: store, helper: helper, power: power,
                             defaults: sandbox.defaults, retryDelays: retryDelays)
        model.postNotification = { [unowned self] title, _ in self.notifications.append(title) }
        model.start(monitoring: false)
        return model
    }

    private func snapshot(cpu: Double = 50, manual: Bool = false) -> SensorMonitor.Snapshot {
        SensorMonitor.Snapshot(
            fans: [FanReading(id: 0, rpm: 2000, min: 1200, max: 6000, manual: manual),
                   FanReading(id: 1, rpm: 2100, min: 1200, max: 6000, manual: manual)],
            groups: [.cpuMax: cpu, .gpuMax: cpu - 5, .hottest: cpu])
    }

    // MARK: Applying

    func testChoosingAPresetHandsItToTheHelper() async {
        let model = makeModel()
        await model.activate(.balanced)
        XCTAssertEqual(helper.applied.last, .balanced)
        XCTAssertTrue(model.isControlling)
        XCTAssertEqual(model.controlState, .controlling)
        XCTAssertNil(model.lastError)

        await model.activate(.automatic)
        XCTAssertFalse(model.isControlling)
        XCTAssertEqual(model.controlState, .automatic)
    }

    func testAFailedApplyKeepsTheChoiceAndTriesAgain() async {
        let model = makeModel()
        helper.failuresToCome = 1
        await model.activate(.balanced)
        XCTAssertEqual(model.presets.activeID, Preset.balanced.id, "the choice is not thrown away")
        XCTAssertFalse(model.isControlling)
        XCTAssertNotNil(model.lastError)
        XCTAssertEqual(model.controlState, .stopped)

        await eventually("the retry") { model.isControlling }
        XCTAssertNil(model.lastError)
        XCTAssertTrue(notifications.isEmpty, "a retry that works is not worth a notification")
    }

    func testGivesUpAfterTheRetriesAndSaysSoOnce() async {
        let model = makeModel()
        helper.failuresToCome = 10
        await model.activate(.balanced)
        await eventually("the retries to run out") { self.notifications.count == 1 }
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(helper.applied.count, 3, "one attempt and two retries")
        XCTAssertEqual(notifications, ["Fan control stopped"])
        XCTAssertEqual(model.presets.activeID, Preset.balanced.id)
    }

    func testANewChoiceCancelsThePendingRetry() async {
        let model = makeModel(retryDelays: [0.05])
        helper.failuresToCome = 1
        await model.activate(.balanced)
        await model.activate(.automatic)
        try? await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(helper.applied.map(\.name), ["Balanced", "Automatic"])
        XCTAssertNil(model.lastError)
    }

    func testWithoutTheHelperNothingIsApplied() async {
        helper.state = .notInstalled
        let model = makeModel()
        await model.activate(.balanced)
        XCTAssertTrue(helper.applied.isEmpty)
        XCTAssertEqual(model.presets.activeID, Preset.balanced.id)
        XCTAssertFalse(model.isControlling)
        XCTAssertEqual(model.controlState, .automatic)
    }

    func testNotificationsCanBeTurnedOff() async {
        let model = makeModel(retryDelays: [])
        model.notificationsEnabled = false
        helper.failuresToCome = 1
        await model.activate(.balanced)
        XCTAssertTrue(notifications.isEmpty)
        XCTAssertNotNil(model.lastError)
    }

    // MARK: What the helper reports

    func testWhenTheHelperGivesUpThePresetStaysSelectedAndIsRetried() async {
        let model = makeModel()
        await model.activate(.balanced)
        helper.onStatus?(.sensorFailure)
        XCTAssertFalse(model.isControlling)
        XCTAssertEqual(model.controlState, .stopped)
        XCTAssertEqual(notifications, ["Fan control stopped"])
        XCTAssertEqual(model.presets.activeID, Preset.balanced.id)

        await eventually("the retry") { model.isControlling }
        XCTAssertEqual(helper.applied.map(\.name), ["Balanced", "Automatic", "Balanced"])
    }

    func testAnEmergencyIsShownAndAnnouncedOnce() async {
        let model = makeModel()
        await model.activate(.balanced)
        helper.onStatus?(.emergency)
        helper.onStatus?(.emergency)
        XCTAssertTrue(model.emergency)
        XCTAssertEqual(model.controlState, .emergency)
        XCTAssertEqual(notifications, ["Fans at maximum"])

        helper.onStatus?(.controlling)
        XCTAssertFalse(model.emergency)
        XCTAssertEqual(model.controlState, .controlling)
    }

    func testAHelperThatRestartedGetsThePresetAgain() async {
        let model = makeModel()
        await model.activate(.performance)
        helper.onStatus?(.watchdogReset)
        await eventually("the re-apply") { self.helper.applied.count == 2 }
        XCTAssertEqual(helper.applied.last, .performance)
        XCTAssertTrue(model.isControlling)
    }

    func testStatusIsIgnoredWhileNotControlling() async {
        let model = makeModel()
        helper.onStatus?(.sensorFailure)
        helper.onStatus?(.idle)
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(helper.applied.isEmpty)
        XCTAssertNil(model.lastError)
    }

    // MARK: Rules

    func testOnBatteryThePresetIsSetAsideNotForgotten() async {
        let model = makeModel()
        model.autoOnBattery = true
        await model.activate(.balanced)
        XCTAssertTrue(model.isControlling)

        power.switchTo(battery: true)
        await eventually("the switch to Automatic") { !model.isControlling }
        XCTAssertTrue(model.pausedOnBattery)
        XCTAssertEqual(helper.applied.last, .automatic)
        XCTAssertEqual(model.presets.activeID, Preset.balanced.id)
        XCTAssertEqual(model.controlState, .automatic)

        await model.activate(.performance)   // choosing another preset on battery changes what comes back
        XCTAssertFalse(model.isControlling)

        power.switchTo(battery: false)
        await eventually("the preset to come back") { model.isControlling }
        XCTAssertEqual(helper.applied.last, .performance)
    }

    func testBatteryIsIgnoredUnlessTheRuleIsOn() async {
        let model = makeModel()
        await model.activate(.balanced)
        power.switchTo(battery: true)
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(model.isControlling)
        XCTAssertFalse(model.pausedOnBattery)
    }

    func testAFocusBorrowsThePresetAndGivesItBack() async {
        let model = makeModel()
        await model.activate(.performance)

        await model.focusChanged(to: Preset.fullBlast.id)
        XCTAssertEqual(model.presets.activeID, Preset.fullBlast.id)
        await model.focusChanged(to: nil)
        XCTAssertEqual(model.presets.activeID, Preset.performance.id)

        await model.focusChanged(to: nil)   // nothing to restore the second time
        XCTAssertEqual(model.presets.activeID, Preset.performance.id)
    }

    func testAFocusEndingDoesNotUndoAChoiceMadeDuringIt() async {
        let model = makeModel()
        await model.activate(.performance)
        await model.focusChanged(to: Preset.fullBlast.id)
        await model.activate(.balanced)
        await model.focusChanged(to: nil)
        XCTAssertEqual(model.presets.activeID, Preset.balanced.id)
    }

    // MARK: Sensors

    func testFansHeldBySomethingElseAreNoticedAfterTwoSnapshots() async {
        let model = makeModel()
        model.received(snapshot(manual: true))
        XCTAssertFalse(model.externalControl, "one snapshot could be the moment after we let go")
        model.received(snapshot(manual: true))
        XCTAssertTrue(model.externalControl)

        await model.activate(.balanced)
        XCTAssertFalse(model.externalControl, "taking control clears it at once")
        model.received(snapshot(manual: true))
        model.received(snapshot(manual: true))
        XCTAssertFalse(model.externalControl, "now it is us")
    }

    func testHistoryKeepsFiveMinutesAtFiveSecondSpacing() {
        let model = makeModel()
        let start = Date(timeIntervalSinceReferenceDate: 0)
        for second in 0..<900 {
            model.received(snapshot(cpu: 40 + Double(second % 30)), at: start.addingTimeInterval(Double(second)))
        }
        XCTAssertEqual(model.history.count, Int(AppModel.historyWindow / AppModel.historySpacing) + 1)
        let newest = model.history.last!.date, oldest = model.history.first!.date
        XCTAssertLessThanOrEqual(newest.timeIntervalSince(oldest), AppModel.historyWindow)
        XCTAssertEqual(model.history.last?.gpu, model.history.last.flatMap { $0.cpu.map { $0 - 5 } })
    }

    func testSettingsPersist() {
        let model = makeModel()
        model.display = .both
        model.useFahrenheit = true
        model.autoOnBattery = true
        model.notificationsEnabled = false
        let relaunched = makeModel()
        XCTAssertEqual(relaunched.display, .both)
        XCTAssertTrue(relaunched.useFahrenheit)
        XCTAssertTrue(relaunched.autoOnBattery)
        XCTAssertFalse(relaunched.notificationsEnabled)
        XCTAssertEqual(relaunched.format(temp: 100), "212°F")
    }

    func testDiagnosticsDescribeTheSetup() async {
        let model = makeModel()
        var preset = model.presets.add()
        preset.mode = .fixedRPM(3000)
        preset.perFan = [1: .auto]
        model.presets.update(preset)
        await model.activate(preset)
        let text = await model.diagnostics()
        XCTAssertTrue(text.contains("Helper: installed"))
        XCTAssertTrue(text.contains("Preset: Custom (fixed 3000 rpm; fan 2: automatic)"))
        XCTAssertTrue(text.contains("State: controlling"))
    }
}
