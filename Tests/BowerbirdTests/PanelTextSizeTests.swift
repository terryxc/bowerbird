import XCTest
@testable import Bowerbird

/// Text size is adjustable, but the heights that depend on the text must grow with it.
///
/// Scaling the text without touching the row height is the easiest mistake here: the row stays 34 pt,
/// the text grows from 13 to 17, and the top and bottom get clipped, subtly: the bottom edge of CJK
/// characters just grazes the edge and you have to look closely to notice.
@MainActor
final class PanelTextSizeTests: XCTestCase {
    private var original: PanelTextSize!

    // XCTest's synchronous setUp and tearDown are nonisolated on Xcode 16, so the async variants hop
    // onto the main actor explicitly; this compiles on both toolchains
    override func setUp() async throws {
        await MainActor.run { original = AppSettings.shared.panelTextSize }
    }

    override func tearDown() async throws {
        await MainActor.run { AppSettings.shared.panelTextSize = original }
    }

    private func metrics(at size: PanelTextSize) -> (title: CGFloat, row: CGFloat,
                                                     search: CGFloat, searchRow: CGFloat,
                                                     body: CGFloat, keyCap: CGFloat, footer: CGFloat) {
        AppSettings.shared.panelTextSize = size
        return (PanelMetrics.rowTitleFontSize, PanelMetrics.rowHeight,
                PanelMetrics.searchFontSize, PanelMetrics.searchHeight,
                PanelMetrics.previewTextFontSize, PanelMetrics.keyCapSize,
                PanelMetrics.footerFontSize)
    }

    /// The standard preset must match the numbers from before text size was adjustable exactly,
    /// otherwise everyone's appearance changes
    func testStandardKeepsTheNumbersWeMeasuredBefore() {
        let m = metrics(at: .standard)
        XCTAssertEqual(m.title, 13)
        XCTAssertEqual(m.row, 34, "Row height 34 was measured from macOS single-line lists")
        XCTAssertEqual(m.search, 15)
        XCTAssertEqual(m.searchRow, 52)
        XCTAssertEqual(m.footer, 11)
    }

    /// Preview body text went from 12 to 13: it is read as paragraphs, and macOS body text is 13
    func testPreviewBodyUsesTheSystemBodySize() {
        XCTAssertEqual(metrics(at: .standard).body, 13)
    }

    func testEveryStepChangesTheSize() {
        let sizes = PanelTextSize.allCases.map { metrics(at: $0).title }
        XCTAssertEqual(sizes, sizes.sorted(), "Sizes must increase monotonically from small to large")
        XCTAssertEqual(Set(sizes).count, sizes.count, "No two of the four presets may be the same size")
    }

    /// The key one: when the text grows, the box holding it must grow too
    func testTheBoxesGrowWithTheText() {
        for size in PanelTextSize.allCases {
            let m = metrics(at: size)
            XCTAssertGreaterThan(m.row, m.title, "\(size): row height must fit the title")
            XCTAssertGreaterThanOrEqual(m.row - m.title, 20, "\(size): the text must not eat the vertical padding")
            XCTAssertGreaterThan(m.searchRow, m.search, "\(size): search row must fit the typed text")
            XCTAssertGreaterThan(m.keyCap, m.footer, "\(size): key cap must fit the key name")
        }
    }

    /// Extra Large must really bring text on the built-in display back to how it feels on the
    /// reference display: at least 1.25x
    func testExtraLargeIsWorthChoosing() {
        let standard = metrics(at: .standard).title
        let extraLarge = metrics(at: .extraLarge).title
        XCTAssertGreaterThanOrEqual(extraLarge / standard, 1.25)
    }

    /// Font sizes are rounded to half points: finer fractions don't align to Retina pixels and edges blur
    func testSizesLandOnHalfPoints() {
        for size in PanelTextSize.allCases {
            let m = metrics(at: size)
            for value in [m.title, m.search, m.body, m.footer] {
                XCTAssertEqual(value * 2, (value * 2).rounded(), "\(size): \(value) is not a multiple of half a point")
            }
        }
    }

    /// The row count must follow the row height, so the "shows about N rows" line in Settings doesn't lie
    func testVisibleRowCountFollowsTheTextSize() {
        AppSettings.shared.panelTextSize = .small
        let manySmallRows = PanelSize.medium.visibleRows
        AppSettings.shared.panelTextSize = .extraLarge
        let fewLargeRows = PanelSize.medium.visibleRows
        XCTAssertGreaterThan(manySmallRows, fewLargeRows)
    }
}
