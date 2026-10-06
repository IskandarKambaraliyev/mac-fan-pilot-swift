import XCTest
import SwiftUI

/// Lays out the main views against a model with made-up readings, to catch a view that crashes or
/// collapses. Set SNAPSHOT_DIR to also get a PNG of each one (for xcodebuild, pass it as
/// TEST_RUNNER_SNAPSHOT_DIR).
@MainActor
final class ViewSmokeTests: XCTestCase {
    private var sandbox: Sandbox!
    private var helper: FakeHelper!
    private var power: FakePower!
    private var model: AppModel!

    override func setUp() async throws {
        _ = NSApplication.shared
        sandbox = Sandbox()
        helper = FakeHelper()
        power = FakePower()
        let store = PresetStore(directory: sandbox.directory, defaults: sandbox.defaults)
        model = AppModel(presets: store, helper: helper, power: power, defaults: sandbox.defaults, retryDelays: [])
        model.postNotification = { _, _ in }
        model.start(monitoring: false)

        // Twelve minutes of readings: a warm-up, then a plateau.
        let start = Date().addingTimeInterval(-720)
        for second in stride(from: 0, through: 720, by: 5) {
            let cpu = 48 + 30 / (1 + exp(-Double(second - 500) / 40)) + 2 * sin(Double(second) / 15)
            model.received(SensorMonitor.Snapshot(
                fans: [FanReading(id: 0, rpm: 3480, min: 2317, max: 6800, manual: false),
                       FanReading(id: 1, rpm: 3515, min: 2317, max: 6800, manual: false)],
                groups: [.cpuMax: cpu, .cpuAverage: cpu - 6, .gpuMax: cpu - 12 + 3 * cos(Double(second) / 20), .hottest: cpu],
                raw: [SensorReading(id: "Tp01", name: "CPU sensor 1", value: cpu),
                      SensorReading(id: "Tg05", name: "GPU sensor 1", value: cpu - 12),
                      SensorReading(id: "TB0T", name: "Battery", value: 29.4),
                      SensorReading(id: "TaLP", name: "", value: 33.1)]),
                at: start.addingTimeInterval(Double(second)))
        }
    }

    override func tearDown() async throws { sandbox.cleanUp() }

    private func render(_ name: String, dark: Bool = false, size: CGSize? = nil, @ViewBuilder _ content: () -> some View,
                        file: StaticString = #filePath, line: UInt = #line) throws {
        let host = NSHostingView(rootView: content().environment(model)
            .background(Color(nsColor: .windowBackgroundColor)))   // the bitmap has no window behind it
        let window = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        let fitted = size ?? host.fittingSize
        window.setContentSize(fitted)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))   // charts and AppKit-backed controls draw a turn later

        XCTAssertGreaterThan(fitted.width, 100, "\(name) has no width", file: file, line: line)
        XCTAssertGreaterThan(fitted.height, 60, "\(name) has no height", file: file, line: line)

        guard let directory = ProcessInfo.processInfo.environment["SNAPSHOT_DIR"] else { return }
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds), file: file, line: line)
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]), file: file, line: line)
        try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
    }

    func testPopover() async throws {
        await model.activate(.balanced)
        try render("popover") { MenuContentView() }
        try render("popover-dark", dark: true) { MenuContentView() }
    }

    func testPopoverNotices() async throws {
        helper.failuresToCome = 1
        await model.activate(.performance)
        try render("popover-stopped") { MenuContentView() }

        model.autoOnBattery = true
        power.switchTo(battery: true)
        await eventually("the battery rule") { self.model.pausedOnBattery && self.model.lastError == nil }
        try render("popover-on-battery") { MenuContentView() }

        helper.state = .notInstalled
        try render("popover-no-helper") { MenuContentView() }
    }

    func testPopoverEmergency() async throws {
        await model.activate(.balanced)
        helper.onStatus?(.emergency)
        try render("popover-emergency") { MenuContentView() }
    }

    func testMenuBarLabel() async throws {
        for display in MenuBarDisplay.allCases {
            model.display = display
            let host = NSHostingView(rootView: MenuBarLabel().environment(model))
            XCTAssertGreaterThan(host.fittingSize.width, 8, "\(display)")
        }
    }

    func testSettingsTabs() async throws {
        await model.activate(.balanced)
        try render("settings-general") { SettingsView(tab: .general) }
        try render("settings-sensors") { SettingsView(tab: .sensors) }

        var custom = model.presets.add()
        custom.name = "Render"
        model.presets.update(custom)
        try render("settings-presets") { SettingsView(tab: .presets) }
    }

    func testPresetEditor() async throws {
        let size = CGSize(width: 400, height: 500)
        try render("editor-built-in", size: size) { PresetEditorView(preset: .balanced) }

        var custom = model.presets.add()
        custom.name = "Render"
        custom.mode = .curve(.performance)
        custom.perFan = [1: .fixedRPM(4200)]
        model.presets.update(custom)
        try render("editor-custom-curve", size: size) { PresetEditorView(preset: custom) }

        model.useFahrenheit = true
        try render("editor-fahrenheit", size: size) { PresetEditorView(preset: custom) }
        model.useFahrenheit = false

        let oneFan = model.snapshot.fans.filter { $0.id == 1 }
        try render("editor-fan-override-fixed", size: CGSize(width: 400, height: 220)) {
            Form { FanModeEditor(mode: .constant(.fixedRPM(4200)), editable: true, fans: oneFan, isOverride: true) }
                .formStyle(.grouped)
        }
        try render("editor-fan-override-auto", size: CGSize(width: 400, height: 220)) {
            Form { FanModeEditor(mode: .constant(.auto), editable: true, fans: oneFan, isOverride: true) }
                .formStyle(.grouped)
        }
    }
}
