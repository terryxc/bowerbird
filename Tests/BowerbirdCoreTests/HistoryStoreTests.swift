import AppKit
import GRDB
import XCTest
@testable import BowerbirdCore

final class HistoryStoreTests: XCTestCase {
    var store: HistoryStore!
    var imagesDir: URL!
    var root: URL!

    override func setUpWithError() throws {
        // Each test gets its own directory with images inside it. Pointing images straight at
        // $TMPDIR would make assetsDirectory resolve to a shared $TMPDIR/assets: tests delete each
        // other's files, running one on its own fails, and the orphan cleanup even deletes other
        // people's files in the user's temp directory.
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bowerbird-tests-\(UUID().uuidString)", isDirectory: true)
        imagesDir = root.appendingPathComponent("images", isDirectory: true)
        store = try HistoryStore(databaseURL: nil, imagesDirectory: imagesDir)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }


    // MARK: Helpers for building captures

    private func textCapture(_ text: String) -> ClipCapture {
        ClipCapture(assets: [.init(type: .string, data: Data(text.utf8))],
                    kind: .text, text: text)
    }

    /// `%` and `_` in a query are literal characters, not LIKE wildcards
    func testSearchTreatsPercentAndUnderscoreLiterally() throws {
        let underscore = try store.record(textCapture("let my_var = 1"), sourceBundleID: nil)
        _ = try store.record(textCapture("let myXvar = 1"), sourceBundleID: nil)
        let percent = try store.record(textCapture("up 100% today"), sourceBundleID: nil)
        _ = try store.record(textCapture("100 apples"), sourceBundleID: nil)

        let exactIDs: (String) throws -> [Int64?] = { query in
            let page = try self.store.searchPage(query)
            return page.items.filter { !page.fuzzyIDs.contains($0.id!) }.map(\.id)
        }
        XCTAssertEqual(try exactIDs("my_var"), [underscore.id])
        XCTAssertEqual(try exactIDs("100%"), [percent.id])
    }

    private func imageCapture(_ png: Data, width: Int, height: Int) -> ClipCapture {
        ClipCapture(assets: [.init(type: .png, data: png)], kind: .image, text: "",
                    imageSize: CGSize(width: width, height: height))
    }

    private func fileCapture(_ urls: [URL]) -> ClipCapture {
        let assets = urls.map { ClipCapture.Asset(type: .fileURL, data: $0.dataRepresentation) }
        let size = urls.reduce(0) { acc, url in
            acc + (((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int) ?? 0)
        }
        _ = size
        return ClipCapture(assets: assets, kind: .file, text: "",
                           filePaths: urls.map(\.path))
    }

    func testRecordTextAndFetchRecent() throws {
        let item = try store.record(textCapture("hello"), sourceBundleID: "com.apple.Terminal")
        XCTAssertNotNil(item.id)
        XCTAssertEqual(item.kind, .text)
        XCTAssertEqual(item.byteSize, 5)
        let all = try store.fetchRecent()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all[0].content, "hello")
        XCTAssertEqual(all[0].sourceBundleID, "com.apple.Terminal")
    }

    func testFetchRecentIsNewestFirst() throws {
        let t0 = Date(timeIntervalSince1970: 1_000)
        _ = try store.record(textCapture("old"), sourceBundleID: nil, at: t0)
        _ = try store.record(textCapture("new"), sourceBundleID: nil, at: t0.addingTimeInterval(10))
        XCTAssertEqual(try store.fetchRecent().map(\.content), ["new", "old"])
    }

    func testDuplicateBumpsToTopWithoutNewRow() throws {
        let t0 = Date(timeIntervalSince1970: 1_000)
        let first = try store.record(textCapture("dup"), sourceBundleID: "a", at: t0)
        _ = try store.record(textCapture("other"), sourceBundleID: "a", at: t0.addingTimeInterval(1))
        let again = try store.record(textCapture("dup"), sourceBundleID: "b", at: t0.addingTimeInterval(2))
        XCTAssertEqual(first.id, again.id)
        let all = try store.fetchRecent()
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(all[0].content, "dup")
        XCTAssertEqual(all[0].sourceBundleID, "b")
    }

    func testDeleteRemovesRow() throws {
        let item = try store.record(textCapture("bye"), sourceBundleID: nil)
        try store.delete(id: item.id!)
        XCTAssertEqual(try store.fetchRecent().count, 0)
    }

