import AVFoundation
import CoreMedia
import Foundation

enum AirPlayReceiverError: Error, LocalizedError {
    case helperNotFound
    case helperExited(String)

    var errorDescription: String? {
        switch self {
        case .helperNotFound:
            return "AirPlay-Empfänger-Hilfsprogramm fehlt im App-Bundle."
        case .helperExited(let message):
            return message.isEmpty ? "AirPlay-Empfänger wurde unerwartet beendet." : message
        }
    }
}

/// Turns this Mac into an AirPlay Mirroring receiver so an iPhone/iPad can
/// mirror its screen into the app, the same way Vysor's iOS support works.
/// Apple provides no public USB screen-capture API, so this is the only
/// path to embedded iOS screen mirroring.
///
/// Spawns a bundled helper binary (a fork of UxPlay — an open-source
/// AirPlay receiver — with its GStreamer rendering replaced by a raw
/// Unix-socket writer; see vendor/uxplay-src/renderers/). All AirPlay
/// protocol/crypto/pairing work happens in that separate process; this
/// class just decodes the H.264 elementary stream it forwards to us and
/// renders it via VideoToolbox/AVSampleBufferDisplayLayer.
///
/// No video recording here (unlike ScrcpySession): AirPlay Mirroring has no
/// back-channel to the device at all — confirmed by inspecting every send
/// path in the vendored UxPlay source — so there's no way to request a
/// fresh keyframe on demand, and one otherwise only appears when a mirror
/// session starts or the screen's resolution/orientation changes. That
/// makes an on-demand "start recording" button structurally unreliable, so
/// it was cut rather than shipped as a feature that silently hangs or needs
/// a screen rotation to work.
final class AirPlayReceiverSession: ObservableObject {
    let displayLayer = AVSampleBufferDisplayLayer()
    let serviceName: String

    /// True once real video frames are flowing (an iPhone is mirroring).
    @Published private(set) var isConnected = false
    /// True while the receiver is up and advertised, before any client mirrors.
    @Published private(set) var isWaiting = false
    @Published private(set) var lastError: String?
    @Published private(set) var videoSize: CGSize = .zero
    /// The connected sender's device name (e.g. "iPhone 15"), as reported by
    /// the AirPlay client during the RTSP handshake and forwarded to us by
    /// the helper over the same Unix socket as the video. `nil` until a
    /// client has actually connected and announced itself.
    @Published private(set) var deviceName: String?

    private static let registryLock = NSLock()
    private static var activeSessions = NSHashTable<AirPlayReceiverSession>.weakObjects()

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

    init(serviceName: String = "ADBScreen") {
        self.serviceName = serviceName
        self.socketPath = "/tmp/adbscreen-airplay-\(UUID().uuidString.prefix(8)).sock"
    }

    func start() {
        stopped = false
        Self.registryLock.lock()
        Self.activeSessions.add(self)
        Self.registryLock.unlock()

        let thread = Thread { [weak self] in
            self?.run()
        }
        thread.name = "adbscreen.airplay.session"
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
            guard let helperPath = Bundle.main.path(forResource: "adbscreen-airplay-helper", ofType: nil) else {
                throw AirPlayReceiverError.helperNotFound
            }

            let listener = UnixSocketListener(path: socketPath)
            try listener.start()
            self.listener = listener

            let process = Process()
            process.executableURL = URL(fileURLWithPath: helperPath)
            process.arguments = ["-n", serviceName]
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
                        self.lastError = AirPlayReceiverError.helperExited(
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

    private func pumpVideo(_ socket: TCPSocket) {
        do {
            while !stopped {
                // Wire format: 1-byte type tag, 4-byte BE length, payload.
                // Type 0x00 is a video frame, 0x01 is a UTF-8 device name
                // (see the doc comment in the vendored video_renderer.c).
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
