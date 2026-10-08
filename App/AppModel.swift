import SwiftUI
import Observation

enum MenuBarDisplay: String, CaseIterable, Identifiable {
    case iconOnly, temp, rpm, both
    var id: String { rawValue }

    var title: String {
        switch self {
        case .iconOnly: "Icon only"
        case .temp: "CPU temperature"
        case .rpm: "Fan speed"
        case .both: "Temperature + speed"
        }
    }

    /// 1.0 stored the menu title itself, so those are still recognised.
    init(stored: String?) {
        self = Self.allCases.first { $0.rawValue == stored || $0.title == stored } ?? .iconOnly
    }
}

/// What the fans are doing, as the menu bar icon shows it.
enum ControlState {
    case automatic     // macOS is in charge, which is what was asked for
    case controlling
    case emergency     // controlling, but a hot sensor forces every fan to maximum
    case stopped       // a preset is selected and could not be kept running

    var needsAttention: Bool { self == .emergency || self == .stopped }
}

struct HistorySample: Identifiable {
    let date: Date
    let cpu: Double?
    let gpu: Double?
    var id: Date { date }
}

@MainActor
@Observable
final class AppModel {
    /// The model of the running app. App Intents reach the app through it.
    static let shared = AppModel()

    /// Polling rate while no readout is on screen. Enough for the history chart.
    static let idleInterval: Double = 10
    static let historyWindow: TimeInterval = 5 * 60
    static let historySpacing: TimeInterval = 5

    let presets: PresetStore
    let helper: any FanHelper
    @ObservationIgnored private let power: any PowerSource
    @ObservationIgnored private let defaults: UserDefaults
    /// Seconds to wait before each further attempt at a preset that could not be applied.
    @ObservationIgnored private let retryDelays: [Double]
    @ObservationIgnored private let monitor = SensorMonitor()
    @ObservationIgnored private var started = false
    @ObservationIgnored private var monitoring = false
    @ObservationIgnored private var monitorInterval: Double?
    @ObservationIgnored private var activation = 0
    @ObservationIgnored private var retryAttempt = 0
    @ObservationIgnored private var foreignManualTicks = 0
    /// One notification per outage, however many retries fail.
    @ObservationIgnored private var stopNotified = false
    /// Replaced in tests.
    @ObservationIgnored var postNotification: (_ title: String, _ body: String) -> Void = {
        Notifier.shared.post(title: $0, body: $1)
    }

    var snapshot = SensorMonitor.Snapshot()
    private(set) var history: [HistorySample] = []
    var lastError: String?
    /// The helper is driving the fans for the active preset.
    private(set) var isControlling = false
    /// Preset currently being handed to the helper (macOS can take a few seconds to release the fans).
    private(set) var applyingID: UUID?
    /// Fans are in manual mode, but not because of us: another fan utility is running.
    private(set) var externalControl = false
    /// The helper is overriding the preset with maximum speed because a sensor is very hot.
    private(set) var emergency = false
    private(set) var onBattery = false
    let hasBattery: Bool

    // Readouts on screen. Polling slows down while there are none.
    @ObservationIgnored var popoverVisible = false { didSet { updateMonitorRate() } }
    @ObservationIgnored var settingsVisible = false { didSet { updateMonitorRate() } }

    // Settings (persisted)
    var useFahrenheit: Bool {
        didSet { defaults.set(useFahrenheit, forKey: "useFahrenheit") }
    }
    var display: MenuBarDisplay {
        didSet { defaults.set(display.rawValue, forKey: "display"); updateMonitorRate() }
    }
    var refreshInterval: Double {
        didSet { defaults.set(refreshInterval, forKey: "refresh"); updateMonitorRate() }
    }
    /// Leave the fans to macOS while on battery, whatever preset is selected.
    var autoOnBattery: Bool {
        didSet {
            defaults.set(autoOnBattery, forKey: "autoOnBattery")
            if started, autoOnBattery != oldValue { Task { await reapply() } }
        }
    }
    var notificationsEnabled: Bool {
        didSet { defaults.set(notificationsEnabled, forKey: "notifications") }
    }

    var cpuTemp: Double? { snapshot.groups[.cpuMax] ?? snapshot.groups[.hottest] }
    var gpuTemp: Double? { snapshot.groups[.gpuMax] }
    var maxFanRPM: Double? { snapshot.fans.map(\.rpm).max() }
    var hasFans: Bool { !snapshot.fans.isEmpty }

    /// The selected preset is set aside because the Mac is on battery.
    var pausedOnBattery: Bool { autoOnBattery && onBattery && !presets.active.isAllAuto }
    /// What should be running right now: the selected preset, unless a rule overrides it.
    private var wanted: Preset { pausedOnBattery ? .automatic : presets.active }

    var controlState: ControlState {
        if emergency { return .emergency }
        if isControlling { return .controlling }
        if lastError != nil, helper.state == .ready, !wanted.isAllAuto { return .stopped }
        return .automatic
    }

