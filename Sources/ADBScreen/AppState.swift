import Combine
import Foundation

/// Owns the actual mirror sessions (keyed by device) so they can outlive any
/// single view — the user explicitly "connects" one or more devices from the
/// sidebar, and every connected device keeps mirroring simultaneously in a
/// grid, independent of what's currently selected/focused in the UI.
final class AppState: ObservableObject {
    enum DeviceSelection: Hashable {
        case android(String)
        case simulated(String)
        case airplay
    }

    @Published var androidDevices: [AndroidDevice] = []
    @Published private(set) var simulatedDevices: [AndroidDevice] = AppState.demoDevices
    @Published private(set) var connectedOrder: [DeviceSelection] = []
    @Published var adbAvailable: Bool = ADB.shared.executablePath != nil

    /// Selections whose underlying session has actually completed its
    /// handshake (`session.isConnected == true`), as opposed to merely
    /// having been requested by the user (see `connectedOrder`). Mirrored
    /// from each session's own `$isConnected` publisher so the sidebar's
    /// "Verbunden" status stays in sync with the tile's title-bar dot,
    /// instead of flipping green the instant a connection attempt starts.
    @Published private(set) var liveConnected: Set<DeviceSelection> = []
    private var liveConnectionCancellables: [DeviceSelection: AnyCancellable] = [:]

    /// AirPlay mirroring has no ahead-of-time device discovery (it's a
    /// receiver waiting for a connection, not a scanned device list), so
    /// this is a fixed entry rather than a dynamic array like androidDevices.
    let airplayServiceName = "ADBScreen"

    /// The connected iPhone/iPad's device name (e.g. "iPhone 15"), mirrored
    /// from the active AirPlayReceiverSession so the sidebar/tile can show
    /// it without every view needing to observe the session object itself.
    /// `nil` until a client actually connects and announces its name.
    @Published private(set) var airplayDeviceName: String?
    private var airplayDeviceNameCancellable: AnyCancellable?

    /// What to show for the AirPlay entry: the actual connected device's
    /// name once known, falling back to our own advertised service name
    /// beforehand (e.g. while disconnected or still waiting for the
    /// handshake to report it).
    var airplayDisplayName: String { airplayDeviceName ?? airplayServiceName }

    private var scrcpySessions: [String: ScrcpySession] = [:]
    private var airplaySession: AirPlayReceiverSession?
    private let powerAssertion = PowerAssertion()

    private var pollTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    private static let demoDevices: [AndroidDevice] = [
        AndroidDevice(serial: "demo-pixel-01", model: "Demo Pixel 8", state: "device"),
        AndroidDevice(serial: "demo-galaxy-02", model: "Demo Galaxy S24", state: "device"),
        AndroidDevice(serial: "demo-xperia-03", model: "Demo Xperia 1 V", state: "device"),
        AndroidDevice(serial: "demo-oneplus-04", model: "Demo OnePlus 12", state: "device"),
        AndroidDevice(serial: "demo-nothing-05", model: "Demo Nothing Phone", state: "device"),
    ]

    // MARK: - Connection memory

    /// Devices the user explicitly asked to connect, persisted across
    /// launches so they auto-reconnect — set only by explicit
    /// connect/disconnect (via `toggle`/`connect`), never by the automatic
    /// stale-device cleanup below, so unplugging a phone doesn't erase the
    /// intent to mirror it once it's plugged back in.
    private static let desiredConnectionsDefaultsKey = "adbscreen.desiredConnections"

