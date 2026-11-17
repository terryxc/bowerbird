import Foundation
import GRDB
import XCTest
@testable import BowerbirdCore

final class PasteboardItemMigrationTests: XCTestCase {
    func testUpgradeKeepsOldAssetsAndTheirLegacyBoundaryFallback() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let images = root.appendingPathComponent("images")
        let database = root.appendingPathComponent("history.sqlite")
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        let queue = try DatabaseQueue(path: database.path)
        try Migrations.migrator(imagesDirectory: images, assetsDirectory: root.appendingPathComponent("assets"))
            .migrate(queue, upTo: "v8_list_order_index")
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO clip_item (id, kind, content, content_hash, created_at)
                VALUES (1, 'text', 'old text', 'old hash', ?)
                """, arguments: [Date()])
            try db.execute(sql: """
                INSERT INTO clip_asset (item_id, type, value, ordinal, byte_size)
                VALUES (1, 'public.utf8-plain-text', ?, 0, 8)
                """, arguments: [Data("old text".utf8)])
        }
        try queue.close()
        let store = try HistoryStore(databaseURL: database, imagesDirectory: images)
        let assets = try store.assets(for: 1)
        XCTAssertEqual(assets.count, 1)
        XCTAssertEqual(assets.first?.data, Data("old text".utf8))
        XCTAssertNil(assets.first?.pasteboardItemIndex)
    }

    func testBoundaryChangesDoNotDeduplicateDifferentClips() {
        func capture(htmlIndex: Int) -> ClipCapture {
            ClipCapture(assets: [
                .init(type: .string, data: Data("first".utf8), pasteboardItemIndex: 0),
                .init(type: .html, data: Data("<b>second</b>".utf8), pasteboardItemIndex: htmlIndex),
                .init(type: .string, data: Data("second".utf8), pasteboardItemIndex: 1),
            ], kind: .text, text: "first")
        }
        XCTAssertNotEqual(capture(htmlIndex: 0).contentHash, capture(htmlIndex: 1).contentHash)
    }

    func testSingleItemHashesStayCompatibleWithExistingHistory() {
        let old = ClipCapture(assets: [.init(type: .string, data: Data("text".utf8))], kind: .text, text: "text")
        let new = ClipCapture(assets: [.init(type: .string, data: Data("text".utf8), pasteboardItemIndex: 0)],
                              kind: .text, text: "text")
        XCTAssertEqual(old.contentHash, new.contentHash)
    }
}
