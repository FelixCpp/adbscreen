import AVFoundation
import Foundation

/// Tracks the macOS "Kamera" (Camera) TCC permission that USB iOS mirroring
/// needs — a connected iPhone/iPad shows up as an `AVCaptureDevice`, so
/// accessing it is gated behind the same permission as any other camera.
final class CameraPermission: ObservableObject {
    @Published private(set) var isGranted: Bool = AVCaptureDevice.authorizationStatus(for: .video) == .authorized

    func refresh() {
        isGranted = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
    }

    /// Triggers the system prompt the first time it's called (i.e. while
    /// still `.notDetermined`). Once denied, macOS never re-prompts and
    /// this silently no-ops — the UI must also offer a System Settings deep
    /// link for that case.
    func request() {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] _ in
            DispatchQueue.main.async { self?.refresh() }
        }
    }
}
