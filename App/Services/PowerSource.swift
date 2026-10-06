import Foundation
import IOKit.ps

/// Whether the Mac is running on its battery. `SystemPowerSource` is the real one; the tests use
/// a fake.
@MainActor
protocol PowerSource: AnyObject {
    var hasBattery: Bool { get }
    var onBattery: Bool { get }
    /// Called on the main thread when the power source may have changed.
    var onChange: (() -> Void)? { get set }
}

@MainActor
final class SystemPowerSource: PowerSource {
    var onChange: (() -> Void)?

    init() {
        // The model that owns this lives as long as the app, so the unretained pointer stays valid.
        let context = Unmanaged.passUnretained(self).toOpaque()
        let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let me = Unmanaged<SystemPowerSource>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { me.onChange?() }   // delivered on the main run loop, below
        }, context)?.takeRetainedValue()
        if let source { CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes) }
    }

    var hasBattery: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return false }
        return sources.contains { source in
            let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any]
            return description?[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
        }
    }

    var onBattery: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return false }
        return IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String? == kIOPMBatteryPowerKey
    }
}
