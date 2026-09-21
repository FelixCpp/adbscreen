import AppKit
import SwiftUI

/// The iPhone-Spiegelung tile in the mirror grid. The session is owned by
/// AppState (not this view) so it keeps running while other tiles come and
/// go.
///
/// No recording button, same reasoning as the AirPlay tile: this only reads
/// pixels of Apple's own system window, so there's no back-channel to
/// request anything on demand.
struct IPhoneMirroringMirrorTile: View {
    @ObservedObject var session: IPhoneMirroringCaptureSession
    @ObservedObject var appState: AppState
    var isFocused: Bool = false
    var onToggleFocus: (() -> Void)? = nil
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
            title: "iPhone-Spiegelung",
            isConnected: displayConnected,
            statusText: "Warte auf „iPhone-Spiegelung“…",
            instructionText: "Systemeinstellungen → Allgemein → AirDrop & Handoff → „iPhone-Spiegelung“ einrichten (gleiche Apple-ID auf Mac und iPhone, Bluetooth/WLAN aktiv).",
            errorText: session.lastError,
            footerNote: "Nutzt Apples Continuity-Funktion, nicht AirPlay – Steuerung erfolgt direkt im Systemfenster, nicht über diese Kachel.",
            onScreenshot: takeScreenshot,
            screenshotTrigger: screenshotTrigger,
            isFocused: isFocused,
            onToggleFocus: onToggleFocus,
            onTitleBarDragChanged: onTitleBarDragChanged,
            onTitleBarDragEnded: onTitleBarDragEnded,
            onDisconnect: { appState.disconnect(.iphoneMirroring) }
        ) {
            IPhoneMirroringMirrorView(session: session) { mirrorView = $0 }
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
        Task {
            do {
                let image = try await WindowSnapshot.capture(of: mirrorView)
                screenshotTrigger += 1
                ScreenshotSaver.promptAndSave(image: image, suggestedName: ScreenshotSaver.filename(prefix: "iPhone-Spiegelung"))
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
