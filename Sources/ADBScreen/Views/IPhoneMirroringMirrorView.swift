import AVFoundation
import AppKit
import SwiftUI

/// View-only iPhone-Spiegelung mirror: hosts the `AVSampleBufferDisplayLayer`
/// fed by `IPhoneMirroringCaptureSession`. Reuses `AirPlayDisplayNSView`
/// rather than duplicating it — that class only ever needed an
/// `AVSampleBufferDisplayLayer` to host, not anything AirPlay-specific.
struct IPhoneMirroringMirrorView: NSViewRepresentable {
    @ObservedObject var session: IPhoneMirroringCaptureSession
    var onViewReady: ((AirPlayDisplayNSView) -> Void)? = nil

    func makeNSView(context: Context) -> AirPlayDisplayNSView {
        let view = AirPlayDisplayNSView()
        view.displayLayer = session.displayLayer
        onViewReady?(view)
        return view
    }

    func updateNSView(_ nsView: AirPlayDisplayNSView, context: Context) {
        nsView.displayLayer = session.displayLayer
    }
}
