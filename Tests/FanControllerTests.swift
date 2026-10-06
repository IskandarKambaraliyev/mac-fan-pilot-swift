import XCTest

/// The helper's control loop against a fake SMC, stepped by hand: no timer and no real waiting.
final class FanControllerTests: XCTestCase {
    private final class Clock { var now = 1000.0 }

    private var smc: FakeSMC!
    private var clock: Clock!
    private var marker: String!

    override func setUp() {
        smc = FakeSMC()
        clock = Clock()
        marker = NSTemporaryDirectory() + "MacFanPilotTests-\(UUID().uuidString).active"
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: marker)
    }

    private func makeController() -> FanController {
        let clock = clock!
        var environment = FanController.Environment()
        environment.now = { clock.now }
        environment.sleep = { clock.now += $0 }
        environment.markerPath = marker
        environment.runsTimer = false
        return FanController(smc: smc, environment: environment)
    }

    private func preset(_ mode: FanMode, perFan: [Int: FanMode] = [:]) -> Preset {
        Preset(id: UUID(), name: "Test", symbol: "fan", isBuiltIn: false, mode: mode, perFan: perFan)
    }

    /// Asks the way the app does, which also feeds the watchdog.
    private func status(of controller: FanController) -> HelperStatus {
        let done = DispatchSemaphore(value: 0)
        var result = HelperStatus.idle
        controller.heartbeat { result = $0; done.signal() }
        done.wait()
        return result
    }

    private func value(_ key: String) -> Double { smc.values[key] ?? .nan }
    private var markerExists: Bool { FileManager.default.fileExists(atPath: marker) }

    // MARK: Targets

    func testFixedSpeedIsHeldAndClampedToTheFansRange() throws {
        let controller = makeController()
        try controller.apply(preset(.fixedRPM(3000)))
        XCTAssertEqual(value("F0Md"), 1)
        XCTAssertEqual(value("F1Md"), 1)
        XCTAssertEqual(value("F0Tg"), 3000)
        XCTAssertEqual(status(of: controller), .controlling)
        XCTAssertTrue(markerExists)

        try controller.apply(preset(.fixedRPM(90_000)))
        XCTAssertEqual(value("F0Tg"), 6000)
        try controller.apply(preset(.fixedRPM(10)))
        XCTAssertEqual(value("F0Tg"), 1200, "never below the fan's own minimum")
        try controller.apply(preset(.fixedPercent(0.5)))
        XCTAssertEqual(value("F1Tg"), 3600)
    }

    func testCurveRampsUpAtOnceAndDownSlowly() throws {
        let controller = makeController()
        let curve = Curve(sensor: .cpuMax, points: [.init(temp: 50, percent: 0), .init(temp: 90, percent: 1)])
        try controller.apply(preset(.curve(curve)))
        XCTAssertEqual(value("F0Tg"), 1200)

        smc.setTemps(cpu: 90, gpu: 50)
        controller.tick()
        // Smoothed to 50·0.7 + 90·0.3 = 62 °C, which is 30% of the way up the curve.
        XCTAssertEqual(value("F0Tg"), 1200 + 4800 * 0.3, accuracy: 1)

        smc.setTemps(cpu: 50, gpu: 50)
        controller.tick()
        XCTAssertEqual(value("F0Tg"), 1200 + 4800 * 0.3 - FP.maxRampDownPerTick, accuracy: 1)
    }

    func testCurveFollowsItsOwnSensor() throws {
        let controller = makeController()
        smc.setTemps(cpu: 50, gpu: 90)
        let onGPU = Curve(sensor: .gpuMax, points: [.init(temp: 50, percent: 0), .init(temp: 90, percent: 1)])
        try controller.apply(preset(.curve(onGPU)))
        XCTAssertEqual(value("F0Tg"), 6000)
    }

    func testChoosingAutomaticLetsGo() throws {
        let controller = makeController()
        try controller.apply(preset(.fixedRPM(3000)))
        try controller.apply(.automatic)
        XCTAssertEqual(value("F0Md"), 0)
        XCTAssertEqual(value("F1Md"), 0)
        XCTAssertEqual(status(of: controller), .idle)
        XCTAssertFalse(markerExists)
    }

    // MARK: Per-fan modes

    func testAnAutomaticFanStaysWithMacOSWhenNoUnlockIsNeeded() throws {
        let controller = makeController()
        try controller.apply(preset(.auto, perFan: [1: .fixedRPM(4000)]))
        controller.tick()
        XCTAssertEqual(value("F0Md"), 0)
        XCTAssertEqual(value("F1Md"), 1)
        XCTAssertEqual(value("F1Tg"), 4000)
    }

    func testAnAutomaticFanBesideAHeldOneFollowsBalancedOnceUnlocked() throws {
        let smc = smc!
        // M3 and later: no manual mode until the unlock flag is up, and that takes every fan.
        smc.refuse = { [unowned smc] key, value in key.hasSuffix("Md") && value == 1 && smc.values["Ftst"] != 1 }
        smc.setTemps(cpu: 80, gpu: 60)
        let controller = makeController()
        try controller.apply(preset(.auto, perFan: [1: .fixedRPM(4000)]))
        XCTAssertEqual(value("Ftst"), 1)
        XCTAssertEqual(value("F1Tg"), 4000)

        controller.tick()
        XCTAssertEqual(value("F0Md"), 1, "nobody else is driving this fan any more")
        XCTAssertEqual(value("F0Tg"), 1200 + 4800 * Curve.balanced.percent(at: 80), accuracy: 1)
    }

    // MARK: Safety

    func testEmergencyForcesMaximumUntilItHasCooledDown() throws {
        let controller = makeController()
        try controller.apply(preset(.fixedRPM(2000)))

        smc.setTemps(cpu: FP.emergencyTemp + 1, gpu: 60)
        controller.tick()
        XCTAssertEqual(value("F0Tg"), 6000)
        XCTAssertEqual(value("F1Tg"), 6000)
        XCTAssertEqual(status(of: controller), .emergency)

        smc.setTemps(cpu: FP.emergencyReleaseTemp + 2, gpu: 60)   // cooler, but not cool enough
        controller.tick()
        XCTAssertEqual(value("F0Tg"), 6000)

        smc.setTemps(cpu: FP.emergencyReleaseTemp - 1, gpu: 60)
        controller.tick()
        XCTAssertEqual(value("F0Tg"), 6000 - FP.maxRampDownPerTick)
        XCTAssertEqual(status(of: controller), .controlling)
    }

    func testWatchdogHandsTheFansBackWhenHeartbeatsStop() throws {
        let controller = makeController()
        try controller.apply(preset(.fixedRPM(3000)))

        clock.now += FP.heartbeatTimeout - 1
        controller.tick()
        XCTAssertEqual(value("F0Md"), 1)

        clock.now += 2
        controller.tick()
        XCTAssertEqual(value("F0Md"), 0)
        XCTAssertEqual(value("F1Md"), 0)
        XCTAssertFalse(markerExists)
        XCTAssertEqual(status(of: controller), .watchdogReset)
    }

    func testHeartbeatsKeepControl() throws {
        let controller = makeController()
        try controller.apply(preset(.fixedRPM(3000)))
        for _ in 0..<5 {
            clock.now += FP.heartbeatTimeout - 5
            XCTAssertEqual(status(of: controller), .controlling)
            controller.tick()
        }
        XCTAssertEqual(value("F0Md"), 1)
    }

    func testUnreadableSensorsFailTheApplyOutright() {
        let controller = makeController()
        smc.setTemps(cpu: nil, gpu: nil)
        XCTAssertThrowsError(try controller.apply(preset(.fixedRPM(3000)))) {
            XCTAssertEqual($0 as? ControlError, .sensorsUnreadable)
        }
        XCTAssertEqual(value("F0Md"), 0)
        XCTAssertFalse(markerExists)
    }

    func testSensorsGoingDarkHandTheFansBackAfterThreeTicks() throws {
        let controller = makeController()
        try controller.apply(preset(.fixedRPM(3000)))
        smc.setTemps(cpu: nil, gpu: nil)

        for _ in 1..<FP.maxSensorFailures { controller.tick() }
        XCTAssertEqual(value("F0Md"), 1, "the last target is held for a tick or two")
        XCTAssertEqual(value("F0Tg"), 3000)

        controller.tick()
        XCTAssertEqual(value("F0Md"), 0)
        XCTAssertEqual(status(of: controller), .sensorFailure)
    }

    func testABriefSensorDropoutIsRiddenOut() throws {
        let controller = makeController()
        try controller.apply(preset(.fixedRPM(3000)))
        smc.setTemps(cpu: nil, gpu: nil)
        controller.tick()
        smc.setTemps(cpu: 55, gpu: 55)
        for _ in 0..<5 { controller.tick() }
        XCTAssertEqual(value("F0Md"), 1)
        XCTAssertEqual(status(of: controller), .controlling)
    }

    func testRepeatedWriteFailuresHandTheFansBack() throws {
        let controller = makeController()
        try controller.apply(preset(.fixedRPM(3000)))
        smc.refuse = { key, _ in key.hasSuffix("Tg") }

        for _ in 1..<FP.maxControlFailures { controller.tick() }
        XCTAssertEqual(value("F0Md"), 1)

        controller.tick()
        XCTAssertEqual(value("F0Md"), 0)
        XCTAssertEqual(value("F1Md"), 0)
        XCTAssertEqual(status(of: controller), .controlFailure)
    }

    // MARK: Taking and releasing the fans

    func testRaisesTheUnlockFlagWhenManualModeIsRefused() throws {
        let smc = smc!
        // thermalmonitord owns the fans until Ftst is raised, and then needs a moment to let go.
        var attemptsAfterUnlock = 0
        smc.refuse = { [unowned smc] key, value in
            guard key.hasSuffix("Md"), value == 1 else { return false }
            guard smc.values["Ftst"] == 1 else { return true }
            attemptsAfterUnlock += 1
            return attemptsAfterUnlock < 4
        }
        let controller = makeController()
        try controller.apply(preset(.fixedRPM(3000)))
        XCTAssertEqual(value("Ftst"), 1)
        XCTAssertEqual(value("F0Md"), 1)
        XCTAssertEqual(value("F1Tg"), 3000)

        XCTAssertTrue(controller.resetToAuto())
        XCTAssertEqual(value("Ftst"), 0)
        XCTAssertEqual(value("F0Md"), 0)
    }

    func testApplyGivesUpCleanlyWhenTheFansAreNeverReleased() {
        smc.refuse = { key, value in key.hasSuffix("Md") && value == 1 }
        let controller = makeController()
        let started = clock.now
        XCTAssertThrowsError(try controller.apply(preset(.fixedRPM(3000))))
        XCTAssertGreaterThanOrEqual(clock.now - started, FP.unlockTimeout - 1, "it waits before giving up")
        XCTAssertEqual(value("Ftst"), 0, "the unlock flag is lowered again")
        XCTAssertEqual(status(of: controller), .idle)
        XCTAssertFalse(markerExists)
    }

    func testStaysResponsibleWhileAFanCannotBeHandedBack() throws {
        let controller = makeController()
        try controller.apply(preset(.fixedRPM(3000)))

        smc.refuse = { key, value in key == "F1Md" && value == 0 }
        XCTAssertFalse(controller.resetToAuto(), "the helper must not exit while this is false")
        XCTAssertEqual(value("F0Md"), 0)
        XCTAssertEqual(value("F1Md"), 1)
        XCTAssertTrue(markerExists, "a relaunch still has to know the fans are held")

        smc.refuse = { _, _ in false }
        XCTAssertTrue(controller.resetToAuto())
        XCTAssertEqual(value("F1Md"), 0)
        XCTAssertFalse(markerExists)
    }

    func testAStaleMarkerMeansAPreviousHelperDiedHoldingTheFans() {
        FileManager.default.createFile(atPath: marker, contents: nil)
        smc.values["F0Md"] = 1
        smc.values["F1Md"] = 1
        smc.values["Ftst"] = 1
        _ = makeController()
        XCTAssertEqual(value("F0Md"), 0)
        XCTAssertEqual(value("F1Md"), 0)
        XCTAssertEqual(value("Ftst"), 0)
        XCTAssertFalse(markerExists)
    }

    func testAMacWithoutFansRefusesPresets() {
        smc = FakeSMC(fans: 0)
        let controller = makeController()
        XCTAssertThrowsError(try controller.apply(preset(.fixedRPM(3000)))) {
            XCTAssertEqual($0 as? ControlError, .noFans)
        }
    }
}
