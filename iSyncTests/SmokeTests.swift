import XCTest
@testable import iSync

final class SmokeTests: XCTestCase {
    func testBundleLoads() {
        XCTAssertNotNil(Bundle(for: SmokeTests.self).url(forResource: "grappa-fixed-vectors", withExtension: "plist"))
    }
}