    func testTextTitleIsFirstLineTrimmed() throws {
        let item = try store.record(textCapture("  first line \nsecond"), sourceBundleID: nil)
        XCTAssertEqual(item.displayTitle, "first line")
    }

    private func tinyPNG() -> Data {
        // 2x2 solid-colour PNG, drawn on the fly with CoreGraphics to avoid checking in a binary file
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        for x in 0..<2 { for y in 0..<2 { rep.setColor(.red, atX: x, y: y) } }
        return rep.representation(using: .png, properties: [:])!
    }

    func testRecordImageWritesFileAndTitle() throws {
        let png = tinyPNG()
        let item = try store.record(imageCapture(png, width: 2, height: 2), sourceBundleID: nil)
        XCTAssertEqual(item.kind, .image)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.imageURL(for: item).path))
        XCTAssertEqual(try Data(contentsOf: store.imageURL(for: item)), png)
        XCTAssertNil(item.ocrText)
        XCTAssertTrue(item.displayTitle.hasPrefix("Image: 2×2 ("))
    }

    /// Image and file titles follow the current language, including for items recorded earlier
    func testImageAndFileTitlesFollowTheCurrentLanguage() throws {
        let image = try store.record(imageCapture(tinyPNG(), width: 2, height: 2), sourceBundleID: nil)
        let file = try store.record(fileCapture([URL(fileURLWithPath: "/tmp/a.pdf")]), sourceBundleID: nil)
        let english = CoreLocalization.provider
        defer { CoreLocalization.provider = english }
        CoreLocalization.provider = { key, args in
            let zh = ["Image: %@×%@ (%@)": "图片：%@×%@（%@）", "File: %@": "文件：%@"][key] ?? key
            return String(format: zh, arguments: args)
        }
        let listed = try store.fetchRecent(limit: 10)
        XCTAssertTrue(try XCTUnwrap(listed.first { $0.id == image.id }).displayTitle.hasPrefix("图片：2×2（"))
        XCTAssertEqual(try XCTUnwrap(listed.first { $0.id == file.id }).displayTitle, "文件：a.pdf")
    }

    func testDeleteImageRemovesFile() throws {
        let item = try store.record(imageCapture(tinyPNG(), width: 2, height: 2), sourceBundleID: nil)
        let url = store.imageURL(for: item)
        try store.delete(id: item.id!)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testRecordFilesStoresPathsAndTitle() throws {
        let a = imagesDir.appendingPathComponent("悉尼中转酒店.pdf")
        try Data("x".utf8).write(to: a)
        let one = try store.record(fileCapture([a]), sourceBundleID: "com.apple.finder")
        XCTAssertEqual(one.kind, .file)
        XCTAssertEqual(one.filePaths, [a.path])
        XCTAssertEqual(one.displayTitle, "File: 悉尼中转酒店.pdf")
        XCTAssertEqual(one.byteSize, 1)

        let b = imagesDir.appendingPathComponent("b.txt")
        try Data("yy".utf8).write(to: b)
        let two = try store.record(fileCapture([a, b]), sourceBundleID: nil)
        XCTAssertEqual(two.displayTitle, "File: 悉尼中转酒店.pdf and 1 more")
        XCTAssertEqual(two.byteSize, 3)
    }

    func testSearchMatchesTextSubstring() throws {
        _ = try store.record(textCapture("brew install --cask maccy"), sourceBundleID: nil)
        _ = try store.record(textCapture("unrelated"), sourceBundleID: nil)
        XCTAssertEqual(try store.search("cask").map(\.content), ["brew install --cask maccy"])
    }

    func testSearchMatchesFileName() throws {
        let a = imagesDir.appendingPathComponent("悉尼中转酒店.pdf")
        try Data("x".utf8).write(to: a)
        _ = try store.record(fileCapture([a]), sourceBundleID: nil)
        XCTAssertEqual(try store.search("悉尼").count, 1)
    }

    func testSearchMatchesImageDimensionsAndOCR() throws {
        let item = try store.record(imageCapture(tinyPNG(), width: 2, height: 2), sourceBundleID: nil)
        XCTAssertEqual(try store.search("2x2").count, 1)
        // "image" is no longer a search term: it is the English UI title, and matching against it
        // would make letters like a, e, g hit every image
        XCTAssertEqual(try store.search("image").count, 0)
        XCTAssertEqual(try store.search("发票").count, 0)
        try store.setOCRText(id: item.id!, "这是一张发票")
        XCTAssertEqual(try store.search("发票").count, 1)
    }

    /// Every size contains an "x" and most contain any given digit; neither alone is a size
    func testASingleLetterOrDigitDoesNotMatchEveryImageBySize() throws {
        _ = try store.record(imageCapture(tinyPNG(), width: 1920, height: 1080), sourceBundleID: nil)
        XCTAssertEqual(try store.search("x").count, 0)
        XCTAssertEqual(try store.search("1").count, 0)
        XCTAssertEqual(try store.search("1920").count, 1)
        XCTAssertEqual(try store.search("1920x").count, 1)
        XCTAssertEqual(try store.search("20x10").count, 1)
    }

    /// The same content arriving from two threads at once is one row, and neither call fails.
    /// The duplicate check and the insert used to be separate transactions: both callers found
    /// nothing, and the second insert broke the unique hash and the capture was dropped.
    func testRecordingTheSameContentConcurrentlyKeepsOneRow() throws {
        let store = self.store!
        let capture = textCapture("copied twice at once")
        let failures = Counter()
        for _ in 0..<20 {
            try store.clearAll()
            DispatchQueue.concurrentPerform(iterations: 8) { _ in
                do { _ = try store.record(capture, sourceBundleID: nil) } catch { failures.increment() }
            }
            XCTAssertEqual(try store.fetchRecent().count, 1)
        }
        XCTAssertEqual(failures.value, 0)
    }

    func testSearchKeepsPinnedFirst() throws {
        let t0 = Date(timeIntervalSince1970: 1_000)
        let old = try store.record(textCapture("apple old"), sourceBundleID: nil, at: t0)
        _ = try store.record(textCapture("apple new"), sourceBundleID: nil, at: t0.addingTimeInterval(5))
        try store.setPinned(id: old.id!, true)
        XCTAssertEqual(try store.search("apple").map(\.content), ["apple old", "apple new"])
    }

    func testPinnedItemsComeFirstThenNewestFirst() throws {
        let t0 = Date(timeIntervalSince1970: 1_000)
        let a = try store.record(textCapture("a"), sourceBundleID: nil, at: t0)
        let b = try store.record(textCapture("b"), sourceBundleID: nil, at: t0.addingTimeInterval(1))
        _ = try store.record(textCapture("c"), sourceBundleID: nil, at: t0.addingTimeInterval(2))
        try store.setPinned(id: a.id!, true)
        try store.setPinned(id: b.id!, true)
        XCTAssertEqual(try store.fetchRecent().map(\.content), ["b", "a", "c"])
        try store.setPinned(id: b.id!, false)
        XCTAssertEqual(try store.fetchRecent().map(\.content), ["a", "c", "b"])
    }

    func testPinnedFlagSurvivesDuplicateBump() throws {
        let a = try store.record(textCapture("keep"), sourceBundleID: nil)
        try store.setPinned(id: a.id!, true)
        let again = try store.record(textCapture("keep"), sourceBundleID: nil)
        XCTAssertTrue(again.pinned)
    }

    func testPurgeUsesSeparateDaysAndSkipsPinned() throws {
        let now = Date(timeIntervalSince1970: 100 * 86_400)
        let policy = RetentionPolicy(textDays: 30, imageDays: 7, fileDays: 30)
        _ = try store.record(textCapture("old text"), sourceBundleID: nil, at: now.addingTimeInterval(-31 * 86_400))
        _ = try store.record(textCapture("fresh text"), sourceBundleID: nil, at: now.addingTimeInterval(-29 * 86_400))
        let oldImage = try store.record(imageCapture(tinyPNG(), width: 2, height: 2), sourceBundleID: nil,
                                        at: now.addingTimeInterval(-8 * 86_400))
        let oldImageURL = store.imageURL(for: oldImage)
        let pinned = try store.record(textCapture("pinned old"), sourceBundleID: nil, at: now.addingTimeInterval(-400 * 86_400))
        try store.setPinned(id: pinned.id!, true)

        let removed = try store.purge(policy: policy, now: now)
        XCTAssertEqual(removed, 2)
        XCTAssertEqual(Set(try store.fetchRecent().map(\.content)), ["fresh text", "pinned old"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldImageURL.path))
    }

    func testPurgeRemovesOrphanImageFiles() throws {
        let orphan = imagesDir.appendingPathComponent("orphan.png")
        try tinyPNG().write(to: orphan)
        _ = try store.purge(policy: .default)
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
    }

    func testStatsAndClearAll() throws {
        _ = try store.record(textCapture("a"), sourceBundleID: nil)
        let img = try store.record(imageCapture(tinyPNG(), width: 2, height: 2), sourceBundleID: nil)
        let stats = try store.stats()
        XCTAssertEqual(stats.count, 2)
        XCTAssertEqual(stats.imageCount, 1)
        XCTAssertGreaterThan(stats.diskBytes, 0)

        try store.clearAll()
        XCTAssertEqual(try store.fetchRecent().count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.imageURL(for: img).path))
        XCTAssertEqual(try store.stats().count, 0)
    }

    /// Pinning means "keep this": no bulk action on the history may take a pinned item along.
    /// Pinned items go only through their own action.
    func testClearingHistoryKeepsPinnedAndClearingPinnedTakesOnlyThose() throws {
        let keep = try store.record(textCapture("pinned"), sourceBundleID: nil)
        try store.setPinned(id: keep.id!, true)
        _ = try store.record(textCapture("loose"), sourceBundleID: nil)
        let img = try store.record(imageCapture(tinyPNG(), width: 2, height: 2), sourceBundleID: nil)
        XCTAssertEqual(try store.stats().pinnedCount, 1)

        XCTAssertEqual(try store.clearHistory(), 2, "the loose text and the image")
        XCTAssertEqual(try store.fetchRecent().map(\.id), [keep.id], "the pinned item survives")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.imageURL(for: img).path), "the image file is gone")

        XCTAssertEqual(try store.clearPinned(), 1)
        XCTAssertEqual(try store.fetchRecent().count, 0)
        XCTAssertEqual(try store.stats().pinnedCount, 0)
    }

    func testClearingPinnedLeavesTheHistoryAlone() throws {
        let keep = try store.record(textCapture("pinned"), sourceBundleID: nil)
        try store.setPinned(id: keep.id!, true)
        let loose = try store.record(textCapture("loose"), sourceBundleID: nil)

        XCTAssertEqual(try store.clearPinned(), 1)
        XCTAssertEqual(try store.fetchRecent().map(\.id), [loose.id])
    }

    func testFetchRecentPaginatesWithOffset() throws {
        let t0 = Date(timeIntervalSince1970: 1_000)
        for i in 0..<25 {
            _ = try store.record(textCapture("item \(i)"), sourceBundleID: nil,
                                 at: t0.addingTimeInterval(Double(i)))
        }
        // Newest first, so the first page is 24…15
        let first = try store.fetchRecent(limit: 10)
        XCTAssertEqual(first.map(\.content), (15...24).reversed().map { "item \($0)" })
        let second = try store.fetchRecent(limit: 10, offset: 10)
        XCTAssertEqual(second.map(\.content), (5...14).reversed().map { "item \($0)" })
        // The last page is short of a full batch, which means there is nothing more
        let third = try store.fetchRecent(limit: 10, offset: 20)
        XCTAssertEqual(third.count, 5)
        XCTAssertEqual(try store.fetchRecent(limit: 10, offset: 25).count, 0)
    }

    func testPaginationDoesNotRepeatOrSkipItems() throws {
        let t0 = Date(timeIntervalSince1970: 1_000)
        for i in 0..<37 {
            _ = try store.record(textCapture("row \(i)"), sourceBundleID: nil,
                                 at: t0.addingTimeInterval(Double(i)))
        }
        var collected: [String] = []
        var offset = 0
        while true {
            let page = try store.fetchRecent(limit: 8, offset: offset)
            if page.isEmpty { break }
            collected += page.map(\.content)
            offset += page.count
        }
        XCTAssertEqual(collected.count, 37)
        XCTAssertEqual(Set(collected).count, 37, "Pages must not overlap")
        XCTAssertEqual(collected, (0...36).reversed().map { "row \($0)" })
    }

    func testSearchPaginates() throws {
        let t0 = Date(timeIntervalSince1970: 1_000)
        for i in 0..<15 {
            _ = try store.record(textCapture("needle \(i)"), sourceBundleID: nil,
                                 at: t0.addingTimeInterval(Double(i)))
            _ = try store.record(textCapture("other \(i)"), sourceBundleID: nil,
                                 at: t0.addingTimeInterval(Double(i) + 0.5))
        }
        let first = try store.search("needle", limit: 6)
        let second = try store.search("needle", limit: 6, offset: 6)
        XCTAssertEqual(first.count, 6)
        XCTAssertEqual(second.count, 6)
        XCTAssertTrue(Set(first.map(\.id)).isDisjoint(with: Set(second.map(\.id))))
        XCTAssertEqual(try store.search("needle", limit: 6, offset: 12).count, 3)
    }
    /// For long text with no line breaks, the "first line" is the whole text. Without truncation the
    /// title and content columns would each hold several MB, while the list only shows one line.
    func testTitleIsCappedForHugeSingleLineText() throws {
        let huge = String(repeating: "长文本没有换行", count: 50_000)
        let item = try store.record(
            ClipCapture(assets: [.init(type: .string, data: Data(huge.utf8))],
                        kind: .text, text: huge),
            sourceBundleID: nil)

        XCTAssertEqual(item.title.count, ClipItem.titleLimit)
        XCTAssertEqual(item.content.count, huge.count, "Content must not be truncated too; search uses the full text")
    }

    /// Storage stats must include large representations spilled to disk. Counting only the images
    /// directory badly under-reports: RTF, HTML and web archives over 256 KB all live in assets.
    func testStatsCountSpilledAssets() throws {
        let big = Data(repeating: 0x41, count: ClipAsset.inlineLimit + 200_000)
        _ = try store.record(
            ClipCapture(assets: [.init(type: .rtf, data: big),
                                 .init(type: .string, data: Data("hi".utf8))],
                        kind: .text, text: "hi"),
            sourceBundleID: nil)

        let stats = try store.stats()
        // The test uses an in-memory database, so the database file contributes 0 and usage should
        // cover exactly the spilled copy. Before the fix this was 0: the assets directory wasn't counted at all.
        XCTAssertGreaterThanOrEqual(stats.diskBytes, big.count,
                                    "The spilled copy wasn't counted in usage")
    }

    /// Images are already written out separately for the preview, and both directories name files
    /// by content hash, so without special handling the same image is stored twice verbatim.
    /// In one real library that accounted for 4.2 MB.
    func testImageIsNotStoredTwice() throws {
        // Use noise; a regular pattern compresses to a few dozen KB as PNG and never reaches the spill threshold
        let side = 600
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: side * 4, bitsPerPixel: 32)!
        if let buffer = rep.bitmapData {
            for i in 0..<(side * side * 4) { buffer[i] = UInt8.random(in: 0...255) }
        }
        let png = rep.representation(using: .png, properties: [:])!
        XCTAssertGreaterThan(png.count, ClipAsset.inlineLimit, "The image must be big enough to spill to disk")

        let item = try store.record(
            ClipCapture(assets: [.init(type: .png, data: png)], kind: .image, text: "",
                        imageSize: CGSize(width: 900, height: 900)),
            sourceBundleID: nil)

        let assetFiles = (try? FileManager.default
            .contentsOfDirectory(atPath: store.assetsDirectory.path)) ?? []
        XCTAssertTrue(assetFiles.isEmpty, "assets shouldn't hold another copy; the preview copy is enough")

        // The bytes read back must still be complete
        let restored = try store.assets(for: try XCTUnwrap(item.id))
        XCTAssertEqual(restored.first?.data, png)
    }

    /// The store must still open when it has clip_asset rows pointing at items that no longer exist.
    ///
    /// This isn't hypothetical: deleting from clip_item with the sqlite3 CLI leaves such orphans (the
    /// CLI turns foreign keys off by default, so the cascade doesn't run). Previously the migration
    /// failed and the layer above renamed the whole database and started over, losing all history
    /// over a dozen junk rows.
    func testOpensDespiteOrphanedAssets() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bowerbird-orphan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbURL = dir.appendingPathComponent("history.sqlite")

        do {
            let first = try HistoryStore(databaseURL: dbURL, imagesDirectory: dir)
            _ = try first.record(
                ClipCapture(assets: [.init(type: .string, data: Data("hi".utf8))],
                            kind: .text, text: "hi"),
                sourceBundleID: nil)
        }

        // Simulate a CLI delete: foreign keys off, delete only clip_item, leaving orphans
        let queue = try DatabaseQueue(path: dbURL.path)
        try queue.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA foreign_keys = OFF")
            try db.execute(sql: "DELETE FROM clip_item")
        }
        let orphans = try queue.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM clip_asset") }
        XCTAssertEqual(orphans, 1, "No orphan was created, so this test isn't testing anything")

        // Reopening must not throw
        let reopened = try HistoryStore(databaseURL: dbURL, imagesDirectory: dir)
        XCTAssertEqual(try reopened.fetchRecent().count, 0)
    }

    /// Large representations of expired items in assets/ must be deleted along with them.
    /// Previously only images/ was scanned, so every expired large RTF, HTML or web archive stayed on disk forever.
    func testPurgeRemovesSpilledAssetFiles() throws {
        let big = Data(repeating: 0x41, count: ClipAsset.inlineLimit + 10_000)
        let old = Date().addingTimeInterval(-40 * 86_400)
        _ = try store.record(
            ClipCapture(assets: [.init(type: .rtf, data: big), .init(type: .string, data: Data("x".utf8))],
                        kind: .text, text: "x"),
            sourceBundleID: nil, at: old)
        let before = try FileManager.default.contentsOfDirectory(atPath: store.assetsDirectory.path)
        XCTAssertEqual(before.count, 1, "The large representation should have been spilled to disk")

        let removed = try store.purge(policy: RetentionPolicy(textDays: 30, imageDays: 7, fileDays: 30))
        XCTAssertEqual(removed, 1)
        let after = (try? FileManager.default.contentsOfDirectory(atPath: store.assetsDirectory.path)) ?? []
        XCTAssertTrue(after.isEmpty, "Spilled file wasn't deleted and would stay on disk forever")
    }

    /// A JPEG preview file is named after its real format, and is the same file used for pasting
    func testJPEGPreviewIsNamedJPGAndShared() throws {
        let side = 600
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: side * 4, bitsPerPixel: 32)!
        if let b = rep.bitmapData { for i in 0..<(side * side * 4) { b[i] = UInt8.random(in: 0...255) } }
        let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.95])!
        XCTAssertGreaterThan(jpeg.count, ClipAsset.inlineLimit)

        let item = try store.record(
            ClipCapture(assets: [.init(type: PasteboardTypes.jpeg, data: jpeg)], kind: .image, text: "",
                        imageSize: CGSize(width: side, height: side)),
            sourceBundleID: nil)

        XCTAssertTrue(item.content.hasSuffix(".jpg"), "Preview file name should be .jpg: \(item.content)")
        let assetFiles = (try? FileManager.default.contentsOfDirectory(atPath: store.assetsDirectory.path)) ?? []
        XCTAssertTrue(assetFiles.isEmpty, "Shouldn't store a second copy in assets/")
        XCTAssertEqual(try store.assets(for: try XCTUnwrap(item.id)).first?.data, jpeg)
    }

    // MARK: Search normalisation

    private func recordText(_ t: String) throws -> ClipItem {
        try store.record(ClipCapture(assets: [.init(type: .string, data: Data(t.utf8))],
                                     kind: .text, text: t), sourceBundleID: nil)
    }

    /// "cafe" must find "café" and vice versa; same for case and full-width/half-width
    func testSearchIgnoresDiacriticsCaseAndWidth() throws {
        _ = try recordText("Résumé for the café")
        _ = try recordText("ＦＵＬＬＷＩＤＴＨ text")
        XCTAssertEqual(try store.search("cafe").count, 1)
        XCTAssertEqual(try store.search("CAFÉ").count, 1)
        XCTAssertEqual(try store.search("resume").count, 1)
        XCTAssertEqual(try store.search("fullwidth").count, 1, "Full-width must be findable with half-width")
        XCTAssertEqual(try store.search("xyzzy").count, 0)
    }

    /// OCR text is normalised too: recognised "Café" must be findable with "cafe"
    func testOCRTextIsSearchableAfterFolding() throws {
        let item = try store.record(
            ClipCapture(assets: [.init(type: .png, data: Data([0x89, 0x50, 0x4E, 0x47]))],
                        kind: .image, text: "", imageSize: CGSize(width: 1, height: 1)),
            sourceBundleID: nil)
        try store.setOCRText(id: try XCTUnwrap(item.id), "Grand Café Menu")
        XCTAssertEqual(try store.search("cafe menu").count, 1)
    }

    // MARK: Using an item moves it to the top

    /// After pasting, it moves back to the top, but its "copied at" time must not change
    func testTouchMovesItemToTopWithoutRewritingCreatedAt() throws {
        let older = try store.record(
            ClipCapture(assets: [.init(type: .string, data: Data("older".utf8))], kind: .text, text: "older"),
            sourceBundleID: nil, at: Date().addingTimeInterval(-3_600))
        _ = try recordText("newer")
        XCTAssertEqual(try store.fetchRecent().first?.content, "newer")

        // Explicitly pass a time later than "newer". The whole test runs within the same millisecond;
        // without it the two sort keys would be exactly equal and we'd be testing the tie-break, not the feature.
        try store.touch(id: try XCTUnwrap(older.id), at: Date().addingTimeInterval(5))
        let top = try XCTUnwrap(try store.fetchRecent().first)
        XCTAssertEqual(top.content, "older")
        XCTAssertEqual(top.createdAt.timeIntervalSince1970, older.createdAt.timeIntervalSince1970, accuracy: 1,
                       "created_at is \"copied at\" and must not change")
        XCTAssertNotNil(top.usedAt)
    }

    /// Re-copying something that was pasted before must bring it back to the top.
    ///
    /// used_at records "last pasted out of history", and the list sorts by COALESCE(used_at, created_at).
    /// If re-copying only refreshed created_at, yesterday's paste would pin the item at yesterday's
    /// position: open the panel right after copying and it isn't first, the row sits under a
    /// "Yesterday" section header, while the preview on the right says "copied today". The same
    /// record contradicts itself.
    ///
    /// Frequently used content is exactly what hits this: only pasted items have used_at.
    func testRecopyingSomethingPastedBeforeBringsItBackToTheTop() throws {
        let yesterday = Date().addingTimeInterval(-86_400)
        let repeated = try store.record(textCapture("常用的一段"), sourceBundleID: nil, at: yesterday)
        // Yesterday it was pasted out of history
        try store.touch(id: try XCTUnwrap(repeated.id), at: yesterday.addingTimeInterval(60))
        // Then something else was copied, which sorts ahead of it
        _ = try store.record(textCapture("后来复制的东西"), sourceBundleID: nil,
                             at: Date().addingTimeInterval(-3_600))
        XCTAssertEqual(try store.fetchRecent().first?.content, "后来复制的东西")

        // Now copy that snippet again
        let again = try store.record(textCapture("常用的一段"), sourceBundleID: nil, at: Date())
        XCTAssertEqual(again.id, repeated.id, "Identical content shouldn't create a new row")
        XCTAssertNil(again.usedAt, "After re-copying it shouldn't still carry the previous paste time")
        XCTAssertEqual(try store.fetchRecent().first?.content, "常用的一段")
        // Section headers use sortDate, the preview's "copied at" uses createdAt; both must say the same thing
        let top = try XCTUnwrap(try store.fetchRecent().first)
        XCTAssertEqual(top.sortDate.timeIntervalSince1970,
                       top.createdAt.timeIntervalSince1970, accuracy: 1)
    }

    /// Something in constant use shouldn't expire: purging goes by the most recent use
    func testPurgeKeepsRecentlyUsedOldItem() throws {
        let old = try store.record(
            ClipCapture(assets: [.init(type: .string, data: Data("old but used".utf8))], kind: .text, text: "old but used"),
            sourceBundleID: nil, at: Date().addingTimeInterval(-60 * 86_400))
        try store.touch(id: try XCTUnwrap(old.id))
        let removed = try store.purge(policy: RetentionPolicy(textDays: 30, imageDays: 7, fileDays: 30))
        XCTAssertEqual(removed, 0)
    }

    // MARK: Separate retention for three kinds

    func testFilesExpireOnTheirOwnSchedule() throws {
        let tenDaysAgo = Date().addingTimeInterval(-10 * 86_400)
        let url = URL(fileURLWithPath: "/tmp/x").dataRepresentation
        _ = try store.record(ClipCapture(assets: [.init(type: .fileURL, data: url)], kind: .file, text: "",
                                         filePaths: ["/tmp/x"]), sourceBundleID: nil, at: tenDaysAgo)
        _ = try store.record(ClipCapture(assets: [.init(type: .png, data: Data([0x89, 0x50]))], kind: .image,
                                         text: "", imageSize: CGSize(width: 1, height: 1)),
                             sourceBundleID: nil, at: tenDaysAgo)
        // Images expire after 7 days, files after 30: at 10 days old only the image should go
        let removed = try store.purge(policy: RetentionPolicy(textDays: 30, imageDays: 7, fileDays: 30))
        XCTAssertEqual(removed, 1)
        XCTAssertEqual(try store.fetchRecent().first?.kind, .file)
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
