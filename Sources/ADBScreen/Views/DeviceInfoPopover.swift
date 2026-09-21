import SwiftUI

/// Metadata popover shown when clicking a device's icon badge in the
/// sidebar. Android gets real properties via `adb shell getprop`; the USB
/// capture path has no such channel, so it just shows what the capture
/// session itself knows.
struct DeviceInfoPopover: View {
    let selection: AppState.DeviceSelection
    let title: String
    @ObservedObject var appState: AppState

    @State private var pairs: [(label: String, value: String)] = []
    @State private var isLoading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
            Divider()
            if isLoading {
                HStack {
                    Spacer()
                    ProgressView().controlSize(.small)
                    Spacer()
                }
                .padding(.vertical, 4)
            } else if pairs.isEmpty {
                Text("Keine Informationen verfügbar.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(pairs, id: \.label) { pair in
                        HStack(alignment: .top) {
                            Text(pair.label)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 12)
                            Text(pair.value)
                                .font(.system(size: 12, weight: .medium))
                                .multilineTextAlignment(.trailing)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 280)
        .onAppear(perform: load)
    }

    private func load() {
        switch selection {
        case .android(let serial):
            DispatchQueue.global(qos: .userInitiated).async {
                var info = ADB.shared.deviceInfo(serial: serial)
                DispatchQueue.main.async {
                    // `getprop` doesn't reliably expose the screen resolution
                    // across devices/manufacturers, but scrcpy already learns
                    // it from the video stream's actual dimensions once
                    // connected — reuse that instead of another adb round
                    // trip (which would need `wm size` and still lag behind
                    // rotation changes).
                    if let size = self.appState.androidSession(for: serial)?.videoSize, size != .zero {
                        if let serialIndex = info.firstIndex(where: { $0.0 == "Seriennummer" }) {
                            info.insert(("Auflösung", "\(Int(size.width))×\(Int(size.height))"), at: serialIndex)
                        } else {
                            info.append(("Auflösung", "\(Int(size.width))×\(Int(size.height))"))
                        }
                    }
                    self.pairs = info
                    self.isLoading = false
                }
            }
        case .simulated(let serial):
            pairs = [
                ("Modell", title),
                ("Status", "Simuliertes Gerät"),
                ("Auflösung", "1080×2400"),
                ("Seriennummer", serial),
            ]
            isLoading = false
        case .usbIOS(let uniqueID):
            var info: [(String, String)] = [("Gerätename", title), ("Verbindung", "USB")]
            if let session = appState.usbIOSSession(for: uniqueID) {
                let status = session.isConnected ? "Verbunden" : (session.isWaiting ? "Verbindet…" : "Getrennt")
                info.append(("Status", status))
                if session.videoSize != .zero {
                    info.append(("Auflösung", "\(Int(session.videoSize.width))×\(Int(session.videoSize.height))"))
                }
            }
            pairs = info
            isLoading = false
        }
    }
}
