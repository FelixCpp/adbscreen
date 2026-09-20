import SwiftUI

/// Metadata popover shown when clicking a device's icon badge in the
/// sidebar. Android gets real properties via `adb shell getprop`; AirPlay
/// has no such channel, so it just shows what the receiver itself knows.
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
                let info = ADB.shared.deviceInfo(serial: serial)
                DispatchQueue.main.async {
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
        case .airplay:
            var info: [(String, String)] = [("Dienstname", appState.airplayServiceName)]
            if let deviceName = appState.airplayDeviceName {
                info.append(("Gerätename", deviceName))
            }
            if let session = appState.airplaySessionInstance {
                let status = session.isConnected ? "Verbunden" : (session.isWaiting ? "Wartet auf Bildschirmsynchronisierung" : "Getrennt")
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
