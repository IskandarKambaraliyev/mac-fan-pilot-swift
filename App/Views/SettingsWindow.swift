import SwiftUI

/// The settings window, managed by hand. SwiftUI's `Settings` scene and `SettingsLink` don't open
/// reliably from a menu bar popover in an app without a Dock icon.
@MainActor
enum SettingsWindow {
    private static var window: NSWindow?
    private static var closeObserver: NSObjectProtocol?

    static func show(model: AppModel) {
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView().environment(model)))
            w.title = "\(FP.appName) Settings"
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.isReleasedWhenClosed = false
            w.center()
            // Drop the window once it has closed so its views stop observing the sensors.
            closeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak model] _ in
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            model?.setRawSensors(false)   // in case the Sensors tab was showing
                            window = nil
                            if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
                            closeObserver = nil
                        }
                    }
                }
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
