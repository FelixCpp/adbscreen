import AppKit
import CoreGraphics

/// Tracks the macOS "Bildschirmaufnahme" (Screen Recording) TCC permission
/// that `WindowSnapshot` needs for screenshots/recordings. There's no change
/// notification for this category, so callers re-check on demand (e.g. when
/// the app regains focus after a trip to System Settings).
final class ScreenCapturePermission: ObservableObject {
    @Published private(set) var isGranted: Bool = CGPreflightScreenCaptureAccess()

    func refresh() {
        isGranted = CGPreflightScreenCaptureAccess()
    }

    /// Triggers the system prompt the first time it's called. Once denied,
    /// macOS never re-prompts and this silently no-ops — the UI must also
    /// offer a System Settings deep link for that case.
    func request() {
        CGRequestScreenCaptureAccess()
        refresh()
    }
}
