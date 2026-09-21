import AVFoundation
import Foundation

/// One USB-connected external video source usable for iOS screen
/// mirroring. Unlike Android's `AndroidDevice`, there's no serial/model
/// string available up front; the only stable identifier is the capture
/// device's `uniqueID`.
struct USBIOSDevice: Identifiable, Hashable {
    let uniqueID: String
    var name: String

    var id: String { uniqueID }
}

/// Finds USB-connected video sources usable for iOS screen mirroring,
/// using only public `AVFoundation` API — no network dependency, and no
/// bundled helper process.
///
/// Two distinct mechanisms are checked, because on a real machine
/// (macOS 26/Tahoe, tested with a physically connected, unlocked, fully
/// trusted iPhone — `usbmuxd` logged "Successfully paired") only the
/// second one actually worked:
///
/// 1. A directly-connected, trusted iPhone/iPad exposing its own screen as
///    an `AVCaptureDevice` with `mediaType == .muxed` — the classic
///    QuickTime "New Movie Recording" trick. Empirically this no longer
///    surfaces anything on current macOS: `system_profiler SPCameraDataType`
///    and a plain `AVCaptureDevice.DiscoverySession` both come back empty
///    for a paired device, and this holds for *every* app using the same
///    public API, not just this one — Apple appears to have discontinued
///    this path. Kept anyway (near-zero cost) in case it's restored, or
///    this app ever runs on an older macOS where it still works.
/// 2. A generic external UVC video capture device — e.g. a USB HDMI
///    capture dongle fed by a Lightning/USB-C → HDMI adapter cable from
///    the iPhone/iPad. macOS sees that as an ordinary external camera, with
///    no dependency on Apple's own (and apparently discontinued)
///    iPhone-as-camera support, and no dependency on iCloud/Continuity
///    either — unlike Apple's own "iPhone-Spiegelung" (`iPhone
///    Mirroring.app`), which Managed Apple IDs on locked-down
///    "Dienstrechner" machines reported as `iCloudNotHealthy` (unsupported),
///    and which an MDM profile can block outright. This is the mechanism
///    actually worth relying on, and the only one this app supports now.
enum USBiOSDiscovery {
    static func discoverDevices() -> [USBIOSDevice] {
        var seenIDs = Set<String>()
        var result: [USBIOSDevice] = []

        func add(_ devices: [AVCaptureDevice]) {
            for device in devices where seenIDs.insert(device.uniqueID).inserted {
                result.append(USBIOSDevice(uniqueID: device.uniqueID, name: device.localizedName))
            }
        }

        let muxedSession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.external],
            mediaType: .muxed,
            position: .unspecified
        )
        add(muxedSession.devices)

        let externalVideoSession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.external],
            mediaType: .video,
            position: .unspecified
        )
        add(externalVideoSession.devices)

        return result
    }
}
