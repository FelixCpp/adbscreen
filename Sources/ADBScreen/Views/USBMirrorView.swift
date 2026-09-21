import AppKit
import AVFoundation
import SwiftUI

/// View-only USB mirror: hosts the AVSampleBufferDisplayLayer fed by
/// USBMirrorReceiverSession. No input forwarding — same limitation as
/// AirPlayMirrorView, plus USB screen-mirroring specifically has no
/// documented touch/keyboard injection channel at all (competitors like
/// Vysor emulate a Bluetooth HID device for that instead).
struct USBMirrorView: NSViewRepresentable {
    @ObservedObject var session: USBMirrorReceiverSession
    var onViewReady: ((USBMirrorDisplayNSView) -> Void)? = nil

    func makeNSView(context: Context) -> USBMirrorDisplayNSView {
        let view = USBMirrorDisplayNSView()
        view.displayLayer = session.displayLayer
        onViewReady?(view)
        return view
    }

    func updateNSView(_ nsView: USBMirrorDisplayNSView, context: Context) {
        nsView.displayLayer = session.displayLayer
    }
}

final class USBMirrorDisplayNSView: NSView {
    var displayLayer: AVSampleBufferDisplayLayer? {
        didSet {
            guard let displayLayer, displayLayer !== oldValue else { return }
            layer?.sublayers?.removeAll()
            displayLayer.videoGravity = .resizeAspect
            layer?.addSublayer(displayLayer)
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
        displayLayer?.frame = bounds
    }
}
