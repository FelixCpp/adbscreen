import AppKit
import SwiftUI

/// The USB-iOS tile in the mirror grid. The session is owned by AppState
/// (not this view) so it keeps running while other tiles come and go.
///
/// No recording button here (unlike the Android tile) — same reasoning as
/// the AirPlay tile doesn't get one, just for a different underlying
/// reason: recording would need to re-encode `AVCaptureVideoPreviewLayer`
/// output ourselves, which isn't worth it for what's meant to be a simple
/// AirPlay-restriction workaround. Screenshots reuse the same
/// ScreenCaptureKit-based window snapshot as every other tile type.
struct USBiOSMirrorTile: View {
    @ObservedObject var session: USBiOSCaptureSession
    @ObservedObject var appState: AppState
    var isFocused: Bool = false
    var onToggleFocus: (() -> Void)? = nil
    var onTitleBarDragChanged: ((CGPoint, CGSize) -> Void)?
    var onTitleBarDragEnded: (() -> Void)?
    @State private var mirrorView: USBiOSDisplayNSView?
    @State private var screenshotTrigger = 0
    /// See AndroidMirrorTile's `displayConnected` doc comment: same
    /// artificial minimum-visible-duration trick to prevent the
    /// "Verbinden…" overlay from flickering on fast connects.
    @State private var displayConnected = false

    var body: some View {
        MirrorTileFrame(
            title: session.displayName,
            isConnected: displayConnected,
            statusText: "Verbinde mit \(session.displayName)…",
            instructionText: "iPhone/iPad per USB-Kabel anschließen und \u{201E}Diesem Computer vertrauen\u{201C} bestätigen.",
            errorText: session.lastError,
            footerNote: "Nur Anzeige – Steuerung ist über USB-Spiegelung nicht möglich.",
            onScreenshot: takeScreenshot,
            screenshotTrigger: screenshotTrigger,
            isFocused: isFocused,
            onToggleFocus: onToggleFocus,
            onTitleBarDragChanged: onTitleBarDragChanged,
            onTitleBarDragEnded: onTitleBarDragEnded,
            onDisconnect: { appState.disconnect(.usbIOS(session.uniqueID)) }
        ) {
            USBiOSMirrorView(session: session) { mirrorView = $0 }
        }
        .task(id: session.isConnected) {
            guard session.isConnected else {
                displayConnected = false
                return
            }
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !Task.isCancelled else { return }
            displayConnected = true
        }
    }

    private func takeScreenshot() {
        guard let mirrorView else {
            presentError(title: "Screenshot fehlgeschlagen", "Die Video-Ansicht ist noch nicht bereit.")
            return
        }
        let name = session.displayName
        Task {
            do {
                let image = try await WindowSnapshot.capture(of: mirrorView)
                screenshotTrigger += 1
                ScreenshotSaver.promptAndSave(image: image, suggestedName: ScreenshotSaver.filename(prefix: name))
            } catch {
                presentError(title: "Screenshot fehlgeschlagen", error.localizedDescription)
            }
        }
    }

    private func presentError(title: String, _ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}
