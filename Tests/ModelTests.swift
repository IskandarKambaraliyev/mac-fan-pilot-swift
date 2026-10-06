import XCTest

final class CurveTests: XCTestCase {
    private let curve = Curve(points: [.init(temp: 50, percent: 0), .init(temp: 70, percent: 0.5), .init(temp: 90, percent: 1)])

    func testInterpolatesBetweenPointsAndClampsOutsideThem() {
        XCTAssertEqual(curve.percent(at: 20), 0)
        XCTAssertEqual(curve.percent(at: 50), 0)
        XCTAssertEqual(curve.percent(at: 60), 0.25, accuracy: 1e-9)
        XCTAssertEqual(curve.percent(at: 80), 0.75, accuracy: 1e-9)
        XCTAssertEqual(curve.percent(at: 90), 1)
        XCTAssertEqual(curve.percent(at: 120), 1)
    }

    func testPointOrderDoesNotMatter() {
        let shuffled = Curve(points: curve.points.reversed())
        for t in stride(from: 40.0, through: 100, by: 5) {
            XCTAssertEqual(shuffled.percent(at: t), curve.percent(at: t), accuracy: 1e-9)
        }
    }

    func testTwoPointsAtTheSameTemperatureMakeAStepNotADivisionByZero() {
        let step = Curve(points: [.init(temp: 60, percent: 0.2), .init(temp: 60, percent: 0.8)])
        XCTAssertEqual(step.percent(at: 59), 0.2)
        XCTAssertEqual(step.percent(at: 61), 0.8)
        XCTAssertTrue(step.percent(at: 60).isFinite)
    }

    func testAnUnreadableTemperatureAsksForTheTopOfTheCurve() {
        XCTAssertEqual(curve.percent(at: .nan), 1)
    }

    func testSanitizedDropsBadPointsAndClampsTheRest() {
        let dirty = Curve(points: [.init(temp: .nan, percent: 0.5), .init(temp: 60, percent: 7), .init(temp: 70, percent: -1)]
                          + (0..<20).map { .init(temp: Double($0), percent: 0.5) })
        let clean = dirty.sanitized
        XCTAssertEqual(clean?.points.count, Curve.maxPoints)
        XCTAssertEqual(clean?.points[0].percent, 1)
        XCTAssertEqual(clean?.points[1].percent, 0)
        XCTAssertNil(Curve(points: [.init(temp: .infinity, percent: 0)]).sanitized)
    }
}

final class PresetTests: XCTestCase {
    private func preset(_ mode: FanMode, perFan: [Int: FanMode] = [:]) -> Preset {
        Preset(id: UUID(), name: "Test", symbol: "fan", isBuiltIn: false, mode: mode, perFan: perFan)
    }

    func testAnythingUnsafeBecomesAutomatic() {
        XCTAssertEqual(FanMode.fixedRPM(.nan).sanitized, .auto)
        XCTAssertEqual(FanMode.fixedPercent(.infinity).sanitized, .auto)
        XCTAssertEqual(FanMode.fixedPercent(3).sanitized, .fixedPercent(1))
        XCTAssertEqual(FanMode.fixedRPM(-50).sanitized, .fixedRPM(0))
        XCTAssertEqual(FanMode.curve(Curve(points: [])).sanitized, .auto)
        XCTAssertEqual(preset(.auto, perFan: [0: .fixedRPM(.nan)]).sanitized.perFan[0], .auto)
    }

    func testAllAutoLooksAtEveryFan() {
        XCTAssertTrue(preset(.auto).isAllAuto)
        XCTAssertTrue(preset(.auto, perFan: [1: .auto]).isAllAuto)
        XCTAssertFalse(preset(.auto, perFan: [1: .fixedRPM(3000)]).isAllAuto)
        XCTAssertFalse(preset(.fixedRPM(3000), perFan: [0: .auto, 1: .auto]).isAllAuto)
    }

    func testUsesFindsASensorInAnOverride() {
        var average = Curve.balanced
        average.sensor = .cpuAverage
        XCTAssertTrue(preset(.auto, perFan: [1: .curve(average)]).uses(.cpuAverage))
        XCTAssertFalse(preset(.curve(.balanced)).uses(.cpuAverage))
    }

    func testOverridesApplyToTheirFanOnly() {
        let p = preset(.fixedRPM(2000), perFan: [1: .fixedRPM(4000)])
        XCTAssertEqual(p.mode(forFan: 0), .fixedRPM(2000))
        XCTAssertEqual(p.mode(forFan: 1), .fixedRPM(4000))
    }

