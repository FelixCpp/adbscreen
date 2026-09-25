import SwiftUI

@main
struct ADBScreenApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView(appState: appState)
        }
        .defaultSize(width: 1100, height: 700)
        .windowResizability(.contentSize)

        // A plain window rather than a `.sheet` on the main window: macOS
        // shows its own "Quit & Reopen" alert after granting a permission
        // (e.g. Screen Recording) from System Settings, which requires
        // closing our main window as part of relaunching — and AppKit
        // refuses to close a window that still has a sheet attached to it,
        // which used to hang that flow entirely.
        Window("Einrichtung", id: "onboarding") {
            OnboardingView(appState: appState)
        }
        .windowResizability(.contentSize)
    }
}
