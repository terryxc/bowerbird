import AppKit
import XCTest
@testable import BowerbirdCore

/// Round-trip tests for formatted content.
///
/// There's really only one core assertion: however many representations are on the pasteboard,
/// the same ones come back out after storing, byte for byte. As long as they're replayed exactly,
/// the target app sees the same thing as when it was copied directly, and no formatting is lost.
final class RichContentTests: XCTestCase {
    var store: HistoryStore!
    var imagesDir: URL!

    override func setUpWithError() throws {
        imagesDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bowerbird-rich-\(UUID().uuidString)", isDirectory: true)
        store = try HistoryStore(databaseURL: nil, imagesDirectory: imagesDir)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: imagesDir)
        try? FileManager.default.removeItem(at: store.assetsDirectory)
    }

    /// Builds some real rich text: bold, coloured, underlined, plus an embedded image
    private func richText() -> NSAttributedString {
        let text = NSMutableAttributedString()
        text.append(NSAttributedString(string: "标题\n", attributes: [
            .font: NSFont.boldSystemFont(ofSize: 18),
            .foregroundColor: NSColor.systemRed,
        ]))
        text.append(NSAttributedString(string: "正文", attributes: [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.systemBlue,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]))
        return text
    }

    private func freshPasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("bowerbird.rich.\(UUID().uuidString)"))
    }

    private func writeRich(to pb: NSPasteboard) throws -> (rtf: Data, html: Data, plain: String) {
        let text = richText()
        let range = NSRange(location: 0, length: text.length)
        let rtf = try XCTUnwrap(text.rtf(from: range, documentAttributes: [:]))
        let html = try text.data(from: range, documentAttributes: [
            .documentType: NSAttributedString.DocumentType.html,
        ])
        pb.clearContents()
        pb.setData(rtf, forType: .rtf)
        pb.setData(html, forType: .html)
        pb.setString(text.string, forType: .string)
        return (rtf, html, text.string)
    }

    func testCapturesEveryRepresentationNotJustPlainText() throws {
        let pb = freshPasteboard()
        let written = try writeRich(to: pb)
        let capture = try XCTUnwrap(PasteboardReader.capture(from: pb))

        XCTAssertEqual(capture.kind, .text)
        XCTAssertEqual(capture.text, written.plain)
        XCTAssertEqual(capture.data(for: .rtf), written.rtf, "RTF must be kept; all the formatting is in it")
        XCTAssertEqual(capture.data(for: .html), written.html)
        XCTAssertNotNil(capture.data(for: .string))
    }

    func testRoundTripsThroughStorage() throws {
        let pb = freshPasteboard()
        let written = try writeRich(to: pb)
        let capture = try XCTUnwrap(PasteboardReader.capture(from: pb))
        let item = try store.record(capture, sourceBundleID: "com.apple.TextEdit")

        let restored = try store.assets(for: try XCTUnwrap(item.id))
        let byType = Dictionary(uniqueKeysWithValues: restored.map { ($0.type, $0.data) })

        XCTAssertEqual(byType[.rtf], written.rtf, "RTF must come back out of storage byte for byte")
        XCTAssertEqual(byType[.html], written.html)
        XCTAssertEqual(byType[.string].flatMap { String(data: $0, encoding: .utf8) }, written.plain)
    }

    /// Richer types go first. Some apps pick which representation to use by the order of types on
    /// the pasteboard, so the order must not be scrambled.
    func testRicherRepresentationsComeFirst() throws {
        let pb = freshPasteboard()
        _ = try writeRich(to: pb)
        let capture = try XCTUnwrap(PasteboardReader.capture(from: pb))
        let order = capture.assets.map(\.type)
        let rtf = try XCTUnwrap(order.firstIndex(of: .rtf))
        let html = try XCTUnwrap(order.firstIndex(of: .html))
        let plain = try XCTUnwrap(order.firstIndex(of: .string))
        XCTAssertLessThan(rtf, html)
        XCTAssertLessThan(html, plain)
    }

    /// The same text with different formatting is two different pieces of content; it must not be
    /// deduplicated just because the plain text matches
    func testSameTextDifferentFormattingIsNotDeduplicated() throws {
        let plain = "同样的文字"
        let attributed = NSAttributedString(string: plain, attributes: [
            .font: NSFont.boldSystemFont(ofSize: 20),
        ])
        let rtf = try XCTUnwrap(attributed.rtf(
            from: NSRange(location: 0, length: attributed.length), documentAttributes: [:]))

        let plainOnly = ClipCapture(assets: [.init(type: .string, data: Data(plain.utf8))],
                                    kind: .text, text: plain)
        let withFormatting = ClipCapture(
            assets: [.init(type: .rtf, data: rtf), .init(type: .string, data: Data(plain.utf8))],
            kind: .text, text: plain)

        XCTAssertNotEqual(plainOnly.contentHash, withFormatting.contentHash)
        _ = try store.record(plainOnly, sourceBundleID: nil)
        _ = try store.record(withFormatting, sourceBundleID: nil)
        XCTAssertEqual(try store.fetchRecent().count, 2)
    }

    /// Each hashed field needs a length prefix, or ("ab","c") and ("a","bc") collide
    func testHashIsNotAmbiguousAcrossFieldBoundaries() {
        let a = ClipCapture(assets: [.init(type: .init("ab"), data: Data("c".utf8))],
                            kind: .text, text: "")
        let b = ClipCapture(assets: [.init(type: .init("a"), data: Data("bc".utf8))],
                            kind: .text, text: "")
        XCTAssertNotEqual(a.contentHash, b.contentHash)
    }

    /// A legacy alias and its modern type are the same bytes; keep only the modern one
    func testDropsLegacyAliasWhenModernTypeIsPresent() throws {
        let pb = freshPasteboard()
        pb.clearContents()
        let payload = Data("hello".utf8)
        pb.setData(payload, forType: .string)
        pb.setData(payload, forType: .init("NSStringPboardType"))
        let capture = try XCTUnwrap(PasteboardReader.capture(from: pb))
        XCTAssertFalse(capture.assets.contains { $0.type.rawValue == "NSStringPboardType" })
        XCTAssertNotNil(capture.data(for: .string))
    }

    /// Rich text over the cap keeps only plain text, so a single record can't eat several MB
    func testOversizedClipKeepsOnlyPlainText() throws {
        // The cap is a constant (mutable global state isn't safe under Swift 6), so build a clip
        // that exceeds it directly
        let pb = freshPasteboard()
        pb.clearContents()
        pb.setData(Data(repeating: 0x41, count: PasteboardReader.maximumClipBytes + 1), forType: .rtf)
        pb.setString("short", forType: .string)
        let capture = try XCTUnwrap(PasteboardReader.capture(from: pb))
        XCTAssertEqual(capture.assets.map(\.type), [.string])
    }
}
