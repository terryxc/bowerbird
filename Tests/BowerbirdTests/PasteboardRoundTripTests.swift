import AppKit
import BowerbirdCore
import XCTest
@testable import Bowerbird

@MainActor
final class PasteboardRoundTripTests: XCTestCase {
    private func roundTrip(_ originals: [NSPasteboardItem],
                           check: ([NSPasteboardItem]) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(databaseURL: root.appendingPathComponent("history.sqlite"),
                                     imagesDirectory: root.appendingPathComponent("images"))
        let source = NSPasteboard.withUniqueName()
        let destination = NSPasteboard.withUniqueName()
        defer { source.releaseGlobally(); destination.releaseGlobally() }
        XCTAssertTrue(source.writeObjects(originals))
        let capture = try XCTUnwrap(PasteboardReader.capture(from: source))
        let item = try store.record(capture, sourceBundleID: nil)
        let assets = try store.assets(for: XCTUnwrap(item.id))
        Paster.writeAssets(assets, to: destination)
        try check(try XCTUnwrap(destination.pasteboardItems))
    }

    func testDifferentFormatsStayWithTheirOriginalItems() throws {
        let first = NSPasteboardItem()
        first.setString("first", forType: .string)
        let second = NSPasteboardItem()
        second.setString("second", forType: .string)
        second.setString("<b>second</b>", forType: .html)
        try roundTrip([first, second]) { items in
            XCTAssertEqual(items.count, 2)
            guard items.count == 2 else { return }
            XCTAssertEqual(items[0].string(forType: .string), "first")
            XCTAssertNil(items[0].data(forType: .html))
            XCTAssertEqual(items[1].string(forType: .string), "second")
            XCTAssertEqual(items[1].string(forType: .html), "<b>second</b>")
        }
    }

    func testAliasInOneItemIsNotDroppedByCanonicalTypeInAnother() throws {
        let first = NSPasteboardItem()
        first.setString("first", forType: .string)
        first.setString("{\\rtf1 first}", forType: .rtf)
        let second = NSPasteboardItem()
        second.setString("second", forType: .string)
        second.setString("{\\rtf1 second}", forType: .init("com.trolltech.anymime.text--rtf"))
        try roundTrip([first, second]) { items in
            XCTAssertEqual(items.count, 2)
            guard items.count == 2 else { return }
            XCTAssertEqual(items[1].string(forType: .rtf), "{\\rtf1 second}")
        }
    }

    func testPNGInOneItemDoesNotDiscardTIFFInAnother() throws {
        func bitmap(width: Int) throws -> NSBitmapImageRep {
            try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: 2,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        }
        let first = NSPasteboardItem()
        first.setData(try XCTUnwrap(bitmap(width: 2).representation(using: .png, properties: [:])), forType: .png)
        let second = NSPasteboardItem()
        second.setData(try XCTUnwrap(bitmap(width: 3).tiffRepresentation), forType: .tiff)
        try roundTrip([first, second]) { items in
            XCTAssertEqual(items.count, 2)
            guard items.count == 2 else { return }
            let data = try XCTUnwrap(items[1].data(forType: .png) ?? items[1].data(forType: .tiff))
            XCTAssertEqual(NSBitmapImageRep(data: data)?.pixelsWide, 3)
        }
    }

    func testFilteredItemsDoNotCreateEmptyItemsOnReplay() {
        let destination = NSPasteboard.withUniqueName()
        defer { destination.releaseGlobally() }
        Paster.writeAssets([.init(type: .string, data: Data("kept".utf8), pasteboardItemIndex: 3)],
                           to: destination)
        XCTAssertEqual(destination.pasteboardItems?.count, 1)
        XCTAssertEqual(destination.string(forType: .string), "kept")
    }

    func testLegacyCapturesStillReplayMultipleFiles() {
        let destination = NSPasteboard.withUniqueName()
        defer { destination.releaseGlobally() }
        Paster.writeAssets([
            .init(type: .fileURL, data: Data("file:///tmp/a.txt".utf8)),
            .init(type: .fileURL, data: Data("file:///tmp/b.txt".utf8)),
        ], to: destination)
        XCTAssertEqual(destination.pasteboardItems?.count, 2)
        XCTAssertEqual(destination.pasteboardItems?.last?.string(forType: .fileURL), "file:///tmp/b.txt")
    }
}
