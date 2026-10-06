import Foundation

/// What the helper is doing with the fans, as reported in every heartbeat reply.
enum HelperStatus: Int {
    case idle = 0            // fans are on Auto because that was asked for
    case controlling = 1
    case watchdogReset = 2   // gave the fans back: the app stopped sending heartbeats
    case sensorFailure = 3   // gave the fans back: temperatures became unreadable
    case controlFailure = 4  // gave the fans back: macOS kept rejecting fan writes
    case emergency = 5       // still controlling, but a sensor is hot enough to force every fan to max
}

/// Presets travel as JSON `Data` to avoid `NSSecureCoding` boilerplate.
@objc protocol HelperProtocol {
    /// reply(nil) on success, reply(errorMessage) otherwise.
    func apply(presetJSON: Data, reply: @escaping (String?) -> Void)
    func resetToAuto(reply: @escaping () -> Void)
    /// Feeds the watchdog. Replies with a `HelperStatus` raw value.
    func heartbeat(reply: @escaping (Int) -> Void)
    /// `FP.version` of the running helper.
    func version(reply: @escaping (String) -> Void)
}
