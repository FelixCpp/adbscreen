import AVFoundation
import AppKit
import CoreMedia
import Foundation
import ScreenCaptureKit

enum IPhoneMirroringCaptureError: Error, LocalizedError {
    case appLaunchFailed
    case windowNotFound
    case streamFailed(String)

    var errorDescription: String? {
        switch self {
        case .appLaunchFailed:
            return "„iPhone-Spiegelung“ konnte nicht gestartet werden."
        case .windowNotFound:
            return "Kein Fenster von „iPhone-Spiegelung“ gefunden."
        case .streamFailed(let message):
            return message
        }
    }
}

/// Mirrors an iPhone/iPad through Apple's own built-in **iPhone-Spiegelung**
/// (`iPhone Mirroring.app`, bundle id `com.apple.ScreenContinuity`) instead
/// of AirPlay. That system feature uses Continuity (Bluetooth + a private
/// Wi-Fi/peer-to-peer link, the same transport as Sidecar/Universal
/// Control) rather than the `_airplay._tcp`/`_raop._tcp` AirPlay services —
/// so on a machine that blocks AirPlay specifically but not Continuity in
/// general, this keeps working.
///
/// There is no public API to embed that system app's video feed directly
/// (unlike AirPlay, where we run our own receiver, or USB muxed capture,
/// which — as of macOS 26 — no longer surfaces the device as an
/// `AVCaptureDevice` at all; see `USBiOSCaptureSession`'s doc comment for
/// that dead end). Instead, this launches the system app and continuously
/// captures *its own window's* contents via `ScreenCaptureKit` — the same
/// public API `WindowSnapshot` already uses for one-off screenshots, just
/// as a live stream instead of a single frame. That means: no touch/
/// keyboard passthrough (we're only reading pixels of someone else's
/// window, not driving it), and the system app's own window chrome/connect
/// UI is visible inside the tile exactly as Apple renders it.
final class IPhoneMirroringCaptureSession: NSObject, ObservableObject {
    static let bundleIdentifier = "com.apple.ScreenContinuity"
    static let appURL = URL(fileURLWithPath: "/System/Applications/iPhone Mirroring.app")

    let displayLayer = AVSampleBufferDisplayLayer()

    /// True once real frames from the mirrored window are flowing.
    @Published private(set) var isConnected = false
    /// True while we're waiting for the system app's window to appear
    /// (freshly launched, or momentarily gone e.g. between reconnects).
    @Published private(set) var isWaiting = false
    @Published private(set) var lastError: String?
    @Published private(set) var videoSize: CGSize = .zero

    private var stream: SCStream?
    private var pollTask: Task<Void, Never>?
    private let sampleQueue = DispatchQueue(label: "adbscreen.iphonemirroring.capture")
    private var stopped = false

    func start() {
        stopped = false
        isWaiting = true
        lastError = nil

        NSWorkspace.shared.open(
            Self.appURL,
            configuration: {
                let config = NSWorkspace.OpenConfiguration()
                config.activates = false
                return config
            }()
        ) { [weak self] _, error in
            guard let self, let error else { return }
            DispatchQueue.main.async {
                self.isWaiting = false
                self.lastError = IPhoneMirroringCaptureError.appLaunchFailed.errorDescription
                _ = error
            }
        }

        pollTask = Task { [weak self] in
            await self?.pollUntilAttached()
        }
    }

    func stop() {
        stopped = true
        pollTask?.cancel()
        pollTask = nil
        let activeStream = stream
        stream = nil
        Task { try? await activeStream?.stopCapture() }
        isConnected = false
        isWaiting = false
    }

    // MARK: - Attaching to the system app's window

    /// Repeatedly looks for the mirroring window until it's found (the
    /// system app takes a moment to launch, and its window only exists once
    /// launched) or capture is stopped. Also what re-runs after
    /// `didStopWithError` — e.g. the user manually quitting the system app
    /// closes the window our stream was capturing.
    private func pollUntilAttached() async {
        while !stopped, !Task.isCancelled {
            if await attachToWindowIfAvailable() { return }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    @MainActor
    private func attachToWindowIfAvailable() async -> Bool {
        guard !stopped else { return true }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard let window = content.windows.first(where: {
                $0.owningApplication?.bundleIdentifier == Self.bundleIdentifier
            }) else {
                return false
            }

            let filter = SCContentFilter(desktopIndependentWindow: window)
            let config = SCStreamConfiguration()
            config.width = max(1, Int(window.frame.width.rounded()))
            config.height = max(1, Int(window.frame.height.rounded()))
            config.showsCursor = false
            config.capturesAudio = false
            config.queueDepth = 5

            let stream = SCStream(filter: filter, configuration: config, delegate: self)
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
            try await stream.startCapture()

            self.stream = stream
            self.videoSize = window.frame.size
            self.isWaiting = false
            self.lastError = nil
            return true
        } catch {
            self.lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return false
        }
    }

    /// `ScreenCaptureKit`-sourced sample buffers otherwise only display once
    /// their (system-clock) presentation time elapses against
    /// `displayLayer`'s own timebase, which can lag behind by however long
    /// capture setup took — every other H.264 source in this app avoids
    /// that the same way (see `H264CoreMedia`), so this mirrors that here.
    private func markDisplayImmediately(_ sampleBuffer: CMSampleBuffer) {
        guard let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
              CFArrayGetCount(attachmentsArray) > 0 else { return }
        let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachmentsArray, 0), to: CFMutableDictionary.self)
        CFDictionarySetValue(
            dict,
            Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
            Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
        )
    }
}

extension IPhoneMirroringCaptureSession: SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid else { return }
        markDisplayImmediately(sampleBuffer)
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.stopped else { return }
            self.isWaiting = false
            self.isConnected = true
            if self.displayLayer.status == .failed {
                self.displayLayer.flush()
            }
            self.displayLayer.enqueue(sampleBuffer)
        }
    }
}

extension IPhoneMirroringCaptureSession: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isConnected = false
            if !self.stopped {
                self.lastError = error.localizedDescription
                self.isWaiting = true
                self.pollTask = Task { [weak self] in
                    await self?.pollUntilAttached()
                }
            }
        }
    }
}
