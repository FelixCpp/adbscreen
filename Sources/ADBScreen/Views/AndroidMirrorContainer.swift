import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// One Android tile in the mirror grid. The session is owned by AppState
/// (not this view) so it keeps running while other tiles come and go.
struct AndroidMirrorTile: View {
    let serial: String
    @ObservedObject var session: ScrcpySession
    @ObservedObject var appState: AppState
    var isFocused: Bool = false
    var onToggleFocus: (() -> Void)? = nil
    var onTitleBarDragChanged: ((CGPoint, CGSize) -> Void)?
    var onTitleBarDragEnded: (() -> Void)?
    @State private var recordingStartDate: Date?
    @State private var screenshotTrigger = 0
    /// True right after the record button is clicked, until the session
    /// confirms actual recording (`isRecording`) or reports an error — pure
    /// local UI feedback so the click always visibly registers immediately,
    /// even though real recording only starts once the next keyframe shows
    /// up on the wire.
    @State private var isArming = false
    /// Smooths out the "Verbinden…" overlay: real connections often
    /// complete in well under 100ms, which made the loading screen flash
    /// in and immediately back out. Requiring it to have been visible for
    /// at least this long before revealing the mirror avoids that flicker
    /// without meaningfully slowing down the perceived connect time.
    @State private var displayConnected = false

    private var title: String {
        appState.androidDevices.first(where: { $0.serial == serial })?.model ?? serial
    }

    var body: some View {
        MirrorTileFrame(
            title: title,
            isConnected: displayConnected,
            statusText: "Verbinde mit \(title)…",
            errorText: session.lastError,
            onScreenshot: takeScreenshot,
            isRecording: session.isRecording || isArming,
            recordingStartDate: recordingStartDate,
            onToggleRecording: toggleRecording,
            showTouchesEnabled: session.showTouchesEnabled,
            onToggleShowTouches: { session.setShowTouches(!session.showTouchesEnabled) },
            stayAwakeEnabled: session.stayAwakeEnabled,
            onToggleStayAwake: { session.setStayAwake(!session.stayAwakeEnabled) },
            isScreenOff: session.isScreenOff,
            onToggleScreenPower: { session.toggleScreenPower() },
            screenshotTrigger: screenshotTrigger,
            isFocused: isFocused,
            onToggleFocus: onToggleFocus,
            fitVideoSize: appState.isOnlyVisibleTile(.android(serial)) ? session.videoSize : nil,
            onTitleBarDragChanged: onTitleBarDragChanged,
            onTitleBarDragEnded: onTitleBarDragEnded,
            onDisconnect: { appState.disconnect(.android(serial)) }
        ) {
            AndroidMirrorView(session: session)
        }
        .onChange(of: session.isRecording) { _, isRecording in
            if isRecording { isArming = false }
            recordingStartDate = isRecording ? Date() : nil
        }
        .onChange(of: session.recordingError) { _, error in
            guard let error else { return }
            isArming = false
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Aufnahme fehlgeschlagen"
            alert.informativeText = error
            alert.runModal()
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

    /// Grabs a full, native-resolution screenshot straight from the device
    /// via `adb exec-out screencap` (the same approach Vysor uses) rather
    /// than capturing our own on-screen mirror window.
    private func takeScreenshot() {
        let capturedSerial = serial
        let capturedTitle = title
        Task.detached(priority: .userInitiated) {
            guard let data = try? ADB.shared.captureScreenshotPNG(serial: capturedSerial) else { return }
            await MainActor.run {
                screenshotTrigger += 1
                ScreenshotSaver.promptAndSave(pngData: data, suggestedName: ScreenshotSaver.filename(prefix: capturedTitle))
            }
        }
    }

    private func toggleRecording() {
        if session.isRecording || isArming {
            isArming = false
            let capturedTitle = title
            session.stopRecording { tempURL in
                guard let tempURL else { return }
                ScreenshotSaver.promptAndMove(
                    tempURL: tempURL,
                    suggestedName: ScreenshotSaver.filename(prefix: capturedTitle, ext: "mp4"),
                    contentType: .mpeg4Movie
                )
            }
            return
        }
        isArming = true
        session.startRecording()
    }
}
