import AppKit
import AVFoundation
import CoreMedia
import Foundation

enum ScrcpyError: Error, LocalizedError {
    case cancelled
    case connectTimeout
    case unsupportedCodec
    case serverJarMissing

    var errorDescription: String? {
        switch self {
        case .cancelled: return "Verbindung abgebrochen"
        case .connectTimeout: return "Zeitüberschreitung beim Verbindungsaufbau zum scrcpy-Server"
        case .unsupportedCodec: return "Nicht unterstützter Video-Codec"
        case .serverJarMissing: return "scrcpy-server konnte nicht im App-Bundle gefunden werden"
        }
    }
}

/// Drives one scrcpy server instance on an Android device: pushes the
/// server jar, launches it over `adb shell`, connects the video + control
/// sockets through an `adb forward` tunnel, decodes the H.264 stream into
/// an AVSampleBufferDisplayLayer, and forwards touch/key input back.
final class ScrcpySession: ObservableObject {
    let device: AndroidDevice
    let displayLayer = AVSampleBufferDisplayLayer()

    @Published private(set) var isConnected = false
    @Published private(set) var lastError: String?
    @Published private(set) var videoSize: CGSize = .zero
    @Published private(set) var isRecording = false
    @Published private(set) var recordingError: String?

    // scrcpy-equivalent device toggles (--show-touches, --stay-awake,
    // screen-off-while-mirroring). Both settings toggles remember the
    // device's original value so disabling them / disconnecting restores
    // exactly what was there before, instead of just forcing it off.
    @Published private(set) var showTouchesEnabled = false
    @Published private(set) var stayAwakeEnabled = false
    @Published private(set) var isScreenOff = false
    private var originalShowTouchesValue: String?
    private var originalStayAwakeValue: String?

    // The server parses scid with Java's `Integer.parseInt(str, 16)`, which
    // rejects values above Int32.max — keep the top bit clear.
    private let scid = UInt32.random(in: 0...0x7FFF_FFFF)
    private var localPort: UInt16 = 0
    private var serverProcess: Process?
    private var videoSocket: TCPSocket?
    private var controlSocket: TCPSocket?
    private var formatDescription: CMVideoFormatDescription?
    private var stopped = false
    private let controlQueue = DispatchQueue(label: "adbscreen.scrcpy.control")
    private var recorder: MP4Recorder?
    private var pendingRecordingURL: URL?

    // Clipboard sync: scrcpy's server has clipboard_autosync on by default,
    // so device→Mac just means reading DEVICE_MSG_TYPE_CLIPBOARD off the
    // control socket. Mac→device has no push notification for pasteboard
    // changes, so it's polled. `lastKnownClipboardText` is the dedup point
    // that stops the two directions from ping-ponging the same change back
    // and forth forever.
    private var lastKnownClipboardText: String?
    private var lastPasteboardChangeCount = NSPasteboard.general.changeCount
    private var pasteboardTimer: Timer?

    private static let serverVersion = "4.1"
    private static let deviceServerPath = "/data/local/tmp/scrcpy-server.jar"

    private var scidHex: String { String(format: "%08x", scid) }
    private var socketName: String { "scrcpy_\(scidHex)" }

    // Tracks every live session so we can force-stop them (and, crucially,
    // remove their adb forwards) from applicationWillTerminate — SwiftUI's
    // onDisappear is not guaranteed to fire in time for a Cmd+Q quit.
    private static let registryLock = NSLock()
    private static var activeSessions = NSHashTable<ScrcpySession>.weakObjects()

    static func stopAll() {
        registryLock.lock()
        let sessions = activeSessions.allObjects
        registryLock.unlock()
        for session in sessions { session.stop() }
    }

    init(device: AndroidDevice) {
        self.device = device
    }

    func start() {
        stopped = false
        Self.registryLock.lock()
        Self.activeSessions.add(self)
        Self.registryLock.unlock()

        let thread = Thread { [weak self] in
            self?.runSetupAndPump()
        }
        thread.name = "adbscreen.scrcpy.session.\(device.serial)"
        thread.start()
    }

    func stop() {
        stopped = true
        videoSocket?.close()
        controlSocket?.close()
        serverProcess?.terminate()
        DispatchQueue.main.async { self.pasteboardTimer?.invalidate() }
        restoreDeviceSettings()
        if localPort != 0 {
            ADB.shared.removeForward(serial: device.serial, localPort: localPort)
        }
        if let activeRecorder = recorder {
            recorder = nil
            DispatchQueue.main.async { self.isRecording = false }
            activeRecorder.stop { _ in }
        }
        Self.registryLock.lock()
        Self.activeSessions.remove(self)
        Self.registryLock.unlock()
    }

