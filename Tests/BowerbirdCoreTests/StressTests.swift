import AppKit
import XCTest
@testable import BowerbirdCore

/// Stress tests. They don't assert correctness; they measure what happens at scale so we don't have to guess.
///
/// Run with `swift test --filter StressTests`. The numbers are printed to the output;
/// assertions only catch clearly unacceptable orders of magnitude, so machine speed won't cause false failures.
final class StressTests: XCTestCase {
    var store: HistoryStore!
    var imagesDir: URL!

    override func setUpWithError() throws {
        imagesDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bowerbird-stress-\(UUID().uuidString)", isDirectory: true)
        let dbURL = imagesDir.appendingPathComponent("history.sqlite")
        try FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        store = try HistoryStore(databaseURL: dbURL, imagesDirectory: imagesDir)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: imagesDir)
        try? FileManager.default.removeItem(at: store.assetsDirectory)
    }

    private func ms(_ block: () throws -> Void) rethrows -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        try block()
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    private func textClip(_ text: String) -> ClipCapture {
        ClipCapture(assets: [.init(type: .string, data: Data(text.utf8))],
                    kind: .text, text: text)
    }

    /// Do paging and search still hold up with 10,000 items in the store?
    func testTenThousandItems() throws {
        let count = 10_000
        let insert = try ms {
            for i in 0..<count {
                _ = try store.record(textClip("条目 \(i) 一些用来占位的内容 item-\(i)"),
                                     sourceBundleID: "com.apple.dt.Xcode")
            }
        }
        print("[stress] Wrote \(count) items: \(String(format: "%.0f", insert)) ms, "
              + "average \(String(format: "%.2f", insert / Double(count))) ms/item")

        var page: [ClipItem] = []
        let firstPage = try ms { page = try store.fetchRecent(limit: 100, offset: 0) }
        XCTAssertEqual(page.count, 100)
        print("[stress] First page of 100: \(String(format: "%.2f", firstPage)) ms")

        let deepPage = try ms { page = try store.fetchRecent(limit: 100, offset: 9_000) }
        print("[stress] Page after item 9000: \(String(format: "%.2f", deepPage)) ms")

        var hits: [ClipItem] = []
        let search = try ms { hits = try store.search("item-9999", limit: 100) }
        XCTAssertFalse(hits.isEmpty)
        print("[stress] Full search, \(hits.count) hits: \(String(format: "%.2f", search)) ms")

        let miss = try ms { _ = try store.search("这个词一定搜不到xyzzy", limit: 100) }
        print("[stress] Full search, no hits: \(String(format: "%.2f", miss)) ms")

        // The panel calls this on every selection change, so it must take microseconds
        let id = try XCTUnwrap(page.first?.id)
        let summary = try ms { _ = try store.assetSummaries(for: id) }
        print("[stress] Representation summary for one item: \(String(format: "%.3f", summary)) ms")

        XCTAssertLessThan(firstPage, 200, "The first page should take under 200ms")
        XCTAssertLessThan(search, 2_000, "A full search should take under 2s")
    }

    /// One huge text item. The preview renders only the first 20,000 characters, but storing,
    /// searching and the list title all have to cope.
    func testVeryLargeTextClip() throws {
        let paragraph = "这是一段用来撑体积的中文内容，混一点 ASCII padding text。"
        let big = String(repeating: paragraph, count: 40_000)   // about 2 MB
        print("[stress] Large text \(big.utf8.count / 1024) KB, \(big.count) characters")

        var item: ClipItem?
        let insert = try ms { item = try store.record(textClip(big), sourceBundleID: nil) }
        print("[stress] Storing large text: \(String(format: "%.0f", insert)) ms")

        let fetched = try ms { _ = try store.fetchRecent(limit: 50) }
        print("[stress] Fetching 50 with that item in the store: \(String(format: "%.2f", fetched)) ms")

        // Preview truncation
        let shown = String(try XCTUnwrap(item).content.prefix(20_000))
        XCTAssertEqual(shown.count, 20_000)

        let search = try ms { _ = try store.search("padding", limit: 50) }
        print("[stress] Search with large text present: \(String(format: "%.2f", search)) ms")
    }

    /// Rich text over the limit keeps only plain text, so one item can't blow up the store
    func testOversizedRichClipIsTrimmed() throws {
        // The limit is a constant (mutable global state isn't safe under Swift 6), so test with data that exceeds it
        let pb = NSPasteboard(name: .init("bowerbird.stress.\(UUID().uuidString)"))
        pb.clearContents()
        pb.setData(Data(repeating: 0x41, count: 8 * 1024 * 1024), forType: .rtf)
        pb.setString("短短的纯文本", forType: .string)
        let capture = try XCTUnwrap(PasteboardReader.capture(from: pb))

        XCTAssertEqual(capture.assets.map(\.type), [.string],
                       "8 MB of RTF must be dropped, keeping only plain text")
        print("[stress] 8 MB rich text stored as only \(capture.storedBytes) bytes")
    }

    /// Large image. The size-limit rule only covers text; images are stored in full, so measure the cost.
    func testLargeImageClip() throws {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4_000, pixelsHigh: 3_000,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        for i in 0..<60 {
            NSColor(calibratedHue: CGFloat(i) / 60, saturation: 0.7, brightness: 0.9, alpha: 1).setFill()
            NSBezierPath(rect: NSRect(x: i * 67, y: 0, width: 67, height: 3_000)).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        let png = rep.representation(using: .png, properties: [:])!
        print("[stress] 4000×3000 PNG = \(png.count / 1024) KB")

        let capture = ClipCapture(assets: [.init(type: .png, data: png)],
                                  kind: .image, text: "", imageSize: CGSize(width: 4_000, height: 3_000))
        var item: ClipItem?
        let insert = try ms { item = try store.record(capture, sourceBundleID: nil) }
        print("[stress] Storing large image: \(String(format: "%.0f", insert)) ms")

        let id = try XCTUnwrap(item?.id)
        let summary = try ms { _ = try store.assetSummaries(for: id) }
        let full = try ms { _ = try store.assets(for: id) }
        print("[stress] Large image: summary \(String(format: "%.3f", summary)) ms, "
              + "reading all content \(String(format: "%.1f", full)) ms")
        XCTAssertLessThan(summary, 5, "The summary must not touch content and must take microseconds")
    }
}
