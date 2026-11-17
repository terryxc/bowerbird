import XCTest
@testable import Bowerbird

@MainActor
final class SmokeTests: XCTestCase {
    func testTargetIsTestable() {
        XCTAssertEqual(PanelMetrics.rowHeight, 34)
    }
}
