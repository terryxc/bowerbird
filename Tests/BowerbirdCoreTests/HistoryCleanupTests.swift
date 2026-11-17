import Foundation
import XCTest
@testable import BowerbirdCore

final class HistoryCleanupTests: XCTestCase {
    private var root: URL!
    private var store: HistoryStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store = try HistoryStore(databaseURL: root.appendingPathComponent("history.sqlite"),
                                 imagesDirectory: root.appendingPathComponent("images"))
    }

    override func tearDownWithError() throws {
        for directory in [store.imagesDirectory, store.assetsDirectory] {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }
        store = nil
        try FileManager.default.removeItem(at: root)
    }

    func testClearRetriesAttachmentsAfterRowsHaveAlreadyGone() throws {
        let capture = ClipCapture(assets: [
            .init(type: .rtf, data: Data(repeating: 65, count: ClipAsset.inlineLimit + 1)),
        ], kind: .text, text: "recent")
        try store.record(capture, sourceBundleID: nil)
        let files = try FileManager.default.contentsOfDirectory(atPath: store.assetsDirectory.path)
        XCTAssertEqual(files.count, 1)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: store.assetsDirectory.path)

        XCTAssertThrowsError(try store.clearRecent(within: 300))
        XCTAssertEqual(try store.stats().count, 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.assetsDirectory.path), files)

        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: store.assetsDirectory.path)
        XCTAssertEqual(try store.clearRecent(within: 300), 0)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: store.assetsDirectory.path).isEmpty)
    }

    func testFailureInOneDirectoryDoesNotSkipOtherDirectory() throws {
        let blocked = store.imagesDirectory.appendingPathComponent("orphan.png")
        try Data("image".utf8).write(to: blocked)
        try FileManager.default.createDirectory(at: store.assetsDirectory, withIntermediateDirectories: true)
        let removable = store.assetsDirectory.appendingPathComponent("orphan")
        try Data("asset".utf8).write(to: removable)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: store.imagesDirectory.path)

        XCTAssertThrowsError(try store.clearAll())
        XCTAssertTrue(FileManager.default.fileExists(atPath: blocked.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: removable.path))
    }

    func testUnreadableDirectoryIsReportedRatherThanTreatedAsEmpty() throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: store.imagesDirectory.path)
        XCTAssertThrowsError(try store.clearHistory())
    }

    func testMissingAssetDirectoryIsAlreadyClean() throws {
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.assetsDirectory.path))
        XCTAssertNoThrow(try store.clearAll())
    }
}
