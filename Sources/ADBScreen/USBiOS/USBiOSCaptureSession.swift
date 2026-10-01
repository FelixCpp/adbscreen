import AVFoundation
import CoreMedia
import Foundation

enum USBiOSCaptureError: Error, LocalizedError {
    case deviceUnavailable
    case inputUnavailable
    case configurationFailed(String)

    var errorDescription: String? {
        switch self {
        case .deviceUnavailable:
            return "Gerät wurde getrennt oder ist nicht mehr erreichbar. Kabel/Adapter prüfen (und, falls es sich um ein direkt verbundenes iPhone/iPad handelt, am Gerät \u{201E}Diesem Computer vertrauen\u{201C} bestätigen)."
        case .inputUnavailable:
            return "Videoeingang konnte nicht hinzugefügt werden."
        case .configurationFailed(let message):
            return message
        }
    }
}

/// Captures video from one USB-connected external device via
/// `AVCaptureSession` — no network dependency at all, so it works on
/// machines where network-based mirroring would be blocked by policy. In
/// practice this is almost always a USB HDMI capture dongle fed by a
/// Lightning/USB-C → HDMI adapter cable from an iPhone/iPad — see
/// `USBiOSDiscovery`'s doc comment for why a directly-connected iPhone/iPad
/// (no adapter) no longer works on current macOS.
///
/// `AVCaptureSession` already decodes the video itself, so display is just
/// an `AVCaptureVideoPreviewLayer` bound to the session — no manual
/// H.264/CoreMedia handling needed. There is also no back-channel here:
/// `AVCaptureSession` gives us video (and mic audio, unused) only, not
/// touch/keyboard input.
final class USBiOSCaptureSession: ObservableObject {
    let uniqueID: String
    let displayName: String
    let captureSession = AVCaptureSession()
    let previewLayer: AVCaptureVideoPreviewLayer

    @Published private(set) var isConnected = false
    @Published private(set) var isWaiting = false
    @Published private(set) var lastError: String?
    @Published private(set) var videoSize: CGSize = .zero

    private let sessionQueue = DispatchQueue(label: "adbscreen.usbios.session")
    private var deviceInput: AVCaptureDeviceInput?
    private var formatObservation: NSKeyValueObservation?
    private var runtimeErrorObserver: NSObjectProtocol?
    private var portFormatObservers: [NSObjectProtocol] = []
    private var stopped = false

    private static let registryLock = NSLock()
    private static var activeSessions = NSHashTable<USBiOSCaptureSession>.weakObjects()

    static func stopAll() {
        registryLock.lock()
        let sessions = activeSessions.allObjects
        registryLock.unlock()
        for session in sessions { session.stop() }
    }

    init(uniqueID: String, displayName: String) {
        self.uniqueID = uniqueID
        self.displayName = displayName
        self.previewLayer = AVCaptureVideoPreviewLayer(session: captureSession)
        previewLayer.videoGravity = .resizeAspect
    }

    func start() {
        stopped = false
        Self.registryLock.lock()
        Self.activeSessions.add(self)
        Self.registryLock.unlock()

        isWaiting = true
        lastError = nil

        let observer = NotificationCenter.default.addObserver(
            forName: .AVCaptureSessionRuntimeError,
            object: captureSession,
            queue: .main
        ) { [weak self] notification in
            guard let self, !self.stopped else { return }
            let error = notification.userInfo?[AVCaptureSessionErrorKey] as? Error
            self.lastError = error?.localizedDescription ?? "Die USB-Verbindung wurde unerwartet unterbrochen."
            self.isConnected = false
            self.isWaiting = false
        }
        runtimeErrorObserver = observer

        sessionQueue.async { [weak self] in
            self?.configureAndStart()
        }
    }

    func stop() {
        stopped = true
        if let runtimeErrorObserver {
            NotificationCenter.default.removeObserver(runtimeErrorObserver)
        }
        runtimeErrorObserver = nil
        portFormatObservers.forEach(NotificationCenter.default.removeObserver)
        portFormatObservers = []
        formatObservation = nil
        let session = captureSession
        sessionQueue.async {
            session.stopRunning()
        }
        deviceInput = nil
        isConnected = false
        isWaiting = false
        Self.registryLock.lock()
        Self.activeSessions.remove(self)
        Self.registryLock.unlock()
    }

    // MARK: - Setup (background queue)

    private func configureAndStart() {
        guard let device = AVCaptureDevice(uniqueID: uniqueID) else {
            report(USBiOSCaptureError.deviceUnavailable)
            return
        }

        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
            captureSession.beginConfiguration()
            if let existing = deviceInput {
                captureSession.removeInput(existing)
            }
            guard captureSession.canAddInput(input) else {
                captureSession.commitConfiguration()
                report(USBiOSCaptureError.inputUnavailable)
                return
            }
            captureSession.addInput(input)
            deviceInput = input
            captureSession.commitConfiguration()
        } catch {
            report(USBiOSCaptureError.configurationFailed(error.localizedDescription))
            return
        }

        observeFormat(of: device, input: input)
        captureSession.startRunning()

        DispatchQueue.main.async { [weak self] in
            guard let self, !self.stopped else { return }
            self.isWaiting = false
            self.isConnected = true
            self.lastError = nil
        }
    }

    /// Two sources, because neither covers every device:
    /// - `activeFormat` (KVO) works for plain video devices like HDMI
    ///   capture dongles.
    /// - A directly connected iPhone/iPad is a `.muxed` device whose
    ///   `activeFormat` always reports 0×0. Its real frame size only shows
    ///   up on the input's video port once the stream is running (and
    ///   changes again on rotation), announced via
    ///   `formatDescriptionDidChangeNotification`.
    private func observeFormat(of device: AVCaptureDevice, input: AVCaptureDeviceInput) {
        updateVideoSize(from: device.activeFormat.formatDescription)
        formatObservation = device.observe(\.activeFormat, options: [.new]) { [weak self] device, _ in
            self?.updateVideoSize(from: device.activeFormat.formatDescription)
        }

        let videoPorts = input.ports.filter { $0.mediaType == .video }
        let observers = videoPorts.map { port in
            NotificationCenter.default.addObserver(
                forName: AVCaptureInput.Port.formatDescriptionDidChangeNotification,
                object: port,
                queue: nil
            ) { [weak self] _ in
                guard let formatDescription = port.formatDescription else { return }
                self?.updateVideoSize(from: formatDescription)
            }
        }
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.stopped else {
                observers.forEach(NotificationCenter.default.removeObserver)
                return
            }
            self.portFormatObservers.forEach(NotificationCenter.default.removeObserver)
            self.portFormatObservers = observers
        }
        for port in videoPorts {
            if let formatDescription = port.formatDescription {
                updateVideoSize(from: formatDescription)
            }
        }
    }

    private func updateVideoSize(from formatDescription: CMFormatDescription) {
        let dimensions = CMVideoFormatDescriptionGetDimensions(formatDescription)
        let size = CGSize(width: Int(dimensions.width), height: Int(dimensions.height))
        guard size != .zero else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.videoSize != size else { return }
            self.videoSize = size
        }
    }

    private func report(_ error: Error) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isWaiting = false
            self.isConnected = false
            if !self.stopped {
                self.lastError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            }
        }
    }
}
