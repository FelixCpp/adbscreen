import AVFoundation
import CoreMediaIO
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
///    QuickTime "New Movie Recording" trick. Empirically this surfaced
///    nothing on current macOS: `system_profiler SPCameraDataType` and a
///    plain `AVCaptureDevice.DiscoverySession` both came back empty for a
///    paired device, and this held for *every* app using the same public
///    API, not just this one. `allowScreenCaptureDevicesIfNeeded()` below
///    is an attempt to revive this path via a documented (but
///    seemingly unenforced-by-default-for-third-parties) `CoreMediaIO`
///    property; whether that actually restores it is unverified pending
///    a real device. Kept regardless (near-zero cost) in case it's
///    restored, or this app ever runs on an older macOS where it still
///    works.
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
        allowScreenCaptureDevicesIfNeeded()

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

    /// `CoreMediaIO`'s system object has a documented (public, non-private)
    /// property, `kCMIOHardwarePropertyAllowScreenCaptureDevices`, that
    /// gates whether "screen capture devices" — which is what a directly
    /// connected iPhone/iPad's `.muxed` `AVCaptureDevice` counts as —
    /// are presented to the current process at all. Apple's header says
    /// it defaults to 1 (allowed) system-wide, but that's a per-process
    /// property, and there's no public documentation on whether/how it's
    /// actually gated for processes without Apple's own entitlements —
    /// which would explain why plain `AVCaptureDevice` discovery alone
    /// (the previous state of this function) found nothing for a
    /// directly-connected iPhone, despite `usbmuxd` pairing successfully.
    /// Explicitly setting it to 1 on every discovery call costs one cheap
    /// `CMIOObjectSetPropertyData` call, and *if* the OS actually honors
    /// it for third-party processes, it's the difference between the
    /// muxed path working and not. This has not been verified against a
    /// physical device yet (none was available while making this
    /// change) — if the OS silently ignores or rejects the write (e.g.
    /// because it's gated by an Apple-private entitlement we don't
    /// have), this is a no-op and discovery falls back to the
    /// external-UVC path exactly as before.
    private static func allowScreenCaptureDevicesIfNeeded() {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyAllowScreenCaptureDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )

        guard CMIOObjectHasProperty(CMIOObjectID(kCMIOObjectSystemObject), &address) else {
            return
        }

        var allow: UInt32 = 1
        let status = CMIOObjectSetPropertyData(
            CMIOObjectID(kCMIOObjectSystemObject),
            &address,
            0,
            nil,
            UInt32(MemoryLayout<UInt32>.size),
            &allow
        )
        if status != noErr {
            NSLog("[USBiOSDiscovery] Failed to set kCMIOHardwarePropertyAllowScreenCaptureDevices: OSStatus %d", status)
        }
    }
}
