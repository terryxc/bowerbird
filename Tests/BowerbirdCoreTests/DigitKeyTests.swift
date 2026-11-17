import XCTest

/// `DigitKey` lives in the app target, which Core's tests can't reach.
/// This pins down the fact it depends on, the ANSI digit-row key codes, by itself. These numbers
/// are hard facts: if someone goes by intuition and makes them a contiguous 18...26, ⌘5 through ⌘8
/// all end up on the wrong keys.
final class DigitKeyTests: XCTestCase {
    /// Physical key codes of the ANSI digit row. Note that 5 and 6, and 7 and 8, aren't in order.
    private let ansiDigitRow: [UInt16: Int] = [
        18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9,
    ]

    func testDigitRowIsNotContiguous() {
        // 22 is 6, not 5; 23 is 5, not 6
        XCTAssertEqual(ansiDigitRow[22], 6)
        XCTAssertEqual(ansiDigitRow[23], 5)
        // 25 is 9, not 8; 26 is 7
        XCTAssertEqual(ansiDigitRow[25], 9)
        XCTAssertEqual(ansiDigitRow[26], 7)
        XCTAssertEqual(ansiDigitRow[28], 8)
    }

    func testCoversOneThroughNineExactlyOnce() {
        XCTAssertEqual(Set(ansiDigitRow.values), Set(1...9))
        XCTAssertEqual(ansiDigitRow.count, 9)
    }
}
