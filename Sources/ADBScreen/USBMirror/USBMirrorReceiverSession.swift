import AVFoundation
import CoreMedia
import Foundation

enum USBMirrorReceiverError: Error, LocalizedError {
    case helperNotFound
    case helperExited(String)

    var errorDescription: String? {
        switch self {
        case .helperNotFound:
            return "USB-Mirroring-Hilfsprogramm fehlt im App-Bundle."
        case .helperExited(let message):
            guard !message.isEmpty else {
                return "USB-Mirroring wurde unerwartet beendet."
            }
            if Self.isKnownActivationFailure(message) {
                return """
                Das iPhone/iPad wurde erkannt, aber macOS verweigert die \
                Aktivierung des Bildschirm-Streamings über USB (\(message)). \
                Das ist eine bekannte, bislang ungelöste Einschränkung der \
                privaten Apple-USB-Schnittstelle auf aktuellen macOS-Versionen \
                (nicht spezifisch für dieses Gerät) – vermutlich blockiert \
                usbmuxd/AMDS die nötige USB-Konfiguration. Zuverlässige \
                Alternative: ein Lightning/USB-C-zu-HDMI-Adapter zusammen mit \
                einem USB-HDMI-Capture-Dongle.
                """
            }
            return message
        }
    }

    /// Recognizes the specific libusb/config-switch failure signatures this
    /// helper's retries always bottom out on (see vendor/qvh-src/ADBSCREEN_NOTES.md)
    /// so the UI can explain the known limitation instead of just showing a
    /// raw, unhelpful libusb error code.
    private static func isKnownActivationFailure(_ message: String) -> Bool {
        message.contains("Could not retrieve config") || message.contains("code -99")
    }
}

/// Mirrors a USB-connected iPhone/iPad's screen without AirPlay/Wi-Fi, for
/// environments where AirPlay is disabled by policy (e.g. managed
/// corporate Macs).
///
/// Apple has no *public, documented* API for this either — QuickTime
/// Player's "record iPhone screen via USB cable" feature relies on a
/// private mechanism (macOS's `com.apple.cmio.iOSScreenCaptureAssistant`):
/// the device switches to a hidden alternate USB configuration ("QuickTime
/// X config") that exposes a couple of raw bulk endpoints carrying H.264 +
/// PCM `CMSampleBuffer`s. That protocol has been reverse-engineered and
/// published as open source (MIT) by github.com/danielpaulus/quicktime_video_hack;
/// see vendor/qvh-src for the vendored copy and ADBScreen's additions on
/// top of it (docs there explain a couple of macOS-specific stability
/// patches around libusb context reuse).
///
/// Spawns a bundled helper binary (`adbscreen-usbmirror-helper`, built from
/// vendor/qvh-src/cmd/adbscreen-usbmirror-helper) that talks to the device
/// over `libusb` and forwards frames to us over the exact same
/// Unix-socket wire format as `adbscreen-airplay-helper`
/// (1-byte type tag, 4-byte BE length, payload — type 0 is a video frame,
/// type 1 is the device name), so the decoding side below is intentionally
/// almost identical to `AirPlayReceiverSession`.
///
/// Known limitation: on some Macs the final USB interface claim can fail
/// because macOS's own `usbmuxd`/AMDS device-management daemons may hold
/// the interface; the helper retries several times, and this session
/// surfaces whatever error message it ultimately gives up with.
final class USBMirrorReceiverSession: ObservableObject {
    let displayLayer = AVSampleBufferDisplayLayer()

    /// True once real video frames are flowing (an iPhone is mirroring).
    @Published private(set) var isConnected = false
    /// True while the helper is up and waiting for/activating a device.
    @Published private(set) var isWaiting = false
    @Published private(set) var lastError: String?
    @Published private(set) var videoSize: CGSize = .zero
    @Published private(set) var deviceName: String?

    private static let registryLock = NSLock()
    private static var activeSessions = NSHashTable<USBMirrorReceiverSession>.weakObjects()

    static func stopAll() {
        registryLock.lock()
        let sessions = activeSessions.allObjects
        registryLock.unlock()
        for session in sessions { session.stop() }
    }

    private let socketPath: String
    private var helperProcess: Process?
    private var listener: UnixSocketListener?
    private var clientSocket: TCPSocket?
    private var stopped = false

    private var formatDescription: CMVideoFormatDescription?
    private var pendingSPS: [UInt8]?
    private var pendingPPS: [UInt8]?

    init() {
        self.socketPath = "/tmp/adbscreen-usbmirror-\(UUID().uuidString.prefix(8)).sock"
    }

    func start() {
        stopped = false
        Self.registryLock.lock()
        Self.activeSessions.add(self)
        Self.registryLock.unlock()

        let thread = Thread { [weak self] in
            self?.run()
        }
        thread.name = "adbscreen.usbmirror.session"
        thread.start()
    }

