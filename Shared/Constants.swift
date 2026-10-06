import Foundation

enum FP {
    static let appName       = "MacFanPilot"
    static let appBundleID   = "uz.stiv.macfanpilot"
    static let helperLabel   = "uz.stiv.macfanpilot.helper"
    static let helperPlist   = "uz.stiv.macfanpilot.helper.plist"
    static let teamID        = "6MD59J7ZW5"
    static let helperVersion = "1.0"

    static let appRequirement =
        #"anchor apple generic and identifier "\#(appBundleID)" and certificate leaf[subject.OU] = "\#(teamID)""#
    static let helperRequirement =
        #"anchor apple generic and identifier "\#(helperLabel)" and certificate leaf[subject.OU] = "\#(teamID)""#

    /// Exists while the helper holds the fans, so a relaunch after a crash knows to hand them back.
    /// /var/run is emptied at boot.
    static let helperActiveMarker = "/var/run/\(helperLabel).active"

    static let controlInterval: Double = 1.0      // seconds
    static let heartbeatInterval: Double = 5.0
    static let heartbeatTimeout: Double = 20.0
    static let helperIdleExit: Double = 10.0      // helper quits this long after its last client left
    static let unlockTimeout: Double = 10.0       // waiting for macOS to let go of the fans on apply
    static let retakeTimeout: Double = 2.0        // same, when macOS reclaims a fan mid-run

    static let emergencyTemp: Double = 100.0        // °C → force max
    static let emergencyReleaseTemp: Double = 95.0  // °C → back to the preset
    static let maxRampDownPerTick: Double = 150     // RPM
    static let tempSmoothing: Double = 0.3          // weight of the newest reading
    static let maxSensorFailures = 3                // consecutive ticks
    static let maxControlFailures = 3
}
