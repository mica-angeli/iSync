import Foundation
import IOKit.pwr_mgt

/// Keeps the Mac from going to sleep on its own while held, on battery as well as on power. The
/// display can still turn off. Closing the lid, choosing Sleep or a low battery still sleeps the Mac.
final class SleepAssertion {
    private var id: IOPMAssertionID?

    init(reason: String) {
        var id = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(kIOPMAssertPreventUserIdleSystemSleep as CFString,
                                                 IOPMAssertionLevel(kIOPMAssertionLevelOn), reason as CFString, &id)
        if result == kIOReturnSuccess {
            self.id = id
        } else {
            logWarning("Could not keep the Mac awake (IOKit error \(String(format: "%#x", result))); it may sleep while working")
        }
    }

    var isHeld: Bool { id != nil }

    /// Lets the Mac sleep again. Safe to call more than once.
    func release() {
        guard let id else { return }
        IOPMAssertionRelease(id)
        self.id = nil
    }

    deinit { release() }
}