    private var desiredKeys: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: Self.desiredConnectionsDefaultsKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: Self.desiredConnectionsDefaultsKey) }
    }

    /// The user's last manual grid arrangement (via drag-to-swap in
    /// `MirrorGridView`), persisted as an ordered list of persistence keys
    /// so the tile layout survives an app relaunch instead of just falling
    /// back to whatever order devices happen to (re)connect in.
    private static let tileOrderDefaultsKey = "adbscreen.tileOrder"

    private var savedTileOrder: [String] {
        get { UserDefaults.standard.stringArray(forKey: Self.tileOrderDefaultsKey) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: Self.tileOrderDefaultsKey) }
    }

    /// Merges the current arrangement into the saved order instead of
    /// overwriting it outright. Devices connect one at a time (e.g. during
    /// the async auto-reconnect on launch), so a naive overwrite would
    /// truncate the saved order down to whichever single device just
    /// connected and permanently lose the remembered position of every
    /// device that hasn't reconnected yet. Keys not currently connected
    /// are left untouched at their old position; the block of currently
    /// connected keys is replaced, as a whole, with their live order.
    private func persistTileOrder() {
        let currentKeys = connectedOrder.map(persistenceKey(for:))
        let currentSet = Set(currentKeys)
        var merged: [String] = []
        var insertedCurrent = false
        for key in savedTileOrder {
            if currentSet.contains(key) {
                if !insertedCurrent {
                    merged.append(contentsOf: currentKeys)
                    insertedCurrent = true
                }
            } else {
                merged.append(key)
            }
        }
        if !insertedCurrent {
            merged.append(contentsOf: currentKeys)
        }
        savedTileOrder = merged
    }

    /// Re-sorts `connectedOrder` to match the last saved arrangement.
    /// Devices not present in the saved order (e.g. connected for the
    /// first time) keep their relative position at the end — Swift's
    /// `sort` is stable, so this never reshuffles unrelated tiles.
    private func applySavedOrder() {
        let order = savedTileOrder
        guard !order.isEmpty else { return }
        connectedOrder.sort { a, b in
            let indexA = order.firstIndex(of: persistenceKey(for: a))
            let indexB = order.firstIndex(of: persistenceKey(for: b))
            switch (indexA, indexB) {
            case let (a?, b?): return a < b
            case (nil, _?): return false
            case (_?, nil): return true
            case (nil, nil): return false
            }
        }
    }

    private func persistenceKey(for selection: DeviceSelection) -> String {
        switch selection {
        case .android(let serial): return "android:\(serial)"
        case .simulated(let serial): return "simulated:\(serial)"
        case .airplay: return "airplay"
        }
    }

    init() {
        refreshAndroid()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.refreshAndroid()
        }
        if desiredKeys.contains(persistenceKey(for: .airplay)) {
            connect(.airplay)
        }
    }

    func isConnected(_ selection: DeviceSelection) -> Bool {
        connectedOrder.contains(selection)
    }

    /// Whether the session for `selection` has actually finished connecting
    /// (matches the tile's title-bar dot), not just whether the user asked
    /// for it to connect.
    func isLiveConnected(_ selection: DeviceSelection) -> Bool {
        liveConnected.contains(selection)
    }

    private func subscribeLiveConnection(for selection: DeviceSelection, publisher: Published<Bool>.Publisher) {
        liveConnectionCancellables[selection] = publisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] connected in
                guard let self else { return }
                if connected {
                    self.liveConnected.insert(selection)
                } else {
                    self.liveConnected.remove(selection)
                }
            }
    }

    func toggle(_ selection: DeviceSelection) {
        isConnected(selection) ? disconnect(selection) : connect(selection)
    }

    func connect(_ selection: DeviceSelection) {
        guard !connectedOrder.contains(selection) else { return }
        switch selection {
        case .android(let serial):
            guard let device = androidDevices.first(where: { $0.serial == serial }) else { return }
            let session = scrcpySessions[serial] ?? ScrcpySession(device: device)
            scrcpySessions[serial] = session
            subscribeLiveConnection(for: selection, publisher: session.$isConnected)
            session.start()
        case .simulated:
            liveConnected.insert(selection)
        case .airplay:
            let session = airplaySession ?? AirPlayReceiverSession(serviceName: airplayServiceName)
            airplaySession = session
            airplayDeviceNameCancellable = session.$deviceName
                .receive(on: DispatchQueue.main)
                .sink { [weak self] name in self?.airplayDeviceName = name }
            subscribeLiveConnection(for: selection, publisher: session.$isConnected)
            session.start()
        }
        connectedOrder.append(selection)
        applySavedOrder()
        persistTileOrder()
        updatePowerAssertion()
        if case .simulated = selection {
            // Demo devices are intentionally session-only and should not
            // affect the real-device auto-reconnect preference.
        } else {
            desiredKeys.insert(persistenceKey(for: selection))
        }
    }

    /// `forgetIntent` is false for automatic disconnects (e.g. a device
    /// getting unplugged) so the user's "I want this mirrored" intent
    /// survives and it reconnects the moment it's available again.
    func disconnect(_ selection: DeviceSelection, forgetIntent: Bool = true) {
        guard let index = connectedOrder.firstIndex(of: selection) else { return }
        connectedOrder.remove(at: index)
        liveConnectionCancellables[selection] = nil
        liveConnected.remove(selection)
        switch selection {
        case .android(let serial):
            scrcpySessions[serial]?.stop()
            scrcpySessions.removeValue(forKey: serial)
        case .simulated:
            break
        case .airplay:
            airplaySession?.stop()
            airplaySession = nil
            airplayDeviceNameCancellable = nil
            airplayDeviceName = nil
        }
        updatePowerAssertion()
        persistTileOrder()
        if forgetIntent {
            desiredKeys.remove(persistenceKey(for: selection))
        }
    }

    /// Swaps two connected tiles' positions in the grid.
    func swapTiles(_ first: DeviceSelection, _ second: DeviceSelection) {
        guard first != second,
              let fromIndex = connectedOrder.firstIndex(of: first),
              let toIndex = connectedOrder.firstIndex(of: second) else { return }
        connectedOrder.swapAt(fromIndex, toIndex)
        persistTileOrder()
    }

    private func updatePowerAssertion() {
        if connectedOrder.isEmpty {
            powerAssertion.release()
        } else {
            powerAssertion.acquire(reason: "ADBScreen: aktive Bildschirmspiegelung")
        }
    }

    /// Tears down and restarts a device's session — useful when it's stuck
    /// in an error state (e.g. a dropped scrcpy connection or a crashed
    /// AirPlay helper) without having to click Trennen and Verbinden
    /// separately.
    func reconnect(_ selection: DeviceSelection) {
        if isConnected(selection) {
            disconnect(selection)
        }
        connect(selection)
    }

    func androidSession(for serial: String) -> ScrcpySession? {
        scrcpySessions[serial]
    }

    func simulateDevices(count: Int) {
        let selections = simulatedDevices.prefix(max(0, min(count, simulatedDevices.count))).map {
            DeviceSelection.simulated($0.serial)
        }
        for selection in connectedOrder where isSimulated(selection) {
            disconnect(selection, forgetIntent: false)
        }
        for selection in selections {
            connect(selection)
        }
    }

    func isSimulated(_ selection: DeviceSelection) -> Bool {
        if case .simulated = selection { return true }
        return false
    }

    func simulatedDevice(for serial: String) -> AndroidDevice? {
        simulatedDevices.first(where: { $0.serial == serial })
    }

    var airplaySessionInstance: AirPlayReceiverSession? {
        airplaySession
    }

    /// Re-checks for the adb binary (in case it was installed after this
    /// app launched) and forces an immediate device list refresh, rather
    /// than waiting for the next poll tick.
    func refreshNow() {
        ADB.shared.refreshExecutablePath()
        adbAvailable = ADB.shared.executablePath != nil
        refreshAndroid()
    }

    private func refreshAndroid() {
        guard ADB.shared.executablePath != nil else { return }
        DispatchQueue.global(qos: .utility).async {
            let devices = ADB.shared.listDevices()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.androidDevices = devices

                // Auto-disconnect sessions for devices that were unplugged.
                let presentSerials = Set(devices.map(\.serial))
                let stale = self.connectedOrder.filter { selection in
                    if case .android(let serial) = selection {
                        return !presentSerials.contains(serial)
                    }
                    return false
                }
                for selection in stale {
                    self.disconnect(selection, forgetIntent: false)
                }

                // Auto-reconnect devices the user previously wanted
                // connected — covers both "at launch" (first poll tick)
                // and "plugged back in mid-session".
                let desired = self.desiredKeys
                for device in devices where device.isReady {
                    let selection = DeviceSelection.android(device.serial)
                    if desired.contains(self.persistenceKey(for: selection)), !self.isConnected(selection) {
                        self.connect(selection)
                    }
                }
            }
        }
    }
}
