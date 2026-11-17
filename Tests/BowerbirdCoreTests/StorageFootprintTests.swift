import AppKit
import GRDB
import XCTest
@testable import BowerbirdCore

/// The same content is stored only once, and deleted data really goes back to the disk.
final class StorageFootprintTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bowerbird-footprint-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func fileStore() throws -> HistoryStore {
        try HistoryStore(databaseURL: dir.appendingPathComponent("history.sqlite"),
                         imagesDirectory: dir.appendingPathComponent("images", isDirectory: true))
    }

    private func smallPNG(seed: UInt8 = 0) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 32, bitsPerPixel: 32)!
        if let b = rep.bitmapData { for i in 0..<256 { b[i] = UInt8(truncatingIfNeeded: i) &+ seed } }
        return rep.representation(using: .png, properties: [:])!
    }

    private func imageCapture(_ png: Data, extra: [ClipCapture.Asset] = []) -> ClipCapture {
        ClipCapture(assets: [.init(type: .png, data: png)] + extra, kind: .image, text: "",
                    imageSize: CGSize(width: 8, height: 8))
    }

    private func assetRow(itemID: Int64, type: NSPasteboard.PasteboardType, in store: HistoryStore) throws -> ClipAsset? {
        try store.dbQueue.read { db in
            try ClipAsset.filter(Column("item_id") == itemID && Column("type") == type.rawValue).fetchOne(db)
        }
    }

    /// Images under 256 KB used to be stored twice: once inline in the database, once in images/ for
    /// the preview
    func testSmallImageIsStoredOnce() throws {
        let store = try fileStore()
        let png = smallPNG()
        XCTAssertLessThan(png.count, ClipAsset.inlineLimit)
        let item = try store.record(imageCapture(png), sourceBundleID: nil)
        let id = try XCTUnwrap(item.id)

        let row = try XCTUnwrap(try assetRow(itemID: id, type: .png, in: store))
        XCTAssertNil(row.value, "The database must no longer hold an inline copy")
        XCTAssertTrue(row.inImagesDirectory)
        XCTAssertEqual(row.fileName, item.content)
        XCTAssertEqual(try store.assets(for: id).first?.data, png, "Pasting must still get the original image back")
    }

    /// Small images saved before the change: at launch they switch to referencing the preview file, and
    /// the database shrinks accordingly
    func testExistingInlineDuplicatesAreMergedOnLaunch() throws {
        var store: HistoryStore! = try fileStore()
        let png = smallPNG()
        let item = try store.record(imageCapture(png), sourceBundleID: nil)
        let id = try XCTUnwrap(item.id)
        // Recreate the old layout: representation inlined in the database, migration marker erased
        try store.dbQueue.write { db in
            try db.execute(sql: "UPDATE clip_asset SET value = ?, file_name = NULL, in_images = 0 WHERE item_id = ?",
                           arguments: [png, id])
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v6_unline_inline_images'")
        }
        store = nil

        store = try fileStore()
        let row = try XCTUnwrap(try assetRow(itemID: id, type: .png, in: store))
        XCTAssertNil(row.value)
        XCTAssertTrue(row.inImagesDirectory)
        XCTAssertEqual(try store.assets(for: id).first?.data, png)
    }

    /// With the preview file gone, the copy in the database is the only one left, so the migration must
    /// not touch it
    func testInlineImageIsKeptWhenPreviewFileIsMissing() throws {
        var store: HistoryStore! = try fileStore()
        let png = smallPNG()
        let item = try store.record(imageCapture(png), sourceBundleID: nil)
        let id = try XCTUnwrap(item.id)
        try store.dbQueue.write { db in
            try db.execute(sql: "UPDATE clip_asset SET value = ?, file_name = NULL, in_images = 0 WHERE item_id = ?",
                           arguments: [png, id])
            // Erase the migration marker so it runs again on reopen
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v6_unline_inline_images'")
        }
        try FileManager.default.removeItem(at: store.imageURL(for: item))
        store = nil

        store = try fileStore()
        XCTAssertEqual(try assetRow(itemID: id, type: .png, in: store)?.value, png)
    }

    /// Two items with the same pixels share one preview file; deleting one must not delete the other's
    /// image
    func testDeletingOneOfTwoItemsSharingAPreviewKeepsTheFile() throws {
        let store = try fileStore()
        let png = smallPNG()
        let a = try store.record(imageCapture(png), sourceBundleID: nil)
        let b = try store.record(imageCapture(png, extra: [.init(type: .html, data: Data("<img>".utf8))]),
                                 sourceBundleID: nil)
        XCTAssertNotEqual(a.id, b.id)
        XCTAssertEqual(a.content, b.content)

        try store.delete(id: try XCTUnwrap(a.id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.imageURL(for: b).path))
        XCTAssertEqual(try store.assets(for: try XCTUnwrap(b.id)).first?.data, png)

        try store.delete(id: try XCTUnwrap(b.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.imageURL(for: b).path))
    }

    private func databaseBytes() -> Int {
        let path = dir.appendingPathComponent("history.sqlite").path
        return (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
    }

    private func fill(_ store: HistoryStore, count: Int) throws {
        let filler = String(repeating: "clipboard ", count: 400)
        for i in 0..<count {
            let text = "\(i) \(filler)"
            _ = try store.record(ClipCapture(assets: [.init(type: .string, data: Data(text.utf8))],
                                             kind: .text, text: text),
                                 sourceBundleID: nil, at: Date().addingTimeInterval(Double(i)))
        }
    }

    /// After Clear All the database file must really shrink, not keep a file full of free pages
    func testClearAllGivesSpaceBack() throws {
        let store = try fileStore()
        try fill(store, count: 200)
        let full = databaseBytes()
        // Both thresholds are relative to the size before clearing rather than hard-coded byte counts:
        // adding or dropping an index moves the absolute size by a few percent, and this test asserts
        // "it shrank", not "the database is exactly this big". testClearRecentGivesSpaceBack next to
        // it is written the same way.
        XCTAssertGreaterThan(full, 500_000, "Must really fill it first, or shrinking can't be observed")

        try store.clearAll()
        XCTAssertLessThan(databaseBytes(), full / 10, "\(databaseBytes()) bytes left after clearing")
        XCTAssertEqual(try store.stats().count, 0)
    }

    func testClearRecentGivesSpaceBack() throws {
        let store = try fileStore()
        try fill(store, count: 200)
        let full = databaseBytes()
        XCTAssertEqual(try store.clearRecent(within: 3_600), 200)
        XCTAssertLessThan(databaseBytes(), full / 10)
    }

    /// Compact when expiry cleanup deletes most of the data, not when it deletes only a few items
    func testPurgeCompactsOnlyWhenMostlyEmpty() throws {
        let store = try fileStore()
        let now = Date()
        try fill(store, count: 200)
        // Backdate the first 190 items to 40 days ago
        try store.dbQueue.write { db in
            try db.execute(sql: "UPDATE clip_item SET created_at = ? WHERE id <= 190",
                           arguments: [now.addingTimeInterval(-40 * 86_400)])
        }
        let full = databaseBytes()
        let policy = RetentionPolicy(textDays: 30, imageDays: 30, fileDays: 30)
        XCTAssertEqual(try store.purge(policy: policy, now: now), 190)
        XCTAssertLessThan(databaseBytes(), full / 4)

        let settled = databaseBytes()
        try store.dbQueue.write { db in
            try db.execute(sql: "UPDATE clip_item SET created_at = ? WHERE id = 191",
                           arguments: [now.addingTimeInterval(-40 * 86_400)])
        }
        XCTAssertEqual(try store.purge(policy: policy, now: now), 1)
        XCTAssertEqual(databaseBytes(), settled, "Deleting one item isn't worth rewriting the whole database")
    }
}

