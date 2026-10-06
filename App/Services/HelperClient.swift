import Foundation
import ServiceManagement
import os

enum HelperError: LocalizedError {
    case notInstalled, rejected(String), connection(Error)
    var errorDescription: String? {
        switch self {
        case .notInstalled: return "Install the helper to control fans."
        case .rejected(let message): return "Fan control failed: \(message)"
        case .connection(let error): return "Couldn't reach the fan helper: \(error.localizedDescription)"
        }
    }
}

@MainActor
@Observable
final class HelperClient {
    enum State: Equatable { case notInstalled, needsApproval, ready, error(String) }

    private(set) var state: State = .notInstalled

    /// Every heartbeat reply, and `.idle` if the connection is lost.
    @ObservationIgnored var onStatus: ((HelperStatus) -> Void)?
    /// The helper became usable, e.g. the user just approved it in System Settings.
    @ObservationIgnored var onReady: (() -> Void)?

    private let log = Logger(subsystem: FP.appBundleID, category: "helper")
    private let service = SMAppService.daemon(plistName: FP.helperPlist)
    @ObservationIgnored private var connection: NSXPCConnection?
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
        var outcome: Outcome<String?> = await call { $0.apply(presetJSON: data, reply: $1) }
        if case .failed = outcome {
            // The helper may have been on its way out; a second message makes launchd start it again.
            outcome = await call { $0.apply(presetJSON: data, reply: $1) }
        }
        switch outcome {
        case .reply(nil):
            startHeartbeat()
        case .reply(let message?):
            disconnect()
            throw HelperError.rejected(message)
        case .failed(let error):
            disconnect()
            throw HelperError.connection(error)
        }
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
