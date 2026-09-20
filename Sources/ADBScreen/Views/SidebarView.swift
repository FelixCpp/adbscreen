import SwiftUI

struct SidebarView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        List {
            Section {
                if appState.androidDevices.isEmpty {
                    Text("Keine Geräte gefunden")
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                }
                ForEach(appState.androidDevices) { device in
                    DeviceRow(
                        title: device.model,
                        subtitle: device.isReady ? nil : device.state,
                        icon: "smartphone",
                        tint: .green,
                        selection: .android(device.serial),
                        enabled: device.isReady,
                        appState: appState
                    )
                    .transition(.asymmetric(insertion: .opacity.combined(with: .move(edge: .leading)), removal: .opacity))
                }
            } header: {
                Text("Android")
            }

            Section {
                ForEach(appState.simulatedDevices) { device in
                    DeviceRow(
                        title: device.model,
                        subtitle: "Demo",
                        icon: "rectangle.on.rectangle",
                        tint: .orange,
                        selection: .simulated(device.serial),
                        enabled: true,
                        appState: appState
                    )
                }
            } header: {
                HStack {
                    Text("Simulation")
                    Spacer()
                    Menu {
                        Button("4 Demo-Geräte anzeigen") {
                            appState.simulateDevices(count: 4)
                        }
                        Button("5 Demo-Geräte anzeigen") {
                            appState.simulateDevices(count: 5)
                        }
                        Divider()
                        Button("Demo-Geräte trennen") {
                            for selection in appState.connectedOrder where appState.isSimulated(selection) {
                                appState.disconnect(selection, forgetIntent: false)
                            }
                        }
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                    }
                    .menuStyle(.borderlessButton)
                    .help("Mehrere Geräte simulieren")
                }
            }

            Section {
                DeviceRow(
                    title: appState.airplayDisplayName,
                    subtitle: nil,
                    icon: "iphone",
                    tint: .blue,
                    selection: .airplay,
                    enabled: true,
                    appState: appState
                )
            } header: {
                Text("iOS (AirPlay)")
            }
        }
        .animation(.easeInOut(duration: 0.25), value: appState.androidDevices)
        .listStyle(.sidebar)
        .navigationTitle("Geräte")
        .toolbar {
            // NavigationSplitView merges every column's toolbar into one
            // shared window toolbar, so this item stays mounted (and
            // visible) even once the sidebar column itself is collapsed —
            // hide it explicitly instead of relying on the column's own
            // disappearance.
            if appState.sidebarVisibility != .detailOnly {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        appState.refreshNow()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("Android-Geräteliste aktualisieren (adb erneut prüfen)")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        appState.showOnboarding = true
                    } label: {
                        Image(systemName: "checklist")
                    }
                    .help("Einrichtung / Berechtigungen prüfen")
                }
            }
        }
    }
}

private struct DeviceRow: View {
    let title: String
    let subtitle: String?
    let icon: String
    let tint: Color
    let selection: AppState.DeviceSelection
    let enabled: Bool
    @ObservedObject var appState: AppState

    @State private var showInfo = false

    var body: some View {
        let connected = appState.isConnected(selection)
        let liveConnected = appState.isLiveConnected(selection)
        HStack(spacing: 12) {
            Button {
                showInfo = true
            } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(tint.opacity(0.16))
                        .frame(width: 36, height: 36)
                    Image(systemName: icon)
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(tint)
                }
            }
            .buttonStyle(.plain)
            .help("Geräteinfo anzeigen")
            .popover(isPresented: $showInfo, arrowEdge: .trailing) {
                DeviceInfoPopover(selection: selection, title: title, appState: appState)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else if liveConnected {
                    Text("Verbunden")
                        .font(.system(size: 11))
                        .foregroundStyle(.green)
                } else if connected {
                    Text("Verbindet…")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 8)

            if connected {
                Button {
                    appState.reconnect(selection)
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.bordered)
                // Fixed on the button itself (not just the label) so its
                // bounding box is a constant regardless of any ambient
                // animation — otherwise the surrounding spring below can
                // make a still-settling row (e.g. one that just connected)
                // render this noticeably larger than an already-settled
                // row, even though both use the exact same view code.
                .frame(width: 32, height: 32)
                .clipShape(Circle())
                .help("Neu verbinden")
                .transition(.scale(scale: 0.5).combined(with: .opacity))
            }

            Button(connected ? "Trennen" : "Verbinden") {
                appState.toggle(selection)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .tint(connected ? .red : .accentColor)
            .disabled(!enabled)
            // "Verbinden" and "Trennen" have different text widths; without
            // a fixed minimum the button visibly jumps/narrows when toggled
            // and can momentarily mismatch its sibling row.
            .frame(minWidth: 78)
        }
        .padding(.vertical, 6)
        .opacity(enabled ? 1 : 0.5)
        // Scoped to just the values that actually need a cross-fade/slide
        // (icon/text swap, reconnect button insertion) rather than the
        // whole row: applying the spring row-wide let its underdamped
        // overshoot (dampingFraction 0.7) bleed into the buttons' own
        // frame sizes while a row's animation was still in flight, which
        // is what made two otherwise-identical rows look differently
        // sized in a screenshot taken mid-animation.
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: connected)
        .animation(.easeInOut(duration: 0.2), value: liveConnected)
    }
}