    func send(_ message: [UInt8]) {
        guard let socket = controlSocket, isConnected else { return }
        controlQueue.async {
            try? socket.write(message)
        }
    }

    // MARK: - scrcpy-equivalent device toggles

    /// Mirrors `scrcpy --show-touches`: flips Android's "Show taps"
    /// developer option so finger/mouse taps are drawn as visible circles
    /// on the mirrored screen itself (a device-side overlay, not something
    /// we render on the Mac).
    func setShowTouches(_ enabled: Bool) {
        guard enabled != showTouchesEnabled else { return }
        showTouchesEnabled = enabled
        let serial = device.serial
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            if enabled {
                self.originalShowTouchesValue = ADB.shared.getSetting(serial: serial, namespace: "system", key: "show_touches")
                ADB.shared.putSetting(serial: serial, namespace: "system", key: "show_touches", value: "1")
            } else {
                ADB.shared.putSetting(serial: serial, namespace: "system", key: "show_touches", value: self.originalShowTouchesValue ?? "0")
            }
        }
    }

    /// Mirrors `scrcpy --stay-awake`: flips "Stay awake while charging" so
    /// the device screen doesn't time out and lock mid-demo. Restored to
    /// its original value on disable/disconnect.
    func setStayAwake(_ enabled: Bool) {
        guard enabled != stayAwakeEnabled else { return }
        stayAwakeEnabled = enabled
        let serial = device.serial
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            if enabled {
                self.originalStayAwakeValue = ADB.shared.getSetting(serial: serial, namespace: "global", key: "stay_on_while_plugged_in")
                ADB.shared.putSetting(serial: serial, namespace: "global", key: "stay_on_while_plugged_in", value: "3")
            } else {
                ADB.shared.putSetting(serial: serial, namespace: "global", key: "stay_on_while_plugged_in", value: self.originalStayAwakeValue ?? "0")
            }
        }
    }

    /// Blanks (or wakes) the device's physical screen via scrcpy's
    /// SET_DISPLAY_POWER control message while the mirror keeps streaming —
    /// handy for privacy during a demo without disconnecting.
    func toggleScreenPower() {
        isScreenOff.toggle()
        send(ScrcpyControlMessage.setDisplayPower(on: !isScreenOff))
    }

    /// Restores any settings this session changed, so disconnecting never
    /// leaves the physical device in an altered state.
    private func restoreDeviceSettings() {
        guard showTouchesEnabled || stayAwakeEnabled else { return }
        let serial = device.serial
        let showTouchesEnabled = self.showTouchesEnabled
        let stayAwakeEnabled = self.stayAwakeEnabled
        let originalShowTouches = self.originalShowTouchesValue
        let originalStayAwake = self.originalStayAwakeValue
        DispatchQueue.global(qos: .utility).async {
            if showTouchesEnabled {
                ADB.shared.putSetting(serial: serial, namespace: "system", key: "show_touches", value: originalShowTouches ?? "0")
            }
            if stayAwakeEnabled {
                ADB.shared.putSetting(serial: serial, namespace: "global", key: "stay_on_while_plugged_in", value: originalStayAwake ?? "0")
            }
        }
    }

    /// Recording starts as soon as the next keyframe arrives on the pump
    /// thread (an MP4 can't open on a mid-GOP frame), so there's a short,
    /// expected delay between calling this and `isRecording` flipping true.
    /// Records to a temp file — the caller asks where to actually save it
    /// only after `stopRecording` finishes, not up front. If no keyframe
    /// shows up within a few seconds (scrcpy connection stalled, etc.) this
    /// gives up and surfaces `recordingError` instead of hanging silently.
    func startRecording() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("adbscreen-\(UUID().uuidString).mp4")
        pendingRecordingURL = url
        DispatchQueue.main.async { self.recordingError = nil }
        // scrcpy only emits a keyframe on its own schedule (typically just
        // once, at connect), so without a nudge a keyframe might not show
        // up for a long time (or ever) after the user hits record. Ask the
        // device encoder to reset now so a fresh SPS/PPS+IDR arrives right
        // away and recording can actually begin (SC_CONTROL_MSG_TYPE_RESET_VIDEO).
        send(ScrcpyControlMessage.simple(.resetVideo))
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self, self.pendingRecordingURL == url else { return }
            self.pendingRecordingURL = nil
            self.recordingError = "Kein Video-Keyframe empfangen — Aufnahme konnte nicht gestartet werden."
        }
    }

    /// Completion (always called on the main thread) receives the temp
    /// file's URL on success, or nil if nothing was actually recording.
    func stopRecording(completion: @escaping (URL?) -> Void) {
        guard let activeRecorder = recorder else {
            // Stopped before the requested keyframe ever arrived, so there's
            // nothing to save. Surface this instead of failing silently —
            // previously the UI just dropped back to idle with no feedback.
            let wasArming = pendingRecordingURL != nil
            pendingRecordingURL = nil
            DispatchQueue.main.async {
                if wasArming {
                    self.recordingError = "Aufnahme wurde beendet, bevor sie starten konnte — kein Video-Keyframe empfangen."
                }
                completion(nil)
            }
            return
        }
        recorder = nil
        DispatchQueue.main.async { self.isRecording = false }
        activeRecorder.stop { result in
            switch result {
            case .success:
                completion(activeRecorder.outputURL)
            case .failure(let error):
                self.recordingError = error.localizedDescription
                completion(nil)
            }
        }
    }

    // MARK: - Setup

    private func runSetupAndPump() {
        do {
            guard let serverJarPath = Bundle.main.path(forResource: "scrcpy-server", ofType: nil) else {
                throw ScrcpyError.serverJarMissing
            }
            try ADB.shared.push(serial: device.serial, localPath: serverJarPath, remotePath: Self.deviceServerPath)

            let remote = "localabstract:\(socketName)"
            localPort = try ADB.shared.forwardToFreePort(serial: device.serial, remote: remote)

            serverProcess = try ADB.shared.spawn([
                "-s", device.serial, "shell",
                "CLASSPATH=\(Self.deviceServerPath)",
                "app_process", "/", "com.genymobile.scrcpy.Server", Self.serverVersion,
                "scid=\(scidHex)",
                "log_level=info",
                "audio=false",
                "control=true",
                "cleanup=true",
                "tunnel_forward=true",
                "video_bit_rate=8000000",
                "max_size=1600",
            ])

            let video = TCPSocket()
            try connectWithRetry(video, consumeDummyByte: true)

            let control = TCPSocket()
            try control.connect(port: localPort, timeout: 2)

            // The 64-byte device name is only sent once, on the first
            // socket the server accepted (the video socket here).
            _ = try video.readExact(64)

            self.videoSocket = video
            self.controlSocket = control

            DispatchQueue.main.async {
                self.isConnected = true
                self.lastError = nil
                self.startClipboardSync()
            }

            let controlPumpThread = Thread { [weak self] in
                self?.pumpControlMessages(control)
            }
            controlPumpThread.name = "adbscreen.scrcpy.session.\(device.serial).control"
            controlPumpThread.start()

            pumpVideo(video)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            DispatchQueue.main.async {
                self.isConnected = false
                if !self.stopped { self.lastError = message }
            }
            teardown()
        }
    }

    private func connectWithRetry(_ socket: TCPSocket, consumeDummyByte: Bool) throws {
        var lastFailure: Error?
        for _ in 0..<80 {
            if stopped { throw ScrcpyError.cancelled }
            do {
                try socket.connect(port: localPort, timeout: 1)
                if consumeDummyByte {
                    _ = try socket.readExact(1)
                }
                return
            } catch {
                lastFailure = error
                socket.close()
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
        throw lastFailure ?? ScrcpyError.connectTimeout
    }

    // MARK: - Clipboard sync

    /// Must be called on the main thread — Timer needs a run loop.
    private func startClipboardSync() {
        lastPasteboardChangeCount = NSPasteboard.general.changeCount
        pasteboardTimer?.invalidate()
        pasteboardTimer = Timer.scheduledTimer(withTimeInterval: 0.75, repeats: true) { [weak self] _ in
            self?.checkPasteboard()
        }
    }

    private func checkPasteboard() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastPasteboardChangeCount else { return }
        lastPasteboardChangeCount = pb.changeCount
        guard let text = pb.string(forType: .string), !text.isEmpty, text != lastKnownClipboardText else { return }
        lastKnownClipboardText = text
        send(ScrcpyControlMessage.setClipboard(text: text))
    }

    /// Called from the control-message pump thread when the device reports
    /// a clipboard change (scrcpy's `clipboard_autosync`, on by default).
    private func handleIncomingClipboard(_ text: String) {
        guard text != lastKnownClipboardText else { return }
        lastKnownClipboardText = text
        DispatchQueue.main.async {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(text, forType: .string)
            self.lastPasteboardChangeCount = pb.changeCount
        }
    }

    /// Reads scrcpy's device→host messages (see device_msg.h): only
    /// DEVICE_MSG_TYPE_CLIPBOARD is acted on; the others are parsed just
    /// enough to stay aligned on the shared control socket's byte stream.
    private func pumpControlMessages(_ socket: TCPSocket) {
        do {
            while !stopped {
                let typeByte = try socket.readExact(1)
                switch typeByte[0] {
                case 0: // DEVICE_MSG_TYPE_CLIPBOARD
                    let lenBytes = try socket.readExact(4)
                    let len = Int(BE.u32(lenBytes, 0))
                    let textBytes = try socket.readExact(len)
                    handleIncomingClipboard(String(decoding: textBytes, as: UTF8.self))
                case 1: // DEVICE_MSG_TYPE_ACK_CLIPBOARD
                    _ = try socket.readExact(8)
                case 2: // DEVICE_MSG_TYPE_UHID_OUTPUT
                    let idAndSize = try socket.readExact(4)
                    let size = Int(BE.u16(idAndSize, 2))
                    if size > 0 { _ = try socket.readExact(size) }
                default:
                    return // unknown message type — can't safely resync
                }
            }
        } catch {
            // Video pump owns error/disconnect reporting; this socket
            // closing is expected once the session stops or disconnects.
        }
    }

    // MARK: - Video pump

    private func pumpVideo(_ socket: TCPSocket) {
        do {
            let codecIdBytes = try socket.readExact(4)
            let codecId = BE.u32(codecIdBytes, 0)
            guard codecId == 0x6832_3634 else { // "h264"
                throw ScrcpyError.unsupportedCodec
            }

            var pendingSPS: [UInt8]?
            var pendingPPS: [UInt8]?

            while !stopped {
                let header = try socket.readExact(12)

                if header[0] & 0x80 != 0 {
                    let width = BE.u32(header, 4)
                    let height = BE.u32(header, 8)
                    DispatchQueue.main.async {
                        self.videoSize = CGSize(width: Int(width), height: Int(height))
                    }
                    continue
                }

                let ptsFlags = BE.u64(header, 0)
                let isConfig = (ptsFlags & (UInt64(1) << 62)) != 0
                let isKeyFrame = (ptsFlags & (UInt64(1) << 61)) != 0
                let len = Int(BE.u32(header, 8))
                guard len > 0 else { continue }
                let payload = try socket.readExact(len)

                let nalRanges = H264AnnexB.splitNALUnits(payload)

                if isConfig {
                    for range in nalRanges {
                        switch H264AnnexB.nalType(payload, range) {
                        case 7: pendingSPS = Array(payload[range])
                        case 8: pendingPPS = Array(payload[range])
                        default: break
                        }
                    }
                    if let sps = pendingSPS, let pps = pendingPPS {
                        formatDescription = H264CoreMedia.makeFormatDescription(sps: sps, pps: pps)
                    }
                    continue
                }

                guard let fmt = formatDescription, !nalRanges.isEmpty else { continue }
                let avcc = H264AnnexB.annexBToAVCC(payload, nalRanges: nalRanges)
                let pts = CMClockGetTime(CMClockGetHostTimeClock())
                if let sample = H264CoreMedia.makeSampleBuffer(avccData: avcc, formatDescription: fmt, isKeyFrame: isKeyFrame, presentationTimeStamp: pts) {
                    if let pendingURL = pendingRecordingURL, isKeyFrame {
                        do {
                            let rec = MP4Recorder(outputURL: pendingURL)
                            try rec.start(formatDescription: fmt)
                            recorder = rec
                            pendingRecordingURL = nil
                            DispatchQueue.main.async { self.isRecording = true }
                        } catch {
                            pendingRecordingURL = nil
                            let message = error.localizedDescription
                            DispatchQueue.main.async { self.recordingError = message }
                        }
                    }
                    recorder?.append(sample)

                    DispatchQueue.main.async {
                        if self.displayLayer.status == .failed {
                            self.displayLayer.flush()
                        }
                        self.displayLayer.enqueue(sample)
                    }
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

    private func teardown() {
        videoSocket?.close()
        controlSocket?.close()
        serverProcess?.terminate()
        DispatchQueue.main.async { self.pasteboardTimer?.invalidate() }
        restoreDeviceSettings()
        if localPort != 0 {
            ADB.shared.removeForward(serial: device.serial, localPort: localPort)
        }
        if let activeRecorder = recorder {
            recorder = nil
            DispatchQueue.main.async { self.isRecording = false }
            activeRecorder.stop { _ in }
        }
        Self.registryLock.lock()
        Self.activeSessions.remove(self)
        Self.registryLock.unlock()
    }

}
