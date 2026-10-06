import Foundation
import os

final class HelperService: NSObject, HelperProtocol, NSXPCListenerDelegate {
    private static let maxPresetBytes = 64 * 1024

    private let log = Logger(subsystem: FP.helperLabel, category: "xpc")
    private let controller: FanController
    // Touched on the main queue only.
    private var clients = 0
    private var idleExit: DispatchWorkItem?

    init(controller: FanController) { self.controller = controller }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection c: NSXPCConnection) -> Bool {
        c.exportedInterface = NSXPCInterface(with: HelperProtocol.self)
        c.exportedObject = self
        c.invalidationHandler = { [weak self] in
            DispatchQueue.main.async { self?.clientLeft() }
        }
        DispatchQueue.main.async { self.clientArrived() }
        c.resume()
        return true
    }

    private func clientArrived() {
        clients += 1
        idleExit?.cancel()
        idleExit = nil
    }

    private func clientLeft() {
        clients -= 1
        guard clients <= 0 else { return }
        log.info("app disconnected → auto")
        controller.resetToAuto()
        scheduleIdleExit()
    }

    /// The helper has nothing to do without a client, so it doesn't linger as a root process.
    /// launchd starts it again the next time the app connects.
    func scheduleIdleExit() {
        idleExit?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.clients <= 0 else { return }
            self.controller.resetToAuto()
            exit(EXIT_SUCCESS)
        }
        idleExit = work
        DispatchQueue.main.asyncAfter(deadline: .now() + FP.helperIdleExit, execute: work)
    }

    // MARK: HelperProtocol

    func apply(presetJSON: Data, reply: @escaping (String?) -> Void) {
        guard presetJSON.count <= Self.maxPresetBytes else { reply("Preset is too large."); return }
        do {
            let preset = try JSONDecoder().decode(Preset.self, from: presetJSON)
            try controller.apply(preset)
            reply(nil)
        } catch {
            reply(String(describing: error))
        }
    }

    func resetToAuto(reply: @escaping () -> Void) { controller.resetToAuto(); reply() }
    func heartbeat(reply: @escaping (Int) -> Void) { controller.heartbeat { reply($0.rawValue) } }
    func version(reply: @escaping (String) -> Void) { reply(FP.helperVersion) }
}
