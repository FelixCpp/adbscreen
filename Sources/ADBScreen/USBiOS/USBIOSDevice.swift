import AVFoundation
import Foundation

/// One iPhone/iPad currently reachable as a USB "muxed" capture device —
/// the same mechanism QuickTime Player's "New Movie Recording" uses to
/// offer a connected iPhone as a video source. Unlike Android's
/// `AndroidDevice`, there's no serial/model string available up front; the
/// only stable identifier is the capture device's `uniqueID`.
struct USBIOSDevice: Identifiable, Hashable {
    let uniqueID: String
    var name: String

    var id: String { uniqueID }
}

/// Finds iPhones/iPads connected over USB and trusted by this Mac, using
/// only public `AVFoundation` API — no AirPlay, no network, and (unlike the
/// AirPlay receiver) no bundled helper process. This is the same discovery
/// AVFoundation performs for QuickTime's iPhone-as-camera feature: a
/// connected, trusted iOS device exposes its screen (plus mic) as an
/// `AVCaptureDevice` with `mediaType == .muxed`.
enum USBiOSDiscovery {
    /// `.externalUnknown` is deprecated in favor of `.external`, but that
    /// replacement's discovery requires the
    /// `com.apple.developer.avfoundation.external-capture-devices`
    /// entitlement on iOS/iPadOS/tvOS only — on macOS, `.externalUnknown`
    /// remains the documented way real-world tools (e.g. QuickTime itself)
    /// discover a muxed iPhone/iPad capture device, so it's used here
    /// despite the deprecation warning.
    static func discoverDevices() -> [USBIOSDevice] {
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.externalUnknown],
            mediaType: .muxed,
            position: .unspecified
        )
        return session.devices.map { USBIOSDevice(uniqueID: $0.uniqueID, name: $0.localizedName) }
    }
}
