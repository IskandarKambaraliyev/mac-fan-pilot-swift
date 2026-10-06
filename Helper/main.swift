import Foundation
import os

let log = Logger(subsystem: FP.helperLabel, category: "main")

guard getuid() == 0 else { log.fault("helper must run as root"); exit(EXIT_FAILURE) }

let controller: FanController
do { controller = try FanController() }
catch {
    // Exit cleanly: launchd restarts this job after a failed exit, and retrying can't help here.
    log.fault("SMC unavailable: \(String(describing: error), privacy: .public)")
    exit(EXIT_SUCCESS)
}

let service = HelperService(controller: controller)
let listener = NSXPCListener(machServiceName: FP.helperLabel)
listener.setConnectionCodeSigningRequirement(FP.appRequirement)   // only our app may connect
listener.delegate = service
listener.resume()

// Restore Auto on shutdown / launchctl stop / unregister.
signal(SIGTERM, SIG_IGN)
let sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
sigterm.setEventHandler {
    controller.resetToAuto()
    exit(EXIT_SUCCESS)
}
sigterm.resume()

log.info("helper started")
service.scheduleIdleExit()   // launchd also runs us at load; leave unless the app shows up
dispatchMain()