    convenience init() {
        self.init(presets: PresetStore(), helper: HelperClient(), power: SystemPowerSource())
    }

    init(presets: PresetStore, helper: any FanHelper, power: any PowerSource,
         defaults: UserDefaults = .standard, retryDelays: [Double] = [5, 20, 60]) {
        self.presets = presets
        self.helper = helper
        self.power = power
        self.defaults = defaults
        self.retryDelays = retryDelays
        hasBattery = power.hasBattery
        useFahrenheit = defaults.bool(forKey: "useFahrenheit")
        display = MenuBarDisplay(stored: defaults.string(forKey: "display"))
        refreshInterval = defaults.object(forKey: "refresh") as? Double ?? 2
        autoOnBattery = defaults.bool(forKey: "autoOnBattery")
        notificationsEnabled = defaults.object(forKey: "notifications") as? Bool ?? true
    }

    /// `monitoring` is off in tests, which feed snapshots in themselves.
    func start(monitoring: Bool = true) {
        guard !started else { return }
        started = true
        self.monitoring = monitoring
        updateMonitorRate()

        onBattery = power.onBattery
        power.onChange = { [weak self] in self?.powerChanged() }
        helper.onStatus = { [weak self] in self?.helperReported($0) }
        // Fires right away when the helper is already installed, which restores the last preset
        // at launch, and later if the user approves the helper in System Settings.
        helper.onReady = { [weak self] in Task { await self?.reapply() } }
        helper.refreshStatus()

        guard monitoring else { return }
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.monitor.refreshNow(fullPass: true)
                await self?.reapply()
            }
        }
    }

    // MARK: Sensors

    /// Full rate while a readout is visible, a slow one otherwise.
    private func updateMonitorRate() {
        guard monitoring else { return }
        let watched = popoverVisible || settingsVisible || display != .iconOnly
        let interval = watched ? refreshInterval : max(refreshInterval, Self.idleInterval)
        guard interval != monitorInterval else { return }
        monitorInterval = interval
        // Restarting the timer also publishes a snapshot at once, so a popover never opens stale.
        monitor.start(interval: interval) { [weak self] snap in self?.received(snap) }
    }

    func setRawSensors(_ on: Bool) { monitor.setIncludeRaw(on) }

    func received(_ snap: SensorMonitor.Snapshot, at date: Date = Date()) {
        snapshot = snap
        // Two snapshots in a row, so the moment after we let go of the fans doesn't count.
        let foreign = !isControlling && applyingID == nil && snap.fans.contains(where: \.manual)
        foreignManualTicks = foreign ? foreignManualTicks + 1 : 0
        externalControl = foreignManualTicks >= 2

        if let last = history.last, date.timeIntervalSince(last.date) < Self.historySpacing { return }
        history.append(HistorySample(date: date, cpu: cpuTemp, gpu: gpuTemp))
        history.removeAll { date.timeIntervalSince($0.date) > Self.historyWindow }
    }

    // MARK: Presets

    /// The user (or a shortcut) chose a preset. The choice is kept even if it can't be applied.
    func activate(_ preset: Preset) async {
        presets.activeID = preset.id
        await reapply()
    }

    /// Applies what should be running now, with a fresh set of retries.
    private func reapply() async {
        retryAttempt = 0
        stopNotified = false
        await apply()
    }

    private func apply() async {
        activation += 1
        let token = activation
        let preset = wanted
        guard helper.state == .ready else {
            isControlling = false
            emergency = false
            applyingID = nil
            lastError = nil   // the popover already offers to install the helper
            return
        }

        applyingID = preset.isAllAuto ? nil : preset.id
        var failure: String?
        do { try await helper.apply(preset) }
        catch { failure = error.localizedDescription }
        // A newer apply started while this one was in flight; its result is the one that counts.
        guard token == activation else { return }

        applyingID = nil
        foreignManualTicks = 0
        externalControl = false   // the next snapshots decide again
        emergency = false
        isControlling = failure == nil && !preset.isAllAuto
        lastError = failure
        if let failure {
            if !scheduleRetry() { notifyStopped("\(preset.name) is not running. \(failure)") }
        } else {
            retryAttempt = 0
            stopNotified = false
        }
        monitor.refreshNow()
    }

    /// false once the retries are used up. A newer apply of any kind cancels the pending one.
    @discardableResult
    private func scheduleRetry() -> Bool {
        guard retryAttempt < retryDelays.count else { return false }
        let delay = retryDelays[retryAttempt]
        retryAttempt += 1
        let token = activation
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, token == self.activation else { return }
            await self.apply()
        }
        return true
    }

    func uninstallHelper() async {
        await activate(.automatic)
        await helper.uninstall()
    }

    func prepareForQuit() async {
        presets.flush()
        await helper.resetToAuto()
    }

    private func helperReported(_ status: HelperStatus) {
        guard isControlling else { return }
        switch status {
        case .controlling:
            emergency = false
        case .emergency:
            guard !emergency else { return }
            emergency = true
            notify("Fans at maximum",
                   "A sensor reached \(format(temp: FP.emergencyTemp)), so every fan runs at full speed until it cools down.")
        case .idle, .watchdogReset:
            // The helper restarted, or we stalled long enough (sleep, a hang) for its watchdog to fire.
            Task { await apply() }
        case .sensorFailure:
            helperGaveUp("Temperature sensors stopped responding, so the fans are back on Automatic.")
        case .controlFailure:
            helperGaveUp("macOS stopped accepting fan commands, so the fans are back on Automatic.")
        }
    }

    /// The helper handed the fans back on its own. The preset stays selected and is tried again.
    private func helperGaveUp(_ message: String) {
        activation += 1   // nothing still in flight may overwrite this
        isControlling = false
        emergency = false
        applyingID = nil
        lastError = message
        notifyStopped(message)
        let token = activation
        Task {
            try? await helper.apply(.automatic)   // let go of the connection and its heartbeat
            if token == activation { scheduleRetry() }
        }
    }

    private func notifyStopped(_ message: String) {
        guard !stopNotified else { return }
        stopNotified = true
        notify("Fan control stopped", message)
    }

    private func notify(_ title: String, _ body: String) {
        if notificationsEnabled { postNotification(title, body) }
    }

    // MARK: Rules

    private func powerChanged() {
        let now = power.onBattery
        guard now != onBattery else { return }
        onBattery = now
        if autoOnBattery { Task { await reapply() } }
    }

    /// A Focus with a fan preset came on (`id` set) or went off (nil). Going off restores what was
    /// selected before, unless the user has picked something else in the meantime.
    func focusChanged(to id: UUID?) async {
        let returnKey = "focusReturnPresetID", focusKey = "focusPresetID"
        if let id {
            guard let preset = presets.presets.first(where: { $0.id == id }) else { return }
            if defaults.string(forKey: returnKey) == nil {
                defaults.set(presets.activeID.uuidString, forKey: returnKey)
            }
            defaults.set(id.uuidString, forKey: focusKey)
            await activate(preset)
        } else {
            let before = defaults.string(forKey: returnKey).flatMap(UUID.init)
            let during = defaults.string(forKey: focusKey).flatMap(UUID.init)
            defaults.removeObject(forKey: returnKey)
            defaults.removeObject(forKey: focusKey)
            guard let before, presets.activeID == during else { return }
            await activate(presets.presets.first { $0.id == before } ?? .automatic)
        }
    }

    // MARK: Diagnostics

    /// Plain text for a bug report: versions, the Mac, the helper, the preset, fans and sensors.
    func diagnostics() async -> String {
        func sysctl(_ name: String) -> String {
            var size = 0
            guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "?" }
            var buffer = [CChar](repeating: 0, count: size)
            guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return "?" }
            return String(cString: buffer)
        }
        let helperText: String
        switch helper.state {
        case .ready: helperText = "installed"
        case .needsApproval: helperText = "waiting for approval"
        case .notInstalled: helperText = "not installed"
        case .error(let message): helperText = "error: \(message)"
        }
        var lines = [
            "\(FP.appName) \(FP.version)",
            "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "Mac: \(sysctl("hw.model")), \(sysctl("machdep.cpu.brand_string"))",
            "Power: \(hasBattery ? (onBattery ? "battery" : "AC, has battery") : "AC, no battery")",
            "Helper: \(helperText)",
            "Preset: \(presets.active.name) (\(presets.active.summary))",
            "State: \(controlState)\(pausedOnBattery ? ", paused on battery" : "")\(externalControl ? ", fans held by another app" : "")",
        ]
        if let lastError { lines.append("Last error: \(lastError)") }
        lines += await withCheckedContinuation { done in monitor.report { done.resume(returning: $0) } }
        return lines.joined(separator: "\n")
    }

    // MARK: Formatting

    func format(temp: Double?) -> String { Temperature.string(temp, fahrenheit: useFahrenheit) }
    func format(rpm: Double?) -> String { rpm.map { "\(Int($0.rounded()))" } ?? "–" }

    func fanName(_ i: Int) -> String {
        snapshot.fans.count == 2 ? (i == 0 ? "Left" : "Right") : "Fan \(i + 1)"
    }
}

private extension FanMode {
    var summary: String {
        switch self {
        case .auto: "automatic"
        case .fixedPercent(let p): "fixed \(Int((p * 100).rounded()))%"
        case .fixedRPM(let r): "fixed \(Int(r.rounded())) rpm"
        case .curve(let c): "curve on \(c.sensor.rawValue), \(c.points.count) points"
        }
    }
}

private extension Preset {
    var summary: String {
        let overrides = perFan.keys.sorted().map { "fan \($0 + 1): \(perFan[$0]?.summary ?? "")" }
        return ([mode.summary] + overrides).joined(separator: "; ")
    }
}
