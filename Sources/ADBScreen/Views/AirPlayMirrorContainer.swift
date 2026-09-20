import AppKit
import SwiftUI

/// The AirPlay tile in the mirror grid. The session is owned by AppState
/// (not this view) so it keeps running while other tiles come and go.
///
/// No recording button here (unlike the Android tile) — AirPlay Mirroring
/// has no back-channel to request a keyframe on demand, which makes an
/// on-demand recording start structurally unreliable; see
/// AirPlayReceiverSession's doc comment for the full story.
struct AirPlayMirrorTile: View {
    @ObservedObject var session: AirPlayReceiverSession
    @ObservedObject var appState: AppState
    var onTitleBarDragChanged: ((CGPoint, CGSize) -> Void)?
    var onTitleBarDragEnded: (() -> Void)?
    @State private var mirrorView: AirPlayDisplayNSView?
    @State private var screenshotTrigger = 0
    /// See AndroidMirrorTile's `displayConnected` doc comment: same
    /// artificial minimum-visible-duration trick to prevent the
    /// "Verbinden…" overlay from flickering on fast connects.
    @State private var displayConnected = false

    var body: some View {
        MirrorTileFrame(
            title: appState.airplayDisplayName,
            isConnected: displayConnected,
            statusText: "Warte auf Bildschirmsynchronisierung…",
            instructionText: "Kontrollzentrum auf dem iPhone öffnen → Bildschirmsynchronisierung → „\(appState.airplayServiceName)“ auswählen.",
            errorText: session.lastError,
            footerNote: "Nur Anzeige – Steuerung ist über AirPlay nicht möglich.",
            onScreenshot: takeScreenshot,
            screenshotTrigger: screenshotTrigger,
            onTitleBarDragChanged: onTitleBarDragChanged,
            onTitleBarDragEnded: onTitleBarDragEnded,
            onDisconnect: { appState.disconnect(.airplay) }
        ) {
            AirPlayMirrorView(session: session) { mirrorView = $0 }
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
        let name = appState.airplayDisplayName
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
