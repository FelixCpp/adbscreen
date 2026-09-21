import AppKit
import SwiftUI

/// The USB-mirroring tile in the mirror grid. The session is owned by
/// AppState (not this view), same pattern as AirPlayMirrorTile.
///
/// No recording button here either — for the same structural reason as
/// AirPlay: no back-channel to request a fresh keyframe on demand.
struct USBMirrorTile: View {
    @ObservedObject var session: USBMirrorReceiverSession
    @ObservedObject var appState: AppState
    var isFocused: Bool = false
    var onToggleFocus: (() -> Void)? = nil
    var onTitleBarDragChanged: ((CGPoint, CGSize) -> Void)?
    var onTitleBarDragEnded: (() -> Void)?
    @State private var mirrorView: USBMirrorDisplayNSView?
    @State private var screenshotTrigger = 0
    @State private var displayConnected = false

    var body: some View {
        MirrorTileFrame(
            title: appState.usbMirrorDisplayName,
            isConnected: displayConnected,
            statusText: "Warte auf iPhone/iPad per USB…",
            instructionText: "iPhone/iPad per Kabel anschließen und „Diesem Computer vertrauen“ bestätigen.",
            errorText: session.lastError,
            footerNote: "Nur Anzeige – Steuerung ist über USB-Mirroring nicht möglich. Hinweis: Direkte USB-Bildschirmspiegelung ist auf aktuellen macOS-Versionen oft blockiert (macOS/usbmuxd-Einschränkung, kein Bug dieser App); notfalls Lightning/USB-C-zu-HDMI-Adapter + HDMI-Capture-Dongle nutzen.",
            onScreenshot: takeScreenshot,
            screenshotTrigger: screenshotTrigger,
            isFocused: isFocused,
            onToggleFocus: onToggleFocus,
            onTitleBarDragChanged: onTitleBarDragChanged,
            onTitleBarDragEnded: onTitleBarDragEnded,
            onDisconnect: { appState.disconnect(.usbMirror) }
        ) {
            USBMirrorView(session: session) { mirrorView = $0 }
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
        let name = appState.usbMirrorDisplayName
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
