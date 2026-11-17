import XCTest
@testable import Bowerbird

/// Two displays side by side, 1440×900 each, with a 25 pt menu bar at the top.
final class PanelPositionTests: XCTestCase {
    private let left = PanelPosition.Display(frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                                             visible: CGRect(x: 0, y: 0, width: 1440, height: 875))
    private let right = PanelPosition.Display(frame: CGRect(x: 1440, y: 0, width: 1440, height: 900),
                                              visible: CGRect(x: 1440, y: 0, width: 1440, height: 875))
    private let size = CGSize(width: 760, height: 480)

    /// The pointer on the menu bar is still on that display, even though it's outside the visible frame
    func testPointerOnTheMenuBarPicksThatDisplay() {
        let origin = PanelPosition.center.origin(for: size, mouse: CGPoint(x: 2000, y: 890),
                                                 screens: [left, right], fallback: left)
        XCTAssertEqual(origin.x, right.visible.midX - size.width / 2)
    }

    /// Following the pointer never pushes the panel off the display
    func testAtThePointerStaysOnScreen() {
        let origin = PanelPosition.cursor.origin(for: size, mouse: CGPoint(x: 1430, y: 30),
                                                 screens: [left, right], fallback: left)
        XCTAssertTrue(left.visible.contains(CGRect(origin: origin, size: size)))
    }

    /// On the top row of pixels the pointer's y equals the frame's maxY, which no frame "contains".
    /// The panel still belongs on the display the pointer is touching, not on the main one.
    func testPointerOnTheTopEdgePicksTheNearestDisplay() {
        let origin = PanelPosition.center.origin(for: size, mouse: CGPoint(x: 2000, y: 900),
                                                 screens: [left, right], fallback: left)
        XCTAssertEqual(origin.x, right.visible.midX - size.width / 2)
    }
}
