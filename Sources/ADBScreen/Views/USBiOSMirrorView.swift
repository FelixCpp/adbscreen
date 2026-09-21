import AppKit
import AVFoundation
import SwiftUI

/// View-only USB mirror: hosts the `AVCaptureVideoPreviewLayer` fed by
/// `USBiOSCaptureSession`. No input forwarding — `AVCaptureSession` gives us
/// video only, not a channel to inject touch/keyboard back into the device.
struct USBiOSMirrorView: NSViewRepresentable {
    @ObservedObject var session: USBiOSCaptureSession
    var onViewReady: ((USBiOSDisplayNSView) -> Void)? = nil

    func makeNSView(context: Context) -> USBiOSDisplayNSView {
        let view = USBiOSDisplayNSView()
        view.previewLayer = session.previewLayer
        onViewReady?(view)
        return view
    }

    func updateNSView(_ nsView: USBiOSDisplayNSView, context: Context) {
        nsView.previewLayer = session.previewLayer
    }
}

final class USBiOSDisplayNSView: NSView {
    var previewLayer: AVCaptureVideoPreviewLayer? {
        didSet {
            guard let previewLayer, previewLayer !== oldValue else { return }
            layer?.sublayers?.removeAll()
            layer?.addSublayer(previewLayer)
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
    }

    override func layout() {
        super.layout()
        previewLayer?.frame = bounds
    }
}