final class FileClipTests: XCTestCase {
    private func freshPasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("bowerbird.test.\(UUID().uuidString)"))
    }

    private func icon() -> (tiff: Data, icns: Data) {
        let image = NSWorkspace.shared.icon(for: .plainText)
        image.size = NSSize(width: 128, height: 128)
        return (image.tiffRepresentation!, Data("icns-fake-\(UUID())".utf8))
    }

    /// When Finder copies a file it includes an icns and a TIFF icon, about 1 MB each time; neither
    /// should be stored
    func testFinderIconIsNotStored() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bowerbird-\(UUID()).txt")
        try Data("hi".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let (tiff, icns) = icon()
        let pb = freshPasteboard()
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setData(url.dataRepresentation, forType: .fileURL)
        item.setString(url.lastPathComponent, forType: .string)
        item.setData(icns, forType: PasteboardReader.fileIconType)
        item.setData(tiff, forType: .tiff)
        pb.writeObjects([item])

        let capture = try XCTUnwrap(PasteboardReader.capture(from: pb))
        XCTAssertEqual(capture.kind, .file)
        let types = capture.assets.map(\.type.rawValue)
        XCTAssertTrue(types.contains(NSPasteboard.PasteboardType.fileURL.rawValue))
        XCTAssertFalse(types.contains { $0.contains("icns") || $0 == "CorePasteboardFlavorType 0x69636E73" },
                       "Icon still present: \(types)")
        XCTAssertFalse(capture.assets.contains { PasteFormat.group(for: $0.type) == .image }, "\(types)")
        XCTAssertNil(capture.imageSize)
    }

    /// "File URL + image" without an icns: the image may be the content itself, so keep it
    func testImageNextToFileURLWithoutIconIsKept() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bowerbird-\(UUID()).png")
        let pb = freshPasteboard()
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setData(url.dataRepresentation, forType: .fileURL)
        item.setData(icon().tiff, forType: .tiff)
        pb.writeObjects([item])

        let capture = try XCTUnwrap(PasteboardReader.capture(from: pb))
        XCTAssertTrue(capture.assets.contains { PasteFormat.group(for: $0.type) == .image })
    }

    /// A file item's plain text is one full path per line, not the file name from the pasteboard
    func testPathTextIsOneFullPathPerLine() throws {
        let paths = ["/Users/me/Desktop/报告 终稿.pdf", "/tmp/a.txt"]
        let json = String(decoding: try JSONEncoder().encode(paths), as: UTF8.self)
        let item = ClipItem(kind: .file, content: json, contentHash: "x", sourceBundleID: nil,
                            createdAt: Date(), byteSize: 0, imageWidth: nil, imageHeight: nil,
                            ocrText: nil, pinned: false, title: "")
        XCTAssertEqual(item.pathText, "/Users/me/Desktop/报告 终稿.pdf\n/tmp/a.txt")
    }
}
