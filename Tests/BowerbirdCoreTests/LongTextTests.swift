import AppKit
import GRDB
import XCTest
@testable import BowerbirdCore

/// Very long text: stored only once, not read in full for the list, and still pasted in full.
final class LongTextTests: XCTestCase {
    var dir: URL!
    var store: HistoryStore!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bowerbird-long-\(UUID().uuidString)", isDirectory: true)
        store = try HistoryStore(databaseURL: dir.appendingPathComponent("history.sqlite"),
                                 imagesDirectory: dir.appendingPathComponent("images", isDirectory: true))
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: dir)
    }

    private func longText(_ bytes: Int = 1_000_000) -> String {
        var text = "开头能搜到的句子 "
        let chunk = "The quick brown fox 跳过那只懒狗 0123456789 "
        while text.utf8.count < bytes { text += chunk }
        return text
    }

    private func record(_ text: String) throws -> ClipItem {
        try store.record(ClipCapture(assets: [.init(type: .string, data: Data(text.utf8))],
                                      kind: .text, text: text), sourceBundleID: nil)
    }

    /// The plain-text representation is byte-for-byte identical to content, so it isn't stored again
    func testPlainTextIsStoredOnce() throws {
        let text = longText()
        let item = try record(text)
        let id = try XCTUnwrap(item.id)

        let row = try XCTUnwrap(try store.dbQueue.read { db in
            try ClipAsset.filter(Column("item_id") == id).fetchOne(db)
        })
        XCTAssertNil(row.value, "shouldn't be inlined in the database again")
        XCTAssertNil(row.fileName, "nor spilled into assets/")
        XCTAssertEqual(row.byteSize, text.utf8.count, "byte count is recorded as is; the UI displays it")

        let spilled = (try? FileManager.default.contentsOfDirectory(atPath: store.assetsDirectory.path)) ?? []
        XCTAssertTrue(spilled.isEmpty, "assets directory should be empty: \(spilled)")

        // What gets pasted is still the complete body
        let assets = try store.assets(for: id)
        XCTAssertEqual(assets.map(\.type), [.string])
        XCTAssertEqual(String(decoding: assets[0].data, as: UTF8.self), text)
    }

    /// The body in the list is truncated, so a multi-MB item isn't loaded into memory in full
    func testListTruncatesTheBody() throws {
        let text = longText()
        _ = try record(text)
        let listed = try XCTUnwrap(try store.fetchRecent().first)
        XCTAssertEqual(listed.content.count, ClipItem.previewCharacterLimit)
        XCTAssertNil(listed.searchText, "the UI never reads search_text, so the list shouldn't fetch it")
        // Fetching the whole item still gives the full text
        let full = try XCTUnwrap(try store.item(id: try XCTUnwrap(listed.id)))
        XCTAssertEqual(full.content, text)
    }

    /// The search index is capped, but the opening passage is still searchable
    func testSearchIndexIsCapped() throws {
        let text = longText(600_000)
        let item = try record(text)
        XCTAssertEqual(try store.search("开头能搜到的句子").count, 1)

        let indexed = try store.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT length(search_text) FROM clip_item WHERE id = ?",
                             arguments: [item.id]) ?? 0
        }
        XCTAssertLessThanOrEqual(indexed, HistoryStore.searchIndexLimit)
    }

    /// A 4 MB text should take about 4 MB on disk, not three copies
    func testOneCopyOnDisk() throws {
        let text = longText(4_000_000)
        _ = try record(text)
        let dbBytes = (try FileManager.default.attributesOfItem(
            atPath: dir.appendingPathComponent("history.sqlite").path)[.size] as? Int) ?? 0
        XCTAssertLessThan(dbBytes, text.utf8.count * 3 / 2,
                          "database file is \(dbBytes) bytes, original text is \(text.utf8.count) bytes")
    }
}
