import SwiftUI

/// Picks the right tile implementation for a connected device selection.
struct MirrorTile: View {
    let selection: AppState.DeviceSelection
    @ObservedObject var appState: AppState
    var onTitleBarDragChanged: ((CGPoint, CGSize) -> Void)?
    var onTitleBarDragEnded: (() -> Void)?

    private var isFocused: Bool { appState.focusedSelection == selection }
    private func toggleFocus() { appState.toggleFocus(selection) }

    var body: some View {
        switch selection {
        case .android(let serial):
            if let session = appState.androidSession(for: serial) {
                AndroidMirrorTile(
                    serial: serial,
                    session: session,
                    appState: appState,
                    isFocused: isFocused,
                    onToggleFocus: toggleFocus,
                    onTitleBarDragChanged: onTitleBarDragChanged,
                    onTitleBarDragEnded: onTitleBarDragEnded
                )
            }
        case .simulated(let serial):
            if let device = appState.simulatedDevice(for: serial) {
                SimulatedMirrorTile(
                    device: device,
                    appState: appState,
                    isFocused: isFocused,
                    onToggleFocus: toggleFocus,
                    onTitleBarDragChanged: onTitleBarDragChanged,
                    onTitleBarDragEnded: onTitleBarDragEnded
                )
            }
        case .airplay:
            if let session = appState.airplaySessionInstance {
                AirPlayMirrorTile(
                    session: session,
                    appState: appState,
                    isFocused: isFocused,
                    onToggleFocus: toggleFocus,
                    onTitleBarDragChanged: onTitleBarDragChanged,
                    onTitleBarDragEnded: onTitleBarDragEnded
                )
            }
        case .usbIOS(let uniqueID):
            if let session = appState.usbIOSSession(for: uniqueID) {
                USBiOSMirrorTile(
                    session: session,
                    appState: appState,
                    isFocused: isFocused,
                    onToggleFocus: toggleFocus,
                    onTitleBarDragChanged: onTitleBarDragChanged,
                    onTitleBarDragEnded: onTitleBarDragEnded
                )
            }
        case .iphoneMirroring:
            if let session = appState.iphoneMirroringSessionInstance {
                IPhoneMirroringMirrorTile(
                    session: session,
                    appState: appState,
                    isFocused: isFocused,
                    onToggleFocus: toggleFocus,
                    onTitleBarDragChanged: onTitleBarDragChanged,
                    onTitleBarDragEnded: onTitleBarDragEnded
                )
            }
        }
    }
}
