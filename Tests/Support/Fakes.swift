import Foundation
import XCTest

@MainActor
final class FakeHelper: FanHelper {
    struct Failure: LocalizedError {
        var errorDescription: String? { "helper said no" }
    }

    var state: HelperState = .ready
    var onStatus: ((HelperStatus) -> Void)?
    var onReady: (() -> Void)?
    /// Every preset handed over, in order.
    private(set) var applied: [Preset] = []
    /// This many of the next non-automatic applies fail.
    var failuresToCome = 0

    func refreshStatus() {}
    func install() {}
    func openApprovalSettings() {}
    func uninstall() async { state = .notInstalled }
    func resetToAuto() async {}

    func apply(_ preset: Preset) async throws {
        applied.append(preset)
        if !preset.isAllAuto, failuresToCome > 0 {
            failuresToCome -= 1
            throw Failure()
        }
    }
}

@MainActor
final class FakePower: PowerSource {
    var hasBattery = true
    var onBattery = false
    var onChange: (() -> Void)?

    func switchTo(battery: Bool) {
        onBattery = battery
        onChange?()
    }
}

/// A scratch folder and a private defaults domain, both emptied before and after each test.
@MainActor
final class Sandbox {
    private static let suite = "MacFanPilotTests"
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MacFanPilotTests-\(UUID().uuidString)")
    let defaults: UserDefaults

    init() {
        UserDefaults().removePersistentDomain(forName: Self.suite)
        defaults = UserDefaults(suiteName: Self.suite)!
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func cleanUp() {
        UserDefaults().removePersistentDomain(forName: Self.suite)
        try? FileManager.default.removeItem(at: directory)
    }

    var presetsFile: URL { directory.appendingPathComponent("presets.json") }
}

extension XCTestCase {
    /// Waits for something that happens on a later turn of the main actor (a retry, a callback).
    @MainActor
    func eventually(_ what: String, timeout: TimeInterval = 2, file: StaticString = #filePath, line: UInt = #line,
                    _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return XCTFail("timed out waiting for: \(what)", file: file, line: line) }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}

/// presets.json exactly as 1.0 wrote it: a bare array, with synthesized enum coding.
let legacyPresetsJSON = """
[{"isBuiltIn":false,"mode":{"fixedRPM":{"_0":5000}},"name":"Quiet work","perFan":{},"symbol":"slider.horizontal.3","id":"57984D2B-2C03-4D35-BAF1-BC3846CD5607"},
 {"isBuiltIn":false,"mode":{"curve":{"_0":{"sensor":"gpuMax","points":[{"id":"0A0B0C0D-0000-0000-0000-000000000001","temp":45,"percent":0.1},{"id":"0A0B0C0D-0000-0000-0000-000000000002","temp":85,"percent":1}]}}},"name":"Render","perFan":{"1":{"auto":{}}},"symbol":"bolt","id":"57984D2B-2C03-4D35-BAF1-BC3846CD5608"}]
"""
