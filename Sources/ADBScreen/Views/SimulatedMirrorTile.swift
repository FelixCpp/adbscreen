import SwiftUI

/// A lightweight preview tile used to test the multi-device layout without
/// needing additional phones connected over ADB.
struct SimulatedMirrorTile: View {
    let device: AndroidDevice
    @ObservedObject var appState: AppState
    var isFocused: Bool = false
    var onToggleFocus: (() -> Void)? = nil
    var onTitleBarDragChanged: ((CGPoint, CGSize) -> Void)?
    var onTitleBarDragEnded: (() -> Void)?

    @State private var screenshotTrigger = 0
    @State private var isScreenOff = false

    private var accent: Color {
        switch device.serial {
        case "demo-pixel-01": return .blue
        case "demo-galaxy-02": return .purple
        case "demo-xperia-03": return .orange
        case "demo-oneplus-04": return .green
        default: return .pink
        }
    }

    var body: some View {
        MirrorTileFrame(
            title: device.model,
            isConnected: appState.isLiveConnected(.simulated(device.serial)),
            statusText: "Verbinde mit \(device.model)…",
            footerNote: "Simuliertes Gerät",
            onScreenshot: { screenshotTrigger += 1 },
            showTouchesEnabled: false,
            onToggleShowTouches: {},
            stayAwakeEnabled: true,
            onToggleStayAwake: {},
            isScreenOff: isScreenOff,
            onToggleScreenPower: { isScreenOff.toggle() },
            screenshotTrigger: screenshotTrigger,
            isFocused: isFocused,
            onToggleFocus: onToggleFocus,
            onTitleBarDragChanged: onTitleBarDragChanged,
            onTitleBarDragEnded: onTitleBarDragEnded,
            onDisconnect: { appState.disconnect(.simulated(device.serial), forgetIntent: false) }
        ) {
            ZStack {
                LinearGradient(
                    colors: [accent.opacity(0.95), .black, accent.opacity(0.45)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Image(systemName: "wifi")
                        Spacer()
                        Text("12:42")
                            .font(.system(.caption, design: .monospaced))
                    }
                    .foregroundStyle(.white.opacity(0.8))
                    Spacer()
                    Text("ADBScreen")
                        .font(.system(size: 25, weight: .bold))
                    Text("Simulierter Android-Bildschirm")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.72))
                    HStack(spacing: 8) {
                        Circle().fill(.white.opacity(0.9)).frame(width: 8, height: 8)
                        Text(device.serial.replacingOccurrences(of: "demo-", with: "").uppercased())
                            .font(.caption.monospaced())
                            .foregroundStyle(.white.opacity(0.8))
                    }
                }
                .padding(22)
                .foregroundStyle(.white)
            }
            .overlay(alignment: .bottom) {
                Capsule()
                    .fill(.white.opacity(0.65))
                    .frame(width: 70, height: 4)
                    .padding(.bottom, 10)
            }
        }
    }
}
