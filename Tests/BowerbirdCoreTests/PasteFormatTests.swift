import AppKit
import XCTest
@testable import BowerbirdCore

/// Format grouping and filtering.
///
/// Every assertion here corresponds to a concrete usage scenario; when changing them, don't lose the
/// scenario along the way.
final class PasteFormatTests: XCTestCase {
    private func asset(_ type: NSPasteboard.PasteboardType, _ bytes: Int = 8) -> ClipCapture.Asset {
        .init(type: type, data: Data(repeating: 0x41, count: bytes))
    }

    // MARK: Grouping

    /// Copied from Feishu or Word: three groups (rich text, web, plain text), so the format bar should
    /// appear
    func testRichClipHasThreeGroups() {
        let assets = [asset(.rtf), asset(.html), asset(.string)]
        XCTAssertEqual(PasteFormat.groups(in: assets), [.richText, .html, .plainText])
    }

    /// Copying a link puts both public.url and plain text on the pasteboard, but they paste the same.
    /// Merged into one group, only one group remains, so the format bar doesn't pop up for every link.
    func testURLFoldsIntoPlainTextSoTheBarStaysHidden() {
        let assets = [asset(.URL), asset(.string)]
        XCTAssertEqual(PasteFormat.groups(in: assets), [.plainText])
    }

    /// Conversely, copying a file in Finder gives "file + plain text", so the format bar should appear;
    /// choosing plain text pastes the path as text
    func testFileClipOffersPathAsPlainText() {
        let assets = [asset(.fileURL), asset(.string)]
        XCTAssertEqual(PasteFormat.groups(in: assets), [.file, .plainText])
    }

    /// A screenshot has only one representation, so there's nothing to choose
    func testScreenshotHasOneGroup() {
        XCTAssertEqual(PasteFormat.groups(in: [asset(.png)]), [.image])
    }

    /// PNG and TIFF are two encodings of the same image and shouldn't become two options
    func testPNGAndTIFFAreOneGroup() {
        XCTAssertEqual(PasteFormat.groups(in: [asset(.png), asset(.tiff)]), [.image])
    }

    /// The order follows the assets, which were already sorted by preferredOrder when stored
    func testGroupOrderFollowsAssetOrder() {
        let assets = [asset(.rtfd), asset(.rtf), asset(.html), asset(.png), asset(.string)]
        XCTAssertEqual(PasteFormat.groups(in: assets), [.richText, .html, .image, .plainText])
    }

    // MARK: Filtering

    /// "As Captured" leaves everything untouched, not a single byte changed
    func testOriginalKeepsEverything() {
        let assets = [asset(.rtf), asset(.html), asset(.string)]
        XCTAssertEqual(PasteFormat.filter(assets, to: nil).map(\.type),
                       [.rtf, .html, .string])
    }

    /// Choosing rich text means dropping the web copy; that's exactly the fix for "pasting from Feishu
    /// messes up the formatting"
    func testPickingRichTextDropsHTML() {
        let assets = [asset(.rtf), asset(.html), asset(.string)]
        let kept = PasteFormat.filter(assets, to: .richText).map(\.type)
        XCTAssertFalse(kept.contains(.html))
        XCTAssertEqual(kept.first, .rtf)
    }

    /// Plain text is appended at the end as a fallback. Without it, ⌘V does nothing when the target app
    /// recognizes none of the types, which feels broken. With it, the intent "don't use the web format"
    /// still holds, because the target app prefers the richer representation that comes first.
    func testNonPlainSelectionAppendsPlainTextFallback() {
        let assets = [asset(.rtf), asset(.html), asset(.string)]
        XCTAssertEqual(PasteFormat.filter(assets, to: .richText).map(\.type), [.rtf, .string])
        XCTAssertEqual(PasteFormat.filter(assets, to: .html).map(\.type), [.html, .string])
    }

    /// Choosing plain text gives only plain text, with nothing appended
    func testPlainTextSelectionIsExact() {
        let assets = [asset(.rtf), asset(.html), asset(.string)]
        XCTAssertEqual(PasteFormat.filter(assets, to: .plainText).map(\.type), [.string])
    }

    /// If the item never stored plain text, don't make one up
    func testNoFallbackWhenClipHasNoPlainText() {
        let assets = [asset(.png), asset(.html)]
        XCTAssertEqual(PasteFormat.filter(assets, to: .image).map(\.type), [.png])
    }