    func testDecodesWithOnlyTheRequiredFields() throws {
        let json = #"{"id":"57984D2B-2C03-4D35-BAF1-BC3846CD5607","name":"Bare","mode":{"curve":{"_0":{"points":[{"temp":50,"percent":0.5}]}}}}"#
        let p = try JSONDecoder().decode(Preset.self, from: Data(json.utf8))
        XCTAssertEqual(p.symbol, Preset.customSymbol)
        XCTAssertFalse(p.isBuiltIn)
        XCTAssertTrue(p.perFan.isEmpty)
        XCTAssertEqual(p.mode.curveSensor, .cpuMax)
    }

    func testAnUnknownSensorFallsBackToTheHottestOne() throws {
        let json = #"{"sensor":"ssd","points":[{"temp":50,"percent":0.5}]}"#
        XCTAssertEqual(try JSONDecoder().decode(Curve.self, from: Data(json.utf8)).sensor, .hottest)
    }

    func testSurvivesARoundTrip() throws {
        let p = preset(.curve(.performance), perFan: [0: .fixedPercent(0.4), 1: .auto])
        XCTAssertEqual(try JSONDecoder().decode(Preset.self, from: JSONEncoder().encode(p)), p)
    }
}

final class SMCValueTests: XCTestCase {
    private func value(_ type: String, _ bytes: [UInt8]) -> Double? {
        SMCValue(key: "TEST", type: type, bytes: bytes).doubleValue
    }

    func testDecodesTheTypesTheAppReads() {
        XCTAssertEqual(value("flt ", [0x00, 0x00, 0x48, 0x42]), 50)        // little-endian float
        XCTAssertEqual(value("ui8 ", [2]), 2)
        XCTAssertEqual(value("ui16", [0x12, 0x34]), 0x1234)                // integers are big-endian
        XCTAssertEqual(value("ui32", [0, 0, 0x01, 0x00]), 256)
        XCTAssertEqual(value("sp78", [0x32, 0x80]), 50.5)
        XCTAssertNil(value("flt ", [0x00]))
        XCTAssertNil(value("ch8*", [0x41]))
    }

    func testEncodesWhatItWrites() {
        XCTAssertEqual(SMCValue.encode(50, type: "flt "), [0x00, 0x00, 0x48, 0x42])
        XCTAssertEqual(SMCValue.encode(1, type: "ui8 "), [1])
        XCTAssertEqual(SMCValue.encode(999, type: "ui8 "), [255])
        XCTAssertEqual(SMCValue.encode(0x1234, type: "ui16"), [0x12, 0x34])
        XCTAssertNil(SMCValue.encode(.nan, type: "flt "))
        XCTAssertNil(SMCValue.encode(1, type: "sp78"))
    }

    func testFourCharacterCodes() {
        XCTAssertEqual("F0Ac".fourCC, 0x4630_4163)
        XCTAssertEqual(UInt32(0x4630_4163).fourCCString, "F0Ac")
    }
}

final class TemperatureTests: XCTestCase {
    func testFormatsInEitherUnit() {
        XCTAssertEqual(Temperature.string(49.6, fahrenheit: false), "50°")
        XCTAssertEqual(Temperature.string(100, fahrenheit: true), "212°F")
        XCTAssertEqual(Temperature.string(nil, fahrenheit: false), "–")
    }

    func testConvertsBothWays() {
        XCTAssertEqual(Temperature.displayed(30, fahrenheit: true), 86)
        XCTAssertEqual(Temperature.celsius(fromDisplayed: 212, fahrenheit: true), 100, accuracy: 1e-9)
        XCTAssertEqual(Temperature.celsius(fromDisplayed: 40, fahrenheit: false), 40)
    }
}

final class MenuBarDisplayTests: XCTestCase {
    func testReadsWhatAnyVersionStored() {
        XCTAssertEqual(MenuBarDisplay(stored: "temp"), .temp)
        XCTAssertEqual(MenuBarDisplay(stored: "CPU temperature"), .temp)   // 1.0 stored the menu title
        XCTAssertEqual(MenuBarDisplay(stored: "Temperature + speed"), .both)
        XCTAssertEqual(MenuBarDisplay(stored: nil), .iconOnly)
        XCTAssertEqual(MenuBarDisplay(stored: "nonsense"), .iconOnly)
    }
}
