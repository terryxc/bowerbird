import AppKit
import XCTest
@testable import BowerbirdCore

/// The kind filter narrows both the plain list and a search, exact and fuzzy parts alike
final class KindFilterTests: XCTestCase {
    private var root: URL!
    private var store: HistoryStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bowerbird-kind-\(UUID().uuidString)", isDirectory: true)
        store = try HistoryStore(databaseURL: nil,
                                 imagesDirectory: root.appendingPathComponent("images", isDirectory: true))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func text(_ s: String) -> ClipCapture {
        ClipCapture(assets: [.init(type: .string, data: Data(s.utf8))], kind: .text, text: s)
    }

    private func image(_ bytes: [UInt8]) -> ClipCapture {
        ClipCapture(assets: [.init(type: .png, data: Data(bytes))], kind: .image, text: "",
                    imageSize: CGSize(width: 8, height: 8))
    }

    func testRecentListNarrowsToOneKind() throws {
        try store.record(text("receive"), sourceBundleID: nil)
        try store.record(image([0x89, 0x50, 0x4E, 0x47, 1]), sourceBundleID: nil)
        try store.record(text("another"), sourceBundleID: nil)

        XCTAssertEqual(try store.fetchRecent().count, 3, "no filter: everything")
        XCTAssertEqual(try store.fetchRecent(kind: .text).map(\.content), ["another", "receive"])
        XCTAssertEqual(try store.fetchRecent(kind: .image).count, 1)
        XCTAssertEqual(try store.fetchRecent(kind: .file).count, 0)
    }

    func testSearchRespectsTheKindExactAndFuzzy() throws {
        try store.record(text("receive"), sourceBundleID: nil)
        // An image whose recognised text would match both exactly and fuzzily
        let shot = try store.record(image([0x89, 0x50, 0x4E, 0x47, 2]), sourceBundleID: nil)
        try store.setOCRText(id: shot.id!, "receive recieve")

        let all = try store.searchPage("recieve")
        XCTAssertEqual(all.items.map(\.kind), [.image], "the image matches exactly, so the text's fuzzy match stays hidden")
        XCTAssertEqual(try store.searchPage("recieve", kind: .text).items.map(\.content), ["receive"],
                       "text only: nothing exact in that kind, so the fuzzy hit shows")
        XCTAssertEqual(try store.searchPage("recieve", kind: .image).items.map(\.kind), [.image], "exact hit, images only")
        XCTAssertEqual(try store.searchPage("recieve", kind: .file).items.count, 0)
    }
}
