import Foundation
import ServiceManagement
import os

enum HelperError: LocalizedError {
    case notInstalled, rejected(String), connection(Error), mismatch
    var errorDescription: String? {
        switch self {
        case .notInstalled: return "Install the helper to control fans."
        case .rejected(let message): return "Fan control failed: \(message)"
        case .connection(let error): return "Couldn't reach the fan helper: \(error.localizedDescription)"
        case .mismatch: return "The fan helper is from a different version of \(FP.appName). Uninstall it in Settings, then install it again."
        }
    }

    /// The helper itself is unreachable or wrong, as opposed to refusing one request.
    var isRepairable: Bool {
        switch self {
        case .connection, .mismatch: return true
        case .notInstalled, .rejected: return false
        }
    }
}

enum HelperState: Equatable { case notInstalled, needsApproval, ready, error(String) }

/// What the app needs from the privileged helper. `HelperClient` is the real one; the tests use
/// a fake.
@MainActor
protocol FanHelper: AnyObject {
    var state: HelperState { get }
    /// Every heartbeat reply, and `.idle` if the connection is lost.
    var onStatus: ((HelperStatus) -> Void)? { get set }
    /// The helper became usable, e.g. the user just approved it in System Settings.
    var onReady: (() -> Void)? { get set }

    func refreshStatus()
    func install()
    func openApprovalSettings()
    func uninstall() async
    func apply(_ preset: Preset) async throws
    func resetToAuto() async
}

@MainActor
@Observable
final class HelperClient: FanHelper {
    private(set) var state: HelperState = .notInstalled

    @ObservationIgnored var onStatus: ((HelperStatus) -> Void)?
    @ObservationIgnored var onReady: (() -> Void)?

    private let log = Logger(subsystem: FP.appBundleID, category: "helper")
    private let service = SMAppService.daemon(plistName: FP.helperPlist)
    @ObservationIgnored private var connection: NSXPCConnection?
    /// The connection whose helper has answered with our own version.
    @ObservationIgnored private weak var verified: NSXPCConnection?
    @ObservationIgnored private var repaired = false
    @ObservationIgnored private var heartbeatTimer: Timer?
    @ObservationIgnored private var approvalTimer: Timer?
    @ObservationIgnored private var activity: NSObjectProtocol?

    // MARK: Install / status

    func refreshStatus() {
        let was = state
        switch service.status {
        case .enabled:
            state = .ready
        case .requiresApproval:
            state = .needsApproval
        case .notFound:
            state = .error("The helper is missing from the app bundle.")
        default:
            if case .error = state { break }   // keep showing why the last install failed
            state = .notInstalled
        }
        pollForApproval(state == .needsApproval)
        if state == .ready, was != .ready { onReady?() }
    }

    func install() {
        if let problem = Self.locationProblem {
            state = .error(problem)
            return
        }
        state = .notInstalled
        var failure: String?
        do {
            try service.register()
        } catch {
            failure = error.localizedDescription
            log.error("register failed: \(error.localizedDescription, privacy: .public)")
        }
        refreshStatus()
        if state == .needsApproval {
            SMAppService.openSystemSettingsLoginItems()
        } else if state != .ready {
            state = .error("Couldn't install the helper. \(failure ?? "")")
        }
    }

    func openApprovalSettings() { SMAppService.openSystemSettingsLoginItems() }

    func uninstall() async {
        await resetToAuto()
        disconnect()
        do {
            try await service.unregister()
        } catch {
            log.error("unregister failed: \(error.localizedDescription, privacy: .public)")
        }
        state = .notInstalled
        refreshStatus()
    }

    /// The daemon is registered against the app's path, so it must not be a throwaway one.
    private static var locationProblem: String? {
        let path = Bundle.main.bundlePath
        guard path.contains("/AppTranslocation/") || path.hasPrefix("/Volumes/") else { return nil }
        return "Move \(FP.appName) to the Applications folder and open it from there."
    }

    /// A build run from Xcode's build folder must not re-point the daemon at itself.
    private static var isInApplications: Bool {
        let path = Bundle.main.bundlePath
        return path.hasPrefix("/Applications/") || path.hasPrefix(NSHomeDirectory() + "/Applications/")
    }

    private func pollForApproval(_ on: Bool) {
        guard on != (approvalTimer != nil) else { return }
        approvalTimer?.invalidate()
        approvalTimer = on ? Self.repeating(every: 2) { [weak self] in self?.refreshStatus() } : nil
    }

    // MARK: Commands