    func stop() {
        stopped = true
        clientSocket?.close()
        listener?.stop()
        helperProcess?.terminate()
        Self.registryLock.lock()
        Self.activeSessions.remove(self)
        Self.registryLock.unlock()
    }

    // MARK: - Setup

    private func run() {
        do {
            guard let helperPath = Bundle.main.path(forResource: "adbscreen-usbmirror-helper", ofType: nil) else {
                throw USBMirrorReceiverError.helperNotFound
            }

            let listener = UnixSocketListener(path: socketPath)
            try listener.start()
            self.listener = listener

            let process = Process()
            process.executableURL = URL(fileURLWithPath: helperPath)
            var env = ProcessInfo.processInfo.environment
            env["ADBSCREEN_VIDEO_SOCK"] = socketPath
            process.environment = env

            let errPipe = Pipe()
            process.standardError = errPipe
            process.standardOutput = FileHandle.nullDevice

            process.terminationHandler = { [weak self] proc in
                guard let self else { return }
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                let message = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !self.stopped {
                    DispatchQueue.main.async {
                        self.lastError = USBMirrorReceiverError.helperExited(
                            message.isEmpty ? "Beendet mit Code \(proc.terminationStatus)." : message
                        ).errorDescription
                        self.isWaiting = false
                        self.isConnected = false
                    }
                }
                self.listener?.stop() // unblocks a pending accept()
            }

            try process.run()
            self.helperProcess = process

            DispatchQueue.main.async { self.isWaiting = true }

            let client = try listener.acceptOnce()
            self.clientSocket = client

            pumpVideo(client)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            DispatchQueue.main.async {
                self.isWaiting = false
                self.isConnected = false
                if !self.stopped { self.lastError = message }
            }
            teardown()
        }
    }

    // MARK: - Video pump
    // Identical wire format/parsing to AirPlayReceiverSession.pumpVideo —
    // see that file's doc comments for details on the type tags.

    private func pumpVideo(_ socket: TCPSocket) {
        do {
            while !stopped {
                let typeByte = try socket.readExact(1)[0]
                let header = try socket.readExact(4)
                let len = Int(BE.u32(header, 0))
                guard len > 0 else { continue }
                let payload = try socket.readExact(len)
                switch typeByte {
                case 1:
                    handleDeviceName(payload)
                default:
                    handleFrame(payload)
                }
            }
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            DispatchQueue.main.async {
                self.isConnected = false
                if !self.stopped { self.lastError = message }
            }
        }
        teardown()
    }

    private func handleDeviceName(_ payload: [UInt8]) {
        guard let name = String(bytes: payload, encoding: .utf8), !name.isEmpty else { return }
        DispatchQueue.main.async {
            self.deviceName = name
        }
    }

    private func handleFrame(_ payload: [UInt8]) {
        let nalRanges = H264AnnexB.splitNALUnits(payload)
        guard !nalRanges.isEmpty else { return }

        var vclRanges: [Range<Int>] = []
        var paramSetsUpdated = false
        for range in nalRanges {
            switch H264AnnexB.nalType(payload, range) {
            case 7: pendingSPS = Array(payload[range]); paramSetsUpdated = true
            case 8: pendingPPS = Array(payload[range]); paramSetsUpdated = true
            case 6, 9: break // SEI / AUD — not needed for decoding
            default: vclRanges.append(range)
            }
        }

        if paramSetsUpdated, let sps = pendingSPS, let pps = pendingPPS,
           let fmt = H264CoreMedia.makeFormatDescription(sps: sps, pps: pps) {
            formatDescription = fmt
            let dims = CMVideoFormatDescriptionGetDimensions(fmt)
            let size = CGSize(width: Int(dims.width), height: Int(dims.height))
            DispatchQueue.main.async {
                if size != self.videoSize { self.videoSize = size }
            }
        }

        guard let fmt = formatDescription, !vclRanges.isEmpty else { return }
        let isKeyFrame = vclRanges.contains { H264AnnexB.nalType(payload, $0) == 5 }
        let avcc = H264AnnexB.annexBToAVCC(payload, nalRanges: vclRanges)
        let pts = CMClockGetTime(CMClockGetHostTimeClock())
        guard let sample = H264CoreMedia.makeSampleBuffer(avccData: avcc, formatDescription: fmt, isKeyFrame: isKeyFrame, presentationTimeStamp: pts) else { return }

        DispatchQueue.main.async {
            self.isWaiting = false
            self.isConnected = true
            if self.displayLayer.status == .failed {
                self.displayLayer.flush()
            }
            self.displayLayer.enqueue(sample)
        }
    }

    private func teardown() {
        clientSocket?.close()
        listener?.stop()
        helperProcess?.terminate()
        Self.registryLock.lock()
        Self.activeSessions.remove(self)
        Self.registryLock.unlock()
    }
}
