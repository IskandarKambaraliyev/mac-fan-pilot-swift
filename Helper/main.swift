import Foundation
import os

let log = Logger(subsystem: FP.helperLabel, category: "main")

guard getuid() == 0 else { log.fault("helper must run as root"); exit(EXIT_FAILURE) }
// Without these the code-signing check below would be meaningless. Exit cleanly: launchd restarts
// this job after a failed exit, and retrying can't help here.
guard !FP.helperLabel.isEmpty, !FP.appBundleID.isEmpty, !FP.teamID.isEmpty else {
    log.fault("identifiers missing from Info.plist")
    exit(EXIT_SUCCESS)
}

let controller: FanController
do { controller = FanController(smc: try SMC()) }
catch {
    log.fault("SMC unavailable: \(String(describing: error), privacy: .public)")   // same: no point retrying
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
    // A failed exit makes launchd start the helper again, which finds the marker and keeps trying.
    exit(controller.resetToAuto() ? EXIT_SUCCESS : EXIT_FAILURE)
}
sigterm.resume()

log.info("helper started")
service.scheduleIdleExit()   // launchd also runs us at load; leave unless the app shows up
dispatchMain()
