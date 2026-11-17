import Foundation
import GRDB
import XCTest
@testable import BowerbirdCore

/// These tests all guard one thing: when the database can't be opened, under what conditions are we
/// allowed to touch the user's existing data.
final class StoreOpenFailureTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("StoreOpenFailureTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeStore() throws -> HistoryStore {
        try HistoryStore(databaseURL: root.appendingPathComponent("history.sqlite"),
                         imagesDirectory: root.appendingPathComponent("images", isDirectory: true))
    }

    /// Locked by another process ≠ broken. This is the core of this change: SQLITE_BUSY must never
    /// trigger a rebuild.
    func testBusyDoesNotJustifyRebuild() {
        for code in [ResultCode.SQLITE_BUSY, .SQLITE_LOCKED] {
            let failure = StoreOpenFailure.classify(DatabaseError(resultCode: code))
            XCTAssertEqual(failure, .busy, "\(code) should be classified as busy")
            XCTAssertFalse(failure.justifiesRebuild, "\(code) shouldn't rename and rebuild the user's database")
        }
    }

    func testCorruptionJustifiesRebuild() {
        for code in [ResultCode.SQLITE_CORRUPT, .SQLITE_NOTADB] {
            let failure = StoreOpenFailure.classify(DatabaseError(resultCode: code))
            XCTAssertEqual(failure, .corrupt)
            XCTAssertTrue(failure.justifiesRebuild)
        }
    }

    /// Disk full, directory not writable and the like: rebuilding doesn't fix those either, so the
    /// database shouldn't be touched.
    func testOtherErrorsDoNotJustifyRebuild() {
        XCTAssertEqual(StoreOpenFailure.classify(DatabaseError(resultCode: .SQLITE_FULL)), .other)
        XCTAssertFalse(StoreOpenFailure.classify(DatabaseError(resultCode: .SQLITE_FULL)).justifiesRebuild)
        // Errors not thrown by GRDB at all (e.g. failing to create the directory) also go to other
        let notDB = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)
        XCTAssertEqual(StoreOpenFailure.classify(notDB), .other)
    }

    /// Actually open a file that isn't SQLite and confirm the end-to-end classification is still
    /// corrupt. This path must keep being able to rebuild, otherwise fixing busy would also break
    /// recovery from corruption.
    func testGarbageFileIsClassifiedCorrupt() throws {
        let db = root.appendingPathComponent("history.sqlite")
        try Data("这不是一个 SQLite 库".utf8).write(to: db)
        XCTAssertThrowsError(try makeStore()) { error in
            XCTAssertEqual(StoreOpenFailure.classify(error), .corrupt)
        }
    }

    /// The on-disk database must use WAL: in delete mode a write needs the whole database exclusively,
    /// so two processes are bound to collide.
    func testFileDatabaseUsesWALAndBusyTimeout() throws {
        let store = try makeStore()
        let mode = try store.dbQueue.read { db in
            try String.fetchOne(db, sql: "PRAGMA journal_mode")
        }
        XCTAssertEqual(mode?.lowercased(), "wal")
        if case .timeout(let seconds) = HistoryStore.fileConfiguration.busyMode {
            XCTAssertGreaterThan(seconds, 0)
        } else {
            XCTFail("hitting a lock must wait a while before failing, not use immediateError")
        }
    }

    /// A second connection (simulating a second instance) reading the same database shouldn't throw
    /// busy immediately.
    func testSecondConnectionCanReadWhileFirstIsOpen() throws {
        let first = try makeStore()
        try first.dbQueue.write { db in try db.execute(sql: "PRAGMA user_version = 1") }
        let second = try makeStore()
        XCTAssertNoThrow(try second.dbQueue.read { db in try ClipItem.fetchCount(db) })
    }
}
