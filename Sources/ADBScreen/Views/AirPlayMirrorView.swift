import AppKit
import AVFoundation
import SwiftUI

/// View-only AirPlay mirror: hosts the AVSampleBufferDisplayLayer fed by
/// AirPlayReceiverSession. No input forwarding — AirPlay Mirroring has no
/// supported channel for injecting touch/keyboard back into the device.
struct AirPlayMirrorView: NSViewRepresentable {
    @ObservedObject var session: AirPlayReceiverSession
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

final class AirPlayDisplayNSView: NSView {
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