    func apply(_ preset: Preset) async throws {
        guard state == .ready else { throw HelperError.notInstalled }
        if preset.isAllAuto {
            // Nothing is held without a connection, and the helper quits once we let go of it.
            await resetToAuto()
            disconnect()
            return
        }
        let data = try JSONEncoder().encode(preset)
        do {
            try await send(data)
        } catch let error as HelperError {
            guard error.isRepairable, await repair() else { throw error }
            try await send(data)
        }
        startHeartbeat()
    }

    private func send(_ presetJSON: Data) async throws {
        do {
            try await checkVersion()
            let rejection: String? = try await request { $0.apply(presetJSON: presetJSON, reply: $1) }
            if let rejection { throw HelperError.rejected(rejection) }
        } catch {
            disconnect()
            throw error
        }
    }

    /// Once per connection: make sure the helper that answers is the one in this app bundle.
    private func checkVersion() async throws {
        guard verified == nil || verified !== connection else { return }
        let version: String = try await request { $0.version(reply: $1) }
        guard version == FP.version else {
            log.error("helper is \(version, privacy: .public), app is \(FP.version, privacy: .public)")
            throw HelperError.mismatch
        }
        verified = connection
    }

    /// Registers the daemon again, once per launch. Moving or replacing the app can leave launchd
    /// unable to start the helper, or starting the copy from the previous build.
    private func repair() async -> Bool {
        guard !repaired, Self.isInApplications else { return false }
        repaired = true
        log.notice("helper unreachable or outdated; registering it again")
        disconnect()
        try? await service.unregister()
        do {
            try service.register()
        } catch {
            log.error("register failed: \(error.localizedDescription, privacy: .public)")
        }
        refreshStatus()
        return state == .ready
    }

    func resetToAuto() async {
        guard connection != nil else { return }
        let _: Outcome<Void> = await call { proxy, done in proxy.resetToAuto { done(()) } }
    }

    // MARK: XPC

    private enum Outcome<T> { case reply(T), failed(Error) }

    private func connect() -> NSXPCConnection {
        if let connection { return connection }
        let c = NSXPCConnection(machServiceName: FP.helperLabel, options: .privileged)
        c.remoteObjectInterface = NSXPCInterface(with: HelperProtocol.self)
        c.setCodeSigningRequirement(FP.helperRequirement)   // only talk to our helper
        c.invalidationHandler = { [weak self, weak c] in
            Task { @MainActor in
                guard let self, let c, self.connection === c else { return }
                self.log.error("helper connection invalidated")
                self.disconnect()
                self.onStatus?(.idle)
            }
        }
        c.resume()
        connection = c
        return c
    }

    private func disconnect() {
        let c = connection
        connection = nil
        c?.invalidate()
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
    }

    /// A call that throws when the helper can't be reached. The helper may have been on its way
    /// out; a second message makes launchd start it again.
    private func request<T>(_ body: (HelperProtocol, @escaping (T) -> Void) -> Void) async throws -> T {
        var outcome: Outcome<T> = await call(body)
        if case .failed = outcome { outcome = await call(body) }
        switch outcome {
        case .reply(let value): return value
        case .failed(let error): throw HelperError.connection(error)
        }
    }

    /// XPC calls exactly one of the reply block and the error handler, so this always returns.
    private func call<T>(_ body: (HelperProtocol, @escaping (T) -> Void) -> Void) async -> Outcome<T> {
        let c = connect()
        return await withCheckedContinuation { (cont: CheckedContinuation<Outcome<T>, Never>) in
            let proxy = c.remoteObjectProxyWithErrorHandler { cont.resume(returning: .failed($0)) }
            guard let helper = proxy as? HelperProtocol else {
                cont.resume(returning: .failed(CocoaError(.xpcConnectionInvalid)))
                return
            }
            body(helper) { cont.resume(returning: .reply($0)) }
        }
    }

    // MARK: Heartbeat

    private func startHeartbeat() {
        guard heartbeatTimer == nil else { return }
        // A napping app delays its timers; that must not look like a dead app to the watchdog.
        activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep,
                                                         reason: "Controlling fans")
        heartbeatTimer = Self.repeating(every: FP.heartbeatInterval) { [weak self] in
            Task { await self?.beat() }
        }
    }

    private func beat() async {
        guard connection != nil else { return }
        let outcome: Outcome<Int> = await call { $0.heartbeat(reply: $1) }
        if case .reply(let raw) = outcome { onStatus?(HelperStatus(rawValue: raw) ?? .idle) }
    }

    /// Scheduled in the common modes so it keeps firing while a menu or a slider is being tracked.
    private static func repeating(every interval: TimeInterval, _ fire: @escaping @MainActor () -> Void) -> Timer {
        let timer = Timer(timeInterval: interval, repeats: true) { _ in
            MainActor.assumeIsolated { fire() }
        }
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }
}
