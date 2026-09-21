import AppKit
import SwiftUI

/// First-run (and re-openable) setup checklist covering everything ADBScreen
/// needs to actually work: the adb binary, and the two macOS permissions
/// (Bildschirmaufnahme for screenshots/recordings, Kamera for USB-Capture-
/// Adapter). There's no Android device step — mirroring an actual device is
/// optional (the demo devices work without one), so its presence isn't a
/// setup criterion. Steps that can be checked live update automatically.
struct OnboardingView: View {
    @ObservedObject var appState: AppState
    @StateObject private var screenCapture = ScreenCapturePermission()
    @StateObject private var camera = CameraPermission()
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    OnboardingStep(
                        done: appState.adbAvailable,
                        title: "adb verfügbar",
                        detail: "Nur nötig, wenn du ein Android-Gerät spiegeln willst — ADBScreen sucht adb (Android Debug Bridge) automatisch, z. B. aus Homebrew, dem Android SDK (Android Studio) oder deinem PATH."
                    ) {
                        Button("Erneut prüfen") { appState.refreshNow() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }

                    OnboardingStep(
                        done: screenCapture.isGranted,
                        title: "Bildschirmaufnahme erlauben",
                        detail: "Für Screenshots und Aufnahmen eines gespiegelten Fensters benötigt ADBScreen die Berechtigung „Bildschirmaufnahme“."
                    ) {
                        HStack {
                            Button("Erlauben") { screenCapture.request() }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            Button("Systemeinstellungen öffnen") {
                                openSettings(pane: "Privacy_ScreenCapture")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }

                    OnboardingStep(
                        done: camera.isGranted,
                        title: "Kamera erlauben",
                        detail: "Nur nötig, wenn du ein iPhone/iPad per USB-Kabel spiegeln willst — ein verbundenes Gerät meldet sich dafür wie eine Kamera, genau wie bei QuickTime Players „Neue Filmaufnahme“."
                    ) {
                        HStack {
                            Button("Erlauben") { camera.request() }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            Button("Systemeinstellungen öffnen") {
                                openSettings(pane: "Privacy_Camera")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }
                .padding(20)
            }

            footer
        }
        .frame(width: 460, height: 460)
        .onAppear { screenCapture.refresh() }
        .onAppear { camera.refresh() }
        .onDisappear { appState.showOnboarding = false }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            screenCapture.refresh()
            camera.refresh()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Einrichtung")
                .font(.title2.bold())
            Text("Diese Schritte sorgen dafür, dass ADBScreen Bildschirme spiegeln kann.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(20)
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Schließen") {
                // Close this window directly rather than relying solely on
                // ContentView's `showOnboarding` observer to do it — that
                // round trip through a different window's environment is
                // one more thing that can fail to fire; this way the button
                // always closes its own window no matter what.
                dismissWindow()
                appState.showOnboarding = false
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }

    private func openSettings(pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }
}

private struct OnboardingStep<Content: View>: View {
    let done: Bool
    let title: String
    let detail: String
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 18))
                .foregroundStyle(done ? .green : .secondary)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                content
                    .padding(.top, 2)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
    }
}
