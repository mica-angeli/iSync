import XCTest
import IOKit.pwr_mgt
@testable import iSync

final class SleepAssertionTests: XCTestCase {
    /// The types of this process's power assertions named `name`, as the system reports them.
    private func assertionTypes(named name: String) -> [String] {
        var byProcess: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&byProcess) == kIOReturnSuccess,
              let all = byProcess?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else { return [] }
        return (all[NSNumber(value: getpid())] ?? [])
            .filter { $0[kIOPMAssertionNameKey] as? String == name }
            .compactMap { $0[kIOPMAssertionTypeKey] as? String }
    }

    private func eventually(_ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(2)
        while !condition() {
            if Date() > deadline { return false }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return true
    }

    func testPreventsIdleSystemSleepButNotDisplaySleepUntilReleased() {
        let name = "iSync test \(UUID().uuidString)"
        let assertion = SleepAssertion(reason: name)
        XCTAssertTrue(assertion.isHeld)
        XCTAssertTrue(eventually { assertionTypes(named: name) == ["PreventUserIdleSystemSleep"] },
                      "held: \(assertionTypes(named: name))")

        assertion.release()
        assertion.release()
        XCTAssertFalse(assertion.isHeld)
        XCTAssertTrue(eventually { assertionTypes(named: name).isEmpty }, "still held: \(assertionTypes(named: name))")
    }
}
