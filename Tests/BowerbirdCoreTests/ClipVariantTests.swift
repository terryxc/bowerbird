import AppKit
import XCTest
@testable import BowerbirdCore

/// The different ways to take the same content: which slots exist, what each writes out, and how many bytes it reports.
final class ClipVariantTests: XCTestCase {
    private func item(kind: ClipKind, content: String, ocr: String? = nil) -> ClipItem {
        ClipItem(kind: kind, content: content, contentHash: "h", sourceBundleID: nil,
                 createdAt: Date(), byteSize: 0, ocrText: ocr)
    }

    private func summaries(_ types: [(NSPasteboard.PasteboardType, Int)]) -> [ClipAssetSummary] {
        types.map { ClipAssetSummary(type: $0.0, byteSize: $0.1) }
    }

    /// Rich text can be pasted as plain text (⇧⌘↩), but that is not a cell on the format bar: the
    /// preview is plain text either way, so two cells would show the same thing
    func testRichTextGetsNoFormatBarCell() {
        let text = item(kind: .text, content: "hello")
        let assets = summaries([(.rtf, 500), (.string, 5)])
        XCTAssertEqual(text.variants(assets: assets), [.asCaptured])
        XCTAssertEqual(text.textVariant, .plainText, "the second way still exists for the key and the menu")
    }

    /// When only plain text was stored, both slots would write exactly the same thing, so don't offer the second
    func testPlainOnlyTextHasNoSecondVariant() {
        let text = item(kind: .text, content: "hello")
        XCTAssertEqual(text.variants(assets: summaries([(.string, 5)])), [.asCaptured])
    }

    func testFileAlwaysOffersPath() throws {
        let paths = ["/tmp/a.txt", "/tmp/b.txt"]
        let json = String(decoding: try JSONEncoder().encode(paths), as: UTF8.self)
        let file = item(kind: .file, content: json)
        XCTAssertEqual(file.variants(assets: []), [.asCaptured, .path])
        XCTAssertEqual(file.textVariant, .path)

        let payload = file.payload(for: .path, assets: [])
        XCTAssertEqual(payload.map(\.type), [.string])
        XCTAssertEqual(String(decoding: payload[0].data, as: UTF8.self), "/tmp/a.txt\n/tmp/b.txt")
        XCTAssertEqual(file.byteCount(for: .path, summaries: []), 21)
    }

    func testImageOffersTextOnlyWhenSomethingWasRecognised() {
        let blank = item(kind: .image, content: "abc.png", ocr: "")
        XCTAssertEqual(blank.variants(assets: []), [.asCaptured])
        XCTAssertEqual(blank.textVariant, .asCaptured)

        let withText = item(kind: .image, content: "abc.png", ocr: "INVOICE 128")
        XCTAssertEqual(withText.variants(assets: []), [.asCaptured, .recognizedText])
        let payload = withText.payload(for: .recognizedText, assets: [])
        XCTAssertEqual(String(decoding: payload[0].data, as: UTF8.self), "INVOICE 128")
        XCTAssertEqual(withText.byteCount(for: .recognizedText, summaries: []), 11)
    }

    /// For HTML-only content, "Paste as Plain Text" must not paste out the whole HTML
    func testPlainTextFallsBackToStoredTextWhenThereIsNoPlainAsset() {
        let text = item(kind: .text, content: "just words")
        let assets: [ClipCapture.Asset] = [.init(type: .html, data: Data("<b>just words</b>".utf8))]
        let payload = text.payload(for: .plainText, assets: assets)
        XCTAssertEqual(payload.map(\.type), [.string])
        XCTAssertEqual(String(decoding: payload[0].data, as: UTF8.self), "just words")
    }

    /// The plain-text byte count is the size of what "Plain Text" actually writes, not of the whole
    /// plain-text group
    func testPlainTextByteCountMatchesThePayload() {
        let link = item(kind: .text, content: "https://example.com")
        let assets: [ClipCapture.Asset] = [
            .init(type: .html, data: Data(repeating: 1, count: 40)),
            .init(type: .URL, data: Data("https://example.com".utf8)),
            .init(type: .string, data: Data("https://example.com".utf8)),
        ]
        let written = link.payload(for: .plainText, assets: assets).reduce(0) { $0 + $1.data.count }
        let shown = link.byteCount(for: .plainText, summaries: summaries([(.html, 40), (.URL, 19), (.string, 19)]))
        XCTAssertEqual(shown, written)

        let htmlOnly = item(kind: .text, content: "just words")
        XCTAssertEqual(htmlOnly.byteCount(for: .plainText, summaries: summaries([(.html, 17)])), 10)
    }

    func testAsCapturedWritesEverythingBack() {
        let text = item(kind: .text, content: "hi")
        let assets: [ClipCapture.Asset] = [
            .init(type: .rtf, data: Data(repeating: 1, count: 10)),
            .init(type: .string, data: Data("hi".utf8)),
        ]
        XCTAssertEqual(text.payload(for: .asCaptured, assets: assets).map(\.type), [.rtf, .string])
        XCTAssertEqual(text.byteCount(for: .asCaptured, summaries: summaries([(.rtf, 10), (.string, 2)])), 12)
    }
}

/// Which text search should look at: an image's file name and a file item's JSON must not be searchable
final class SearchTextTests: XCTestCase {
    var dir: URL!
    var store: HistoryStore!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bowerbird-search-\(UUID().uuidString)", isDirectory: true)
        store = try HistoryStore(databaseURL: dir.appendingPathComponent("history.sqlite"),
                                 imagesDirectory: dir.appendingPathComponent("images", isDirectory: true))
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: dir)
    }

    private func png() -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 16, bitsPerPixel: 32)!
        return rep.representation(using: .png, properties: [:])!
    }

    /// An image's content is a hex hash; indexed verbatim, typing a single letter would find every image
    func testImageIsNotSearchableByItsFileName() throws {
        let item = try store.record(ClipCapture(assets: [.init(type: .png, data: png())],
                                                kind: .image, text: "",
                                                imageSize: CGSize(width: 4, height: 4)),
                                     sourceBundleID: nil)
        let name = item.content
        XCTAssertTrue(name.hasSuffix(".png"))
        for letter in ["a", "b", "c", "d", "e", "f"] {
            XCTAssertTrue(try store.search(letter).isEmpty, "\"\(letter)\" matched an image")
        }
        // Text from OCR is still searchable
        try store.setOCRText(id: try XCTUnwrap(item.id), "INVOICE 128")
        XCTAssertEqual(try store.search("invoice").count, 1)
    }

    func testFileIsSearchableByPathButNotByJSON() throws {
        _ = try store.record(ClipCapture(assets: [.init(type: .fileURL, data: Data("x".utf8))],
                                          kind: .file, text: "",
                                          filePaths: ["/Users/me/Desktop/report.pdf"]),
                              sourceBundleID: nil)
        XCTAssertEqual(try store.search("report").count, 1)
        XCTAssertEqual(try store.search("desktop").count, 1)
        // The escaped backslashes in the JSON must not be searchable
        XCTAssertTrue(try store.search("\\/").isEmpty)
    }
}
