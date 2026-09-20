import AppKit
import AVFoundation
import SwiftUI

struct AndroidMirrorView: NSViewRepresentable {
    @ObservedObject var session: ScrcpySession
    var onViewReady: ((MirrorNSView) -> Void)? = nil

    func makeNSView(context: Context) -> MirrorNSView {
        let view = MirrorNSView()
        view.displayLayer = session.displayLayer
        view.session = session
        onViewReady?(view)
        return view
    }

    func updateNSView(_ nsView: MirrorNSView, context: Context) {
        // `session` can be swapped out for a brand-new ScrcpySession
        // instance (e.g. AppState auto-reconnecting after a sidebar
        // refresh briefly drops the device from `adb devices`), which
        // comes with its own `displayLayer`. Without re-attaching it here,
        // the NSView keeps rendering to the old, now-dead session's layer:
        // the new session's control socket still works fine (so
        // touch/scroll keeps reaching the device), but no more video
        // frames ever reach the visible layer, so the mirror appears
        // frozen.
        nsView.displayLayer = session.displayLayer
        nsView.session = session
        nsView.videoSize = session.videoSize
    }
}

/// Hosts the AVSampleBufferDisplayLayer and forwards mouse/keyboard input as
/// scrcpy control messages, translating view-local points to device pixel
/// coordinates while accounting for resizeAspect letterboxing.
final class MirrorNSView: NSView {
    var displayLayer: AVSampleBufferDisplayLayer? {
        didSet {
            guard let displayLayer, displayLayer !== oldValue else { return }
            layer?.sublayers?.removeAll()
            displayLayer.videoGravity = .resizeAspect
            // Setting the frame right away matters: `layout()` only runs on
            // the next AppKit layout pass, which isn't guaranteed to happen
            // immediately after this reattachment (e.g. right after a
            // session swap the view's own bounds haven't changed, so
            // nothing marks it as needing layout). Without this, the new
            // layer sits at `.zero` until some unrelated layout pass comes
            // along, rendering as a black view even though frames are
            // actively being enqueued into it.
            displayLayer.frame = bounds
            layer?.addSublayer(displayLayer)
            needsLayout = true
        }
    }

    var session: ScrcpySession?
    var videoSize: CGSize = .zero

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

    private func devicePoint(for locationInView: CGPoint) -> ScrcpyPosition? {
        guard videoSize.width > 0, videoSize.height > 0, bounds.width > 0, bounds.height > 0 else { return nil }
        let viewAspect = bounds.width / bounds.height
        let videoAspect = videoSize.width / videoSize.height

        let contentRect: CGRect
        if viewAspect > videoAspect {
            let width = bounds.height * videoAspect
            contentRect = CGRect(x: (bounds.width - width) / 2, y: 0, width: width, height: bounds.height)
        } else {
            let height = bounds.width / videoAspect
            contentRect = CGRect(x: 0, y: (bounds.height - height) / 2, width: bounds.width, height: height)
        }

        let clampedX = min(max(locationInView.x, contentRect.minX), contentRect.maxX)
        let clampedY = min(max(locationInView.y, contentRect.minY), contentRect.maxY)

        let relX = (clampedX - contentRect.minX) / contentRect.width
        // AppKit views are bottom-left origin; device coordinates are top-left.
        let relY = 1 - (clampedY - contentRect.minY) / contentRect.height

        let x = Int32((relX * videoSize.width).rounded())
        let y = Int32((relY * videoSize.height).rounded())
        return ScrcpyPosition(x: x, y: y, screenWidth: UInt16(videoSize.width), screenHeight: UInt16(videoSize.height))
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        sendTouch(event: event, action: .down)
    }

    override func mouseDragged(with event: NSEvent) {
        sendTouch(event: event, action: .move)
    }

    override func mouseUp(with event: NSEvent) {
        sendTouch(event: event, action: .up)
    }

    private func sendTouch(event: NSEvent, action: AndroidMotionEventAction) {
        guard let session, let pos = devicePoint(for: convert(event.locationInWindow, from: nil)) else { return }
        let buttons: UInt32 = action == .up ? 0 : AndroidMotionEventButton.primary.rawValue
        let msg = ScrcpyControlMessage.touch(
            action: action,
            pointerID: ScrcpyPointerID.mouse,
            position: pos,
            pressure: action == .up ? 0 : 1,
            actionButton: AndroidMotionEventButton.primary.rawValue,
            buttons: buttons
        )
        session.send(msg)
    }

    override func scrollWheel(with event: NSEvent) {
        guard let session, let pos = devicePoint(for: convert(event.locationInWindow, from: nil)) else { return }
        let msg = ScrcpyControlMessage.scroll(
            position: pos,
            hscroll: Float(event.scrollingDeltaX),
            vscroll: Float(-event.scrollingDeltaY),
            buttons: 0
        )
        session.send(msg)
    }

    override func keyDown(with event: NSEvent) {
        guard let session else { return }
        if let androidKeycode = AndroidKeycodeMap.keycode(for: event) {
            session.send(ScrcpyControlMessage.keycode(action: .down, keycode: androidKeycode))
            return
        }
        if let characters = event.characters, !characters.isEmpty, event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            session.send(ScrcpyControlMessage.text(characters))
        }
    }

    override func keyUp(with event: NSEvent) {
        guard let session, let androidKeycode = AndroidKeycodeMap.keycode(for: event) else { return }
        session.send(ScrcpyControlMessage.keycode(action: .up, keycode: androidKeycode))
    }

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }
}
