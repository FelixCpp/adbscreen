import AppKit
import SwiftUI

enum WindowAspectFit {
    static func fit(window: NSWindow, currentArea: CGSize, videoSize: CGSize) {
        guard videoSize.width > 0, videoSize.height > 0,
              currentArea.width > 0, currentArea.height > 0 else { return }

        let aspect = videoSize.width / videoSize.height
        let frame = window.frame
        let chrome = CGSize(width: frame.width - currentArea.width, height: frame.height - currentArea.height)

        var target = CGSize(width: currentArea.height * aspect, height: currentArea.height)

        let contentMin = window.frameRect(forContentRect: CGRect(origin: .zero, size: window.contentMinSize)).size
        let minSize = CGSize(
            width: max(window.minSize.width, contentMin.width),
            height: max(window.minSize.height, contentMin.height)
        )
        if chrome.width + target.width < minSize.width {
            target.width = minSize.width - chrome.width
            target.height = target.width / aspect
        }
        if chrome.height + target.height < minSize.height {
            target.height = minSize.height - chrome.height
            target.width = target.height * aspect
        }

        if let visible = (window.screen ?? NSScreen.main)?.visibleFrame {
            let maxArea = CGSize(width: visible.width - chrome.width, height: visible.height - chrome.height)
            if target.width > maxArea.width {
                target.width = maxArea.width
                target.height = target.width / aspect
            }
            if target.height > maxArea.height {
                target.height = maxArea.height
                target.width = target.height * aspect
            }
        }

        let newSize = CGSize(
            width: (chrome.width + target.width).rounded(),
            height: (chrome.height + target.height).rounded()
        )
        var newFrame = CGRect(
            x: frame.midX - newSize.width / 2,
            y: frame.maxY - newSize.height,
            width: newSize.width,
            height: newSize.height
        )
        newFrame = window.constrainFrameRect(newFrame, to: window.screen)
        window.setFrame(newFrame, display: true, animate: true)
    }
}

struct WindowReader: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = WindowReaderView()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class WindowReaderView: NSView {
        var onWindow: ((NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let window = self.window
            DispatchQueue.main.async { [weak self] in
                self?.onWindow?(window)
            }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
