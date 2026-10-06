import SwiftUI
import Observation

enum MenuBarDisplay: String, CaseIterable, Identifiable {
    case iconOnly = "Icon only", temp = "CPU temperature", rpm = "Fan speed", both = "Temperature + speed"
    var id: String { rawValue }
}

@MainActor
@Observable
final class AppModel {
    let presets = PresetStore()
    let helper = HelperClient()
    @ObservationIgnored private let monitor = SensorMonitor()
    @ObservationIgnored private var started = false
    @ObservationIgnored private var activation = 0
    @ObservationIgnored private var foreignManualTicks = 0

    var snapshot = SensorMonitor.Snapshot()
    var lastError: String?
    /// The helper is driving the fans for the active preset.
    private(set) var isControlling = false
    /// Preset currently being handed to the helper (macOS can take a few seconds to release the fans).
    private(set) var applyingID: UUID?
    /// Fans are in manual mode, but not because of us: another fan utility is running.
    private(set) var externalControl = false

    // Settings (persisted)
    var useFahrenheit = UserDefaults.standard.bool(forKey: "useFahrenheit") {
        didSet { UserDefaults.standard.set(useFahrenheit, forKey: "useFahrenheit") }
    }
    var display = MenuBarDisplay(rawValue: UserDefaults.standard.string(forKey: "display") ?? "") ?? .iconOnly {
        didSet { UserDefaults.standard.set(display.rawValue, forKey: "display") }
    }
    var refreshInterval = UserDefaults.standard.object(forKey: "refresh") as? Double ?? 2 {
        didSet { UserDefaults.standard.set(refreshInterval, forKey: "refresh"); startMonitor() }
    }

    var cpuTemp: Double? { snapshot.groups[.cpuMax] ?? snapshot.groups[.hottest] }
    var gpuTemp: Double? { snapshot.groups[.gpuMax] }
    var maxFanRPM: Double? { snapshot.fans.map(\.rpm).max() }
    var hasFans: Bool { !snapshot.fans.isEmpty }

    func start() {
        guard !started else { return }
        started = true
        startMonitor()

        helper.onStatus = { [weak self] in self?.helperReported($0) }
        // Fires right away when the helper is already installed, which restores the last preset
        // at launch, and later if the user approves the helper in System Settings.
        helper.onReady = { [weak self] in Task { await self?.reapply() } }
        helper.refreshStatus()

        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.monitor.refreshNow(fullPass: true)
                await self?.reapply()
            }
        }
    }

    func startMonitor() {
        monitor.start(interval: refreshInterval) { [weak self] snap in self?.received(snap) }
    }

    func setRawSensors(_ on: Bool) { monitor.setIncludeRaw(on) }

    private func received(_ snap: SensorMonitor.Snapshot) {
        snapshot = snap
        // Two snapshots in a row, so the moment after we let go of the fans doesn't count.
        let foreign = !isControlling && applyingID == nil && snap.fans.contains(where: \.manual)
        foreignManualTicks = foreign ? foreignManualTicks + 1 : 0
        externalControl = foreignManualTicks >= 2
    }

    // MARK: Presets

    func activate(_ preset: Preset) async {
        activation += 1
        let token = activation
        presets.activeID = preset.id
        guard helper.state == .ready else {
            isControlling = false
            lastError = nil   // the popover already offers to install the helper
            return
        }

        applyingID = preset.isAllAuto ? nil : preset.id
        var failure: String?
        do { try await helper.apply(preset) }
        catch { failure = error.localizedDescription }
        // A newer activation started while this one was in flight; its result is the one that counts.
        guard token == activation else { return }

        applyingID = nil
        foreignManualTicks = 0
        isControlling = failure == nil && !preset.isAllAuto
        lastError = failure
        if failure != nil { presets.activeID = Preset.automatic.id }
        monitor.refreshNow()
    }

    private func reapply() async { await activate(presets.active) }

    func uninstallHelper() async {
        await activate(.automatic)
        await helper.uninstall()
    }

    func prepareForQuit() async { await helper.resetToAuto() }

    private func helperReported(_ status: HelperStatus) {
        guard isControlling else { return }
        switch status {
        case .controlling:
            break
        case .idle, .watchdogReset:
            // The helper restarted, or we stalled long enough (sleep, a hang) for its watchdog to fire.
            Task { await reapply() }
        case .sensorFailure:
            fallBack("Temperature sensors stopped responding, so the fans are back on Automatic.")
        case .controlFailure:
            fallBack("macOS stopped accepting fan commands, so the fans are back on Automatic.")
        }
    }

    private func fallBack(_ message: String) {
        Task {
            await activate(.automatic)
            lastError = message
        }
    }

    // MARK: Formatting

    func format(temp: Double?) -> String {
        guard let t = temp else { return "–" }
        return useFahrenheit ? "\(Int((t * 9 / 5 + 32).rounded()))°F" : "\(Int(t.rounded()))°"
    }
    func format(rpm: Double?) -> String { rpm.map { "\(Int($0.rounded()))" } ?? "–" }
}
