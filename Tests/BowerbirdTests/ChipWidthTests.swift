import AppKit
import SwiftUI
import XCTest
@testable import Bowerbird

/// Selecting a format chip must not change its width, or every chip after it shifts sideways
@MainActor
final class ChipWidthTests: XCTestCase {
    func testSelectingAChipKeepsItsWidth() {
        for title in ["As Captured", "Plain Text", "Text in Image", "原样", "纯文本"] {
            let widths = [false, true].map { selected in
                NSHostingView(rootView: TextChip(verbatim: title, selected: selected) {}).fittingSize.width
            }
            XCTAssertEqual(widths[0], widths[1], "\(title): \(widths[0]) → \(widths[1])")
        }
    }
}
