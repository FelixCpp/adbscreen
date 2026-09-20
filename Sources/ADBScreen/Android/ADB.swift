import Foundation

struct AndroidDevice: Identifiable, Hashable {
    let serial: String
    var model: String
    var state: String // "device", "unauthorized", "offline"

    var id: String { serial }
    var isReady: Bool { state == "device" }
}

enum ADBError: Error, LocalizedError {
    case binaryNotFound
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .binaryNotFound:
            return "adb wurde nicht gefunden. Installiere es z. B. mit: brew install android-platform-tools"
        case .commandFailed(let msg):
            return msg
        }
    }
}

/// Thin wrapper around the `adb` command line tool (Android Debug Bridge).
/// We shell out rather than reimplementing the ADB host protocol, since the
/// server jar push/exec/forward primitives it gives us are exactly what
/// scrcpy's own client uses.
final class ADB {
    static let shared = ADB()

    private(set) var executablePath: String?

    init() {
        executablePath = ADB.locateBinary()
    }

    /// Re-locates the adb binary. `executablePath` is otherwise only
    /// resolved once at launch, so this lets a manual refresh pick up adb
    /// having been installed after the app was already running.
    func refreshExecutablePath() {
        executablePath = ADB.locateBinary()
    }

    private static func locateBinary() -> String? {
        let candidates = [
            "/opt/homebrew/bin/adb",
            "/usr/local/bin/adb",
            (ProcessInfo.processInfo.environment["ANDROID_HOME"].map { "\($0)/platform-tools/adb" }) ?? "",
            (ProcessInfo.processInfo.environment["ANDROID_SDK_ROOT"].map { "\($0)/platform-tools/adb" }) ?? "",
            NSString(string: "~/Library/Android/sdk/platform-tools/adb").expandingTildeInPath,
        ]
        for path in candidates where !path.isEmpty {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        // Fall back to PATH resolution via `/usr/bin/env`.
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        task.arguments = ["which", "adb"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !path.isEmpty {
                return path
            }
        } catch {
            return nil
        }
        return nil
    }

    @discardableResult
    func run(_ arguments: [String], timeout: TimeInterval = 10) throws -> String {
        guard let exe = executablePath else { throw ADBError.binaryNotFound }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: exe)
        task.arguments = arguments

        let outPipe = Pipe()
        let errPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = errPipe

        try task.run()
        task.waitUntilExit()

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        let out = String(data: outData, encoding: .utf8) ?? ""
        let err = String(data: errData, encoding: .utf8) ?? ""

        if task.terminationStatus != 0 {
            throw ADBError.commandFailed(err.isEmpty ? out : err)
        }
        return out
    }

    /// Captures a full, native-resolution PNG screenshot on the device
    /// itself (`adb exec-out screencap -p`) — this is how Vysor does it
    /// too, and it beats capturing our own mirror window: no macOS Screen
    /// Recording permission needed, and no loss from the window's on-screen
    /// scale factor.
    func captureScreenshotPNG(serial: String) throws -> Data {
        guard let exe = executablePath else { throw ADBError.binaryNotFound }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: exe)
        task.arguments = ["-s", serial, "exec-out", "screencap", "-p"]

        let outPipe = Pipe()
        let errPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = errPipe

        try task.run()
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()

        guard task.terminationStatus == 0, !data.isEmpty else {
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: errData, encoding: .utf8) ?? "Screenshot fehlgeschlagen"
            throw ADBError.commandFailed(message)
        }
        return data
    }

    /// Spawn a long-running adb subprocess (e.g. `shell app_process ...`)
    /// without waiting for it to exit. Caller owns the returned Process.
    func spawn(_ arguments: [String]) throws -> Process {
        guard let exe = executablePath else { throw ADBError.binaryNotFound }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: exe)
        task.arguments = arguments
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try task.run()
        return task
    }

    func listDevices() -> [AndroidDevice] {
        guard let out = try? run(["devices", "-l"]) else { return [] }
        var devices: [AndroidDevice] = []
        for line in out.split(separator: "\n").dropFirst() {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2 else { continue }
            let serial = String(parts[0])
            let state = String(parts[1])
            var model = serial
            for part in parts.dropFirst(2) where part.hasPrefix("model:") {
                model = String(part.dropFirst("model:".count)).replacingOccurrences(of: "_", with: " ")
            }
            devices.append(AndroidDevice(serial: serial, model: model, state: state))
        }
        return devices
    }

    func push(serial: String, localPath: String, remotePath: String) throws {
        try run(["-s", serial, "push", localPath, remotePath], timeout: 20)
    }

    /// `adb forward tcp:0 <remote>` lets the OS pick a free local port;
    /// adb prints the chosen port back on stdout.
    func forwardToFreePort(serial: String, remote: String) throws -> UInt16 {
        let out = try run(["-s", serial, "forward", "tcp:0", remote])
        guard let port = UInt16(out.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw ADBError.commandFailed("Unerwartete adb forward Ausgabe: \(out)")
        }
        return port
    }

    /// `--remove` takes the LOCAL spec (e.g. "tcp:49468"), not the remote
    /// abstract socket name — passing the remote name is silently a no-op.
    func removeForward(serial: String, localPort: UInt16) {
        _ = try? run(["-s", serial, "forward", "--remove", "tcp:\(localPort)"])
    }

    /// Reads one `settings` value (e.g. namespace `system`, key
    /// `show_touches`). Returns nil for "null"/empty, matching what
    /// `settings get` prints when a key was never explicitly set.
    func getSetting(serial: String, namespace: String, key: String) -> String? {
        guard let out = try? run(["-s", serial, "shell", "settings", "get", namespace, key], timeout: 5) else { return nil }
        let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed.isEmpty || trimmed == "null") ? nil : trimmed
    }

    /// Writes one `settings` value. Used for scrcpy-equivalent toggles like
    /// "Show touches" (`system show_touches`) and "Stay awake"
    /// (`global stay_on_while_plugged_in`).
    func putSetting(serial: String, namespace: String, key: String, value: String) {
        _ = try? run(["-s", serial, "shell", "settings", "put", namespace, key, value], timeout: 5)
    }

    /// Full `getprop` dump, parsed from its `[key]: [value]` line format.
    private func rawProperties(serial: String) -> [String: String] {
        guard let out = try? run(["-s", serial, "shell", "getprop"], timeout: 5) else { return [:] }
        var result: [String: String] = [:]
        for line in out.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("["), let sepRange = trimmed.range(of: "]: [") else { continue }
            let key = trimmed[trimmed.index(after: trimmed.startIndex)..<sepRange.lowerBound]
            var value = String(trimmed[sepRange.upperBound...])
            if value.hasSuffix("]") { value.removeLast() }
            result[String(key)] = value
        }
        return result
    }

    /// Curated, human-readable device properties for the sidebar's info
    /// popover — a hand-picked subset of `getprop`, not the raw dump.
    func deviceInfo(serial: String) -> [(label: String, value: String)] {
        let props = rawProperties(serial: serial)
        var pairs: [(String, String)] = []
        if let v = props["ro.product.model"] { pairs.append(("Modell", v)) }
        if let v = props["ro.product.manufacturer"] { pairs.append(("Hersteller", v)) }
        if let v = props["ro.build.version.release"] { pairs.append(("Android-Version", v)) }
        if let v = props["ro.build.version.sdk"] { pairs.append(("SDK-Level", v)) }
        if let v = props["ro.product.cpu.abi"] { pairs.append(("CPU-Architektur", v)) }
        pairs.append(("Seriennummer", serial))
        return pairs
    }
}
