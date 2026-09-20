import AppKit
import ScreenCaptureKit

/// Captures just one view's on-screen content via ScreenCaptureKit.
///
/// AVSampleBufferDisplayLayer content is hardware-composited straight into
/// the window's backing store, bypassing NSView's normal draw path — so
/// `NSView.cacheDisplay`/`CALayer.render(in:)` produce a blank image for it.
/// ScreenCaptureKit reads the actual composited window buffer instead,
/// which works reliably. This requires Screen Recording permission; macOS
/// prompts for it automatically on first use.
enum WindowSnapshot {
    enum SnapshotError: LocalizedError {
        case noWindow
        case windowNotFound
        case underlying(Error)

        var errorDescription: String? {
            switch self {
            case .noWindow:
                return "Kein Fenster für diese Ansicht gefunden."
            case .windowNotFound:
                return "ScreenCaptureKit konnte das App-Fenster nicht in der Liste der aufnehmbaren Fenster finden."
            case .underlying(let error):
                return error.localizedDescription
            }
        }
    }

    @MainActor
    static func capture(of view: NSView) async throws -> NSImage {
        guard let window = view.window, let screen = window.screen ?? NSScreen.main else {
            throw SnapshotError.noWindow
        }
        let scale = screen.backingScaleFactor

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw SnapshotError.underlying(error)
        }

        guard let scWindow = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else {
            throw SnapshotError.windowNotFound
        }

        let filter = SCContentFilter(desktopIndependentWindow: scWindow)
        let config = SCStreamConfiguration()
        config.width = max(1, Int((window.frame.width * scale).rounded()))
        config.height = max(1, Int((window.frame.height * scale).rounded()))
        config.showsCursor = false
        // macOS bundles "Screen Recording" and "System Audio Recording" into
        // one TCC permission category regardless of actual usage — the
        // system prompt always mentions audio even though we never enable
        // it here. This is a still image; no audio is captured or needed.
        config.capturesAudio = false

        let cgImage: CGImage
        do {
            cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        } catch {
            throw SnapshotError.underlying(error)
        }

        // Crop from the full window capture down to just this view,
        // converting AppKit's bottom-left-origin view frame into the
        // top-left-origin pixel rect the captured CGImage uses.
        let frameInWindow = view.convert(view.bounds, to: nil)
        let windowHeight = window.frame.height
        let cropRect = CGRect(
            x: frameInWindow.origin.x * scale,
            y: (windowHeight - frameInWindow.maxY) * scale,
            width: frameInWindow.width * scale,
            height: frameInWindow.height * scale
        ).integral

        guard let cropped = cgImage.cropping(to: cropRect) else {
            return NSImage(cgImage: cgImage, size: window.frame.size)
        }
        return NSImage(cgImage: cropped, size: frameInWindow.size)
    }
}
