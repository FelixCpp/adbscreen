import AppKit

/// Ensures every live scrcpy session (spawned adb shell process + adb
/// forward tunnel) is torn down on quit, even if SwiftUI's onDisappear
/// doesn't get a chance to run before the process exits.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Let macOS choose Aqua or Dark automatically from the user's
        // current system appearance.
        NSApp.appearance = nil
    }

    func applicationWillTerminate(_ notification: Notification) {
        ScrcpySession.stopAll()
    }
}