    /// Choosing a group the item doesn't have falls back to everything; never write an empty pasteboard
    func testUnavailableFormatFallsBackToEverything() {
        let assets = [asset(.png)]
        XCTAssertEqual(PasteFormat.filter(assets, to: .pdf).map(\.type), [.png])
    }

    // MARK: Summary and content must agree

    /// The byte count shown in the panel comes from the summary; what's actually written comes from the
    /// content. Both paths must compute the same groups and sizes, otherwise the UI says 639 B and
    /// something else gets pasted.
    func testSummaryPathAgreesWithAssetPath() {
        let assets = [asset(.rtf, 600), asset(.html, 700), asset(.string, 40)]
        let summaries = assets.map { ClipAssetSummary(type: $0.type, byteSize: $0.data.count) }

        XCTAssertEqual(PasteFormat.groups(in: assets), PasteFormat.groups(in: summaries))
        for choice in [PasteFormat?.none, .richText, .html, .plainText, .image] {
            XCTAssertEqual(PasteFormat.byteSize(assets, to: choice),
                           PasteFormat.byteSize(summaries, to: choice),
                           "format \(choice?.rawValue ?? "as captured") differs between the two paths")
        }
    }

    // MARK: Byte counts

    func testByteSizeCountsWhatWillActuallyBeWritten() {
        let assets = [asset(.rtf, 600), asset(.html, 700), asset(.string, 40)]
        XCTAssertEqual(PasteFormat.byteSize(assets, to: nil), 1_340)
        XCTAssertEqual(PasteFormat.byteSize(assets, to: .richText), 640)
        XCTAssertEqual(PasteFormat.byteSize(assets, to: .plainText), 40)
    }
    // MARK: Dedup by result

    /// Copying from a browser: "Web" and "As Captured" write exactly the same bytes, so that chip should
    /// go. Measured: of the 14 items in real history with two groups, 13 were like this.
    func testDropsAChipThatProducesTheSameBytesAsOriginal() {
        let assets = [asset(.html), asset(.string)]
        XCTAssertEqual(PasteFormat.groups(in: assets), [.html, .plainText])
        XCTAssertEqual(PasteFormat.distinctFormats(in: assets), [.plainText],
                       "only plain text should remain, so the format bar is just \"As Captured | Plain Text\"")
    }

    /// Word / WPS / Feishu: the four results really are all different, but the product decision is at
    /// most two, so this also offers only "As Captured | Plain Text". As Captured already preserves the
    /// formatting in full.
    func testRichClipStillOffersOnlyTwoOptions() {
        let assets = [asset(.rtf), asset(.html), asset(.string)]
        XCTAssertEqual(PasteFormat.distinctFormats(in: assets), [.plainText])
    }

    /// Copying a file in Finder is the same: only "As Captured | Plain Text", where plain text pastes the
    /// path as text
    func testFileClipCollapsesToPlainTextOnly() {
        let assets = [asset(.fileURL), asset(.string)]
        XCTAssertEqual(PasteFormat.distinctFormats(in: assets), [.plainText])
    }

    /// An image copied from a web page has no plain text at all, so there's nothing to choose and the
    /// bar is hidden
    func testWebImageShowsNoBarBecauseThereIsNoPlainText() {
        let assets = [asset(.html), asset(.png)]
        XCTAssertTrue(PasteFormat.distinctFormats(in: assets).isEmpty)
    }

    /// With only one group the bar is hidden
    func testSingleGroupShowsNoBar() {
        XCTAssertTrue(PasteFormat.distinctFormats(in: [asset(.png)]).isEmpty)
        XCTAssertTrue(PasteFormat.distinctFormats(in: [asset(.string), asset(.URL)]).isEmpty)
    }

    /// Dedup results must agree between the summary path and the content path
    func testDistinctAgreesAcrossBothPaths() {
        let assets = [asset(.rtf, 600), asset(.html, 700), asset(.string, 40)]
        let summaries = assets.map { ClipAssetSummary(type: $0.type, byteSize: $0.data.count) }
        XCTAssertEqual(PasteFormat.distinctFormats(in: assets),
                       PasteFormat.distinctFormats(in: summaries))
    }

}
