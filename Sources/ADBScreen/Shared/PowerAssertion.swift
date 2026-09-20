import IOKit.pwr_mgt

/// Keeps the Mac from sleeping (display and system) while at least one
/// mirror is connected — matches `caffeinate -d -i`. A demo dying because
/// the screen dimmed mid-presentation is worse than the battery cost.
final class PowerAssertion {
    private var displayAssertionID: IOPMAssertionID = 0
    private var systemAssertionID: IOPMAssertionID = 0
    private var isActive = false

    func acquire(reason: String) {
        guard !isActive else { return }
        let displayOK = IOPMAssertionCreateWithName(
            kIOPMAssertionTypeNoDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &displayAssertionID
        ) == kIOReturnSuccess
        let systemOK = IOPMAssertionCreateWithName(
            kIOPMAssertionTypeNoIdleSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &systemAssertionID
        ) == kIOReturnSuccess
        isActive = displayOK || systemOK
    }

    func release() {
        guard isActive else { return }
        IOPMAssertionRelease(displayAssertionID)
        IOPMAssertionRelease(systemAssertionID)
        isActive = false
    }
}
