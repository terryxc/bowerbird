import AppKit
import Foundation
import GRDB

/// GRDB's DatabaseQueue is thread-safe on its own and every other stored property is a constant,
/// so this object can be passed between threads.
public final class HistoryStore: @unchecked Sendable {
    public let dbQueue: DatabaseQueue
    public let imagesDirectory: URL
    let databaseURL: URL?

    /// How the on-disk database is opened.
    ///
    /// DatabaseQueue defaults to journal_mode=delete plus busyMode=.immediateError, which together
    /// are very hostile to multiple processes: in delete mode a write locks the whole database, and
    /// immediateError means a collision throws SQLITE_BUSY at once, with no retry at all. With two
    /// instances running, the one launched second may not even get through its migrations.
    ///
    /// WAL keeps readers and writers from blocking each other (across processes too), and
    /// busyTimeout gives writes that really do collide time to back off.
    /// The in-memory database needs none of this, so it only applies to the on-disk path.
    static let fileConfiguration: Configuration = {
        var config = Configuration()
        config.journalMode = .wal
        config.busyMode = .timeout(5)
        return config
    }()

    /// Pass nil for databaseURL to get an in-memory database, for tests.
    public init(databaseURL: URL?, imagesDirectory: URL) throws {
        self.databaseURL = databaseURL
        self.imagesDirectory = imagesDirectory
        try FileManager.default.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)
        if let url = databaseURL {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            dbQueue = try DatabaseQueue(path: url.path, configuration: Self.fileConfiguration)
        } else {
            dbQueue = try DatabaseQueue()
        }
        try Migrations.migrator(imagesDirectory: imagesDirectory,
                                assetsDirectory: imagesDirectory.deletingLastPathComponent()
                                    .appendingPathComponent("assets", isDirectory: true))
            .migrate(dbQueue)
        // Older versions didn't compact after clearing, so an upgraded database may be ~98% free pages
        compactIfFragmented()
    }

    /// Normalisation for search: diacritic-insensitive, case-insensitive, and full/half-width
    /// insensitive.
    ///
    /// "cafe" must find "café", "É" must find "é", and "ｃａｆｅ" must find "cafe".
    /// SQLite's LIKE only folds ASCII case, so it can do none of this.
    public static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    /// The search index is built from at most this many characters.
    ///
    /// search_text is a second, folded copy of the body. Without a cap, a 4 MB text is 4 MB twice
    /// over in the database. Search is after the lines you can see, not whatever sits past the
    /// 200,000th character. Alfred makes a similar trade-off for large clipboard contents.
    public static let searchIndexLimit = 200_000

    static func searchText(for item: ClipItem, ocr: String? = nil) -> String {
        let text = item.searchableText
        var out = fold(text.count > searchIndexLimit ? String(text.prefix(searchIndexLimit)) : text)
        let recognized = ocr ?? item.ocrText
        if let recognized, !recognized.isEmpty { out += "\n" + fold(recognized) }
        return out
    }

    /// ~/Library/Application Support/Bowerbird/, or the folder named by BOWERBIRD_DATA_DIR.
    ///
    /// The override exists for screenshots and manual testing: launch the binary with the variable
    /// set and it records into an empty folder instead of the real history.
    public static func standard() throws -> HistoryStore {
        let base: URL
        if let override = ProcessInfo.processInfo.environment["BOWERBIRD_DATA_DIR"], !override.isEmpty {
            base = URL(fileURLWithPath: override, isDirectory: true)
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        } else {
            base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: true)
                .appendingPathComponent("Bowerbird", isDirectory: true)
        }
        return try HistoryStore(databaseURL: base.appendingPathComponent("history.sqlite"),
                                imagesDirectory: base.appendingPathComponent("images", isDirectory: true))
    }

    public var dataDirectory: URL { imagesDirectory.deletingLastPathComponent() }

    public func imageURL(for item: ClipItem) -> URL {
        imagesDirectory.appendingPathComponent(item.content)
    }

    // MARK: Writing

    @discardableResult
    public func record(_ capture: ClipCapture, sourceBundleID: String?, at date: Date = Date()) throws -> ClipItem {
        let hash = capture.contentHash

        // Same content already exists: just bump it to the top. Don't add a row or rewrite all the
        // representations
        if let existing = try dbQueue.write({ db in
            try Self.bumpExisting(db, hash: hash, date: date, sourceBundleID: sourceBundleID)
        }) {
            return existing
        }

        // Images are still written to their own file. That copy is the one the preview reads over
        // and over; it's more convenient as a file than in the database, and it keeps the database small.
        // This is the preview copy. PNG is preferred; if there's only JPEG, store JPEG (converting
        // lossy to lossless only makes it bigger, for no benefit); TIFF was already converted to PNG
        // at capture time. The extension follows the real format. TIFF bytes used to be named .png
        // too, and they only displayed because NSImage sniffs the content.
        var imageFileName: String?
        var previewType: NSPasteboard.PasteboardType?
        if capture.kind == .image {
            let candidates: [(NSPasteboard.PasteboardType, String)] = [
                (.png, "png"), (PasteboardTypes.jpeg, "jpg"), (.tiff, "tiff"),
            ]
            if let (type, ext) = candidates.first(where: { capture.data(for: $0.0) != nil }),
               let bytes = capture.data(for: type) {
                previewType = type
                imageFileName = "\(Hash.sha256(bytes)).\(ext)"
            }
        }

        var item = ClipItem(
            kind: capture.kind,
            content: primaryContent(for: capture, imageFileName: imageFileName),
            contentHash: hash,
            sourceBundleID: sourceBundleID,
            createdAt: date,
            byteSize: capture.displayBytes(previewType: previewType),
            imageWidth: capture.imageSize.map { Int($0.width) },
            imageHeight: capture.imageSize.map { Int($0.height) },
            ocrText: nil,
            pinned: false,
            title: ""
        )
        item.title = item.derivedTitle(text: capture.text)
        item.searchText = Self.searchText(for: item)

        // Writing the file and inserting the row happen in the same write transaction.
        //
        // Done separately, there's a real window: the image file has been written but the row not
        // yet inserted, while expiry cleanup runs "delete unreferenced files" on another thread.
        // The file just written is treated as an orphan and deleted, and the row then points at a
        // file that doesn't exist. The database write lock serves as the mutex for the whole store here.
        let newItem = item
        return try dbQueue.write { db -> ClipItem in
            // Look again, now holding the write lock. The check above ran in its own transaction;
            // the same content recorded from two threads at once (the watcher and "paste the text
            // in an image") both found nothing, and the second insert failed on the unique hash and
            // the capture was dropped.
            if let found = try Self.bumpExisting(db, hash: hash, date: date, sourceBundleID: sourceBundleID) {
                return found
            }
            var item = newItem
            if let imageFileName, let previewType, let bytes = capture.data(for: previewType) {
                let url = self.imagesDirectory.appendingPathComponent(imageFileName)
                if !FileManager.default.fileExists(atPath: url.path) {
                    try bytes.write(to: url, options: .atomic)
                }
            }
            try item.insert(db)
            guard let itemID = item.id else { return item }
            for (index, asset) in capture.assets.enumerated() {
                var stored = try self.persist(asset: asset, itemID: itemID, ordinal: index,
                                              previewFileName: imageFileName, content: item.content)
                stored.pasteboardItemIndex = asset.pasteboardItemIndex
                try stored.insert(db)
            }
            return item
        }
    }

    /// `content` is still the one primary representation used for search and display:
    /// the body for text, the file name for images, a JSON array of paths for files.
    /// The full set of representations lives in `clip_asset`; each has its own job.
    private func primaryContent(for capture: ClipCapture, imageFileName: String?) -> String {
        switch capture.kind {
        case .text:
            return capture.text
        case .image:
            return imageFileName ?? ""
        case .file:
            let data = (try? JSONEncoder().encode(capture.filePaths)) ?? Data()
            return String(decoding: data, as: UTF8.self)
        }
    }

    /// Returns the space taken by deleted records to the disk.
    ///
    /// Deleting rows in SQLite only marks pages as free; the file itself doesn't shrink. After
    /// clearing everything, "Space used" in Settings still showed 434 KB, which was a database full
    /// of free pages. VACUUM rewrites the database and the free pages go away.
    func compact() throws {
        try dbQueue.vacuum()
        // In WAL mode, VACUUM first writes the whole rewritten database into -wal, and the main file
        // only shrinks after a checkpoint. Without this step, "Space used" in Settings still shows a
        // megabyte or two after clearing everything, which is the very reason this method exists.
        // TRUNCATE also resets -wal to zero.
        // writeWithoutTransaction is generic; the result isn't needed here, so discard it
        // explicitly to avoid a warning
        _ = try dbQueue.writeWithoutTransaction { db in try db.checkpoint(.truncate) }
    }

    /// Only compact when more than a quarter of the pages are free.
    ///
    /// Expiry cleanup runs hourly, and rewriting the whole database every time isn't worth it. Pages
    /// freed here and there get reused by later writes; once enough pile up, return them in one go.
    func compactIfFragmented() {
        let (pages, free) = (try? dbQueue.read { db in
            (try Int.fetchOne(db, sql: "PRAGMA page_count") ?? 0,
             try Int.fetchOne(db, sql: "PRAGMA freelist_count") ?? 0)
        }) ?? (0, 0)
        if free > 0, free * 4 >= pages { try? compact() }
    }

    /// Large representations go to disk, small ones inline. A few MB of RTFD in a row bloats the
    /// database and slows queries.
    private func persist(asset: ClipCapture.Asset, itemID: Int64, ordinal: Int,
                         previewFileName: String?, content: String) throws -> ClipAsset {
        // The plain-text representation is byte-for-byte identical to the content column, so storing
        // it twice doubles the space for nothing. Record it as "value lives in content": value and
        // file_name both stay empty, and on read it's taken from that column.
        // Measured on a 4 MB text, this took it from 12 MB to 8 MB (the other half is search_text;
        // see searchIndexLimit).
        if asset.type == .string, asset.data == Data(content.utf8) {
            return ClipAsset(itemID: itemID, type: asset.type.rawValue,
                             ordinal: ordinal, byteSize: asset.data.count)
        }
        // Images already have a copy written for the preview, and both directories name files by
        // content hash, so the same image would be stored twice, byte for byte. In one measured
        // database, 4.2 MB came from exactly this. If the preview copy exists, reference it instead
        // of writing a second one.
        //
        // This must come before the inline check. The size used to be checked first, so images under
        // 256 KB were still inlined into the database, and small images ended up with one copy in the
        // database and one in images/: still two copies.
        if let previewFileName, PasteFormat.group(for: asset.type) == .image,
           previewFileName.hasPrefix(Hash.sha256(asset.data)) {
            return ClipAsset(itemID: itemID, type: asset.type.rawValue,
                             fileName: previewFileName, inImagesDirectory: true,
                             ordinal: ordinal, byteSize: asset.data.count)
        }
        if asset.data.count <= ClipAsset.inlineLimit {
            return ClipAsset(itemID: itemID, type: asset.type.rawValue, value: asset.data,
                             ordinal: ordinal, byteSize: asset.data.count)
        }
        let digest = Hash.sha256(asset.data)

        // This also runs inside record's write transaction, so it's mutually exclusive with orphan
        // cleanup (see the note in record)
        try FileManager.default.createDirectory(at: assetsDirectory, withIntermediateDirectories: true)
        let url = assetsDirectory.appendingPathComponent(digest)
        if !FileManager.default.fileExists(atPath: url.path) {
            try asset.data.write(to: url, options: .atomic)
        }
        return ClipAsset(itemID: itemID, type: asset.type.rawValue, fileName: digest,
                         ordinal: ordinal, byteSize: asset.data.count)
    }

    /// Large representations are stored here
    public var assetsDirectory: URL {
        dataDirectory.appendingPathComponent("assets", isDirectory: true)
    }

    /// Fetches all representations of a history item, in order, for writing back to the pasteboard
    public func assets(for itemID: Int64) throws -> [ClipCapture.Asset] {
        let (rows, content) = try dbQueue.read { db in
            let rows = try ClipAsset
                .filter(Column("item_id") == itemID)
                .order(Column("ordinal"))
                .fetchAll(db)
            let content = try String.fetchOne(db, sql: "SELECT content FROM clip_item WHERE id = ?",
                                              arguments: [itemID]) ?? ""
            return (rows, content)
        }
        return rows.compactMap { row in
            let data: Data?
            if let value = row.value {
                data = value
            } else if let name = row.fileName {
                let directory = row.inImagesDirectory ? imagesDirectory : assetsDirectory
                data = try? Data(contentsOf: directory.appendingPathComponent(name))
            } else if row.type == NSPasteboard.PasteboardType.string.rawValue {
                // The value lives in the content column; see persist
                data = Data(content.utf8)
            } else {
                data = nil
            }
            guard let data, !data.isEmpty else { return nil }
            return ClipCapture.Asset(type: NSPasteboard.PasteboardType(row.type), data: data,
                                     pasteboardItemIndex: row.pasteboardItemIndex)
        }
    }

    /// Fetches only each representation's type and size, without touching the contents.
    ///
    /// The panel recomputes the format bar every time the selection changes. Going through
    /// `assets(for:)` would read the large on-disk representations back in full: holding ↓ across a
    /// run of images or rich text means several MB of main-thread IO per step. The format bar only
    /// needs type and byte count, and the database already has columns for both.
    public func assetSummaries(for itemID: Int64) throws -> [ClipAssetSummary] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT type, byte_size FROM clip_asset WHERE item_id = ? ORDER BY ordinal
                """, arguments: [itemID])
                .map { row in
                    ClipAssetSummary(type: NSPasteboard.PasteboardType(row["type"]),
                                     byteSize: row["byte_size"])
                }
        }
    }

    // MARK: Reading

    /// Fetches one page ordered pinned first, then newest first. offset pages to the next batch.
    /// kind narrows the page to one kind of clip; nil means every kind.
    public func fetchRecent(limit: Int = 200, offset: Int = 0, kind: ClipKind? = nil) throws -> [ClipItem] {
        try dbQueue.read { db in
            try ClipItem
                .select(Self.listColumns)
                .filter(literal: Self.kindClause(kind))
                .order(Column("pinned").desc, SQL("COALESCE(used_at, created_at) DESC").sqlExpression, Column("id").desc)
                .limit(limit, offset: offset)
                .fetchAll(db)
        }
    }

    /// The WHERE fragment for a kind filter; always true when there is none, so it can be ANDed in
    private static func kindClause(_ kind: ClipKind?) -> SQL {
        kind.map { "kind = \($0.rawValue)" } ?? "1"
    }

    /// The columns the list needs.
    ///
    /// The body is truncated to what the preview can use, and `search_text` isn't fetched at all:
    /// it's only compared in SQL and the UI never reads it. Otherwise, if a page of 100 items
    /// contains a few multi-MB texts, every panel open reads them fully into memory, each with an
    /// equally large search_text alongside.
    static var listColumns: [SQLSelectable] { [
        Column("id"), Column("kind"),
        SQL("substr(content, 1, \(ClipItem.previewCharacterLimit)) AS content").sqlExpression,
        Column("content_hash"), Column("source_bundle_id"), Column("created_at"), Column("used_at"),
        Column("byte_size"), Column("image_width"), Column("image_height"),
        Column("ocr_text"), Column("pinned"), Column("title"),
    ] }

    /// Fetches the whole item (body not truncated). Needed for old data from before paste v2.
    public func item(id: Int64) throws -> ClipItem? {
        try dbQueue.read { db in try ClipItem.fetchOne(db, key: id) }
    }

    // MARK: Search

    /// Matches text content, file paths, OCR text, and an image's pixel size ("1920", "4x4").
    public func search(_ query: String, limit: Int = 200, offset: Int = 0) throws -> [ClipItem] {
        try searchPage(query, limit: limit, offset: offset).items
    }

    /// Exact matches, or, only when there are none at all, fuzzy ones.
    ///
    /// The exact part is SQL substring matching, ordered by pinned and time. When nothing matches
    /// exactly and the query is long enough, FuzzyMatcher looks through the most recent few thousand
    /// items for ones that are "off by a letter or two" and ranks them by error count. Fuzzy results
    /// used to be appended whenever the exact page was not full; with five exact hits for "duty" that
    /// put a JSON blob containing "id_type" underneath them, which only looked broken.
    /// Maccy's mixed mode has the same rule: the fuzzy pass is a fallback, never a supplement. Fuzzy
    /// matching only scans the first 1000 characters of each item: someone making a typo is most
    /// likely searching for a line they can see, and scanning all of a multi-MB text isn't worth it.
    /// The row with this content, moved to the top; nil when there is none yet.
    private static func bumpExisting(_ db: Database, hash: String, date: Date,
                                     sourceBundleID: String?) throws -> ClipItem? {
        guard var found = try ClipItem.filter(Column("content_hash") == hash).fetchOne(db) else {
            return nil
        }
        found.createdAt = date
        // used_at must be cleared too, or copying something again won't bring it to the top.
        //
        // used_at records when the item was last pasted out of the history, and the list sorts by
        // COALESCE(used_at, created_at). If something was pasted yesterday and the same content
        // is copied again today, created_at moves forward but used_at stays on yesterday, so the
        // row still sorts into yesterday's section: it sits under the "Yesterday" header while the
        // preview on the right says "copied today". The record contradicts itself. Something just
        // copied is the newest thing there is, and its history starts over from this moment.
        found.usedAt = nil
        found.sourceBundleID = sourceBundleID
        // Write only these three columns. SQLite stores rows whole, so writing the full row back
        // isn't much slower (3.8 ms either way in measurements), but it puts a third more bytes
        // into -wal: copying the same 1 MB text 20 times gave 241 KB vs 160 KB.
        // Changing two timestamps shouldn't touch content and search_text.
        try found.update(db, columns: ["created_at", "used_at", "source_bundle_id"])
        return found
    }

    /// "1920", "4x4", "1920x": digits with at most one x, and at least two characters that pin
    /// something down. A bare "x" or a single digit is not a size anyone is looking for.
    static func looksLikeImageSize(_ query: String) -> Bool {
        let digits = query.filter(\.isASCII).filter(\.isNumber).count
        let separators = query.filter { $0 == "x" }.count
        guard digits + separators == query.count, separators <= 1 else { return false }
        return digits >= 2
    }

    public func searchPage(_ query: String, limit: Int = 200, offset: Int = 0, kind: ClipKind? = nil) throws -> SearchPage {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            return SearchPage(items: try fetchRecent(limit: limit, offset: offset, kind: kind), fuzzyIDs: [])
        }
        let inKind = Self.kindClause(kind)
        // The query goes through the same normalisation, so both sides line up
        let folded = Self.fold(q)
        // `%` and `_` are LIKE wildcards: searching "my_var" used to match "myXvar", and the preview
        // then had nothing to highlight. Escape them (and the escape character) so the query is literal.
        let literal = folded
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        let pattern = "%\(literal)%"
        // Images can also be found by size: typing "1920" or "4x4" both count as a match.
        // Compare against the size only, without the English "image: " prefix. With it, the letters
        // a, e and g would match every image in the database, a single letter would flood the list,
        // and it wouldn't hold once the UI language changes anyway.
        //
        // Only when the query looks like a size, though: every size contains an "x" and most
        // contain any given digit, so "x" or "1" alone used to list every image there is.
        let exact: SQL = Self.looksLikeImageSize(folded)
            ? """
            search_text LIKE \(pattern) ESCAPE '\\'
            OR (kind = 'image' AND (image_width || 'x' || image_height) LIKE \(pattern) ESCAPE '\\')
            """
            : "search_text LIKE \(pattern) ESCAPE '\\'"
        var items = try dbQueue.read { db in
            try ClipItem
                .select(Self.listColumns)
                .filter(literal: exact)
                .filter(literal: inKind)
                .order(Column("pinned").desc, SQL("COALESCE(used_at, created_at) DESC").sqlExpression, Column("id").desc)
                .limit(limit, offset: offset)
                .fetchAll(db)
        }
        guard items.isEmpty, let maxErrors = FuzzyMatcher.allowedErrors(for: folded) else {
            return SearchPage(items: items, fuzzyIDs: [])
        }
        // An empty page past the first one means either "no exact matches at all" (keep paging the
        // fuzzy list) or "the exact matches ran out" (stop). Only a count tells them apart, and it is a
        // full-table LIKE scan, so it runs only here, never on page one.
        if offset > 0 {
            let exactCount = try dbQueue.read { db in
                try ClipItem.filter(literal: exact).filter(literal: inKind).fetchCount(db)
            }
            guard exactCount == 0 else { return SearchPage(items: [], fuzzyIDs: []) }
        }

        let ranked = try fuzzyRanking(folded, maxErrors: maxErrors, excluding: exact, within: inKind)
        let start = min(offset, ranked.count)
        let end = min(start + limit, ranked.count)
        guard start < end else { return SearchPage(items: [], fuzzyIDs: []) }
        let ids = Array(ranked[start..<end])
        let fetched = try dbQueue.read { db in
            try ClipItem.select(Self.listColumns).filter(ids.contains(Column("id"))).fetchAll(db)
        }
        // Arrange in ranking order; SQL's IN doesn't guarantee order
        let byID = Dictionary(uniqueKeysWithValues: fetched.compactMap { item in item.id.map { ($0, item) } })
        items += ids.compactMap { byID[$0] }
        return SearchPage(items: items, fuzzyIDs: Set(ids))
    }

    /// IDs of fuzzy matches, ordered by (error count, pinned, time). Searches at most the most
    /// recent 5000 items.
    private func fuzzyRanking(_ folded: String, maxErrors: Int, excluding exact: SQL, within inKind: SQL) throws -> [Int64] {
        struct Candidate { let id: Int64; let errors: Int; let pinned: Bool; let date: Date }
        let rows = try dbQueue.read { db in
            let request: SQLRequest<Row> = """
                SELECT id, pinned, COALESCE(used_at, created_at) AS sort_date,
                       substr(search_text, 1, \(Self.fuzzyScanLength)) AS head
                FROM clip_item
                WHERE search_text IS NOT NULL AND NOT (\(exact)) AND \(inKind)
                ORDER BY sort_date DESC LIMIT \(Self.fuzzyCandidateLimit)
                """
            return try request.fetchAll(db)
        }
        var hits: [Candidate] = []
        for row in rows {
            let head: String = row["head"]
            guard let errors = FuzzyMatcher.errors(matching: folded, in: head, maxErrors: maxErrors) else { continue }
            hits.append(Candidate(id: row["id"], errors: errors, pinned: row["pinned"], date: row["sort_date"]))
        }
        hits.sort {
            if $0.errors != $1.errors { return $0.errors < $1.errors }
            if $0.pinned != $1.pinned { return $0.pinned }
            if $0.date != $1.date { return $0.date > $1.date }
            return $0.id > $1.id
        }
        return hits.map(\.id)
    }

    static let fuzzyScanLength = 1_000
    static let fuzzyCandidateLimit = 5_000

    // MARK: Updating

    public func setPinned(id: Int64, _ pinned: Bool) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE clip_item SET pinned = ? WHERE id = ?", arguments: [pinned, id])
        }
    }

    public func setOCRText(id: Int64, _ text: String) throws {
        try dbQueue.write { db in
            guard let item = try ClipItem.fetchOne(db, key: id) else { return }
            try db.execute(sql: "UPDATE clip_item SET ocr_text = ?, search_text = ? WHERE id = ?",
                           arguments: [text, Self.searchText(for: item, ocr: text), id])
        }
    }

    /// Pasting or copying an item from the history bumps it to the top.
    /// Only used_at changes; created_at stays "copied at", so the time line in the preview doesn't lie.
    public func touch(id: Int64, at date: Date = Date()) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE clip_item SET used_at = ? WHERE id = ?", arguments: [date, id])
        }
    }

    /// Throws away all recognised text.
    ///
    /// Called when "Recognize text in images" is turned off. Stopping new recognition isn't enough:
    /// text already recognised would still be in search, and a switch that's off but still affects
    /// results isn't off. Clearing to NULL (not an empty string) is deliberate: an empty string
    /// means "recognised, no text in the image", NULL means "not recognised yet", so turning the
    /// switch back on automatically queues these images for recognition again.
    public func forgetRecognizedText() throws {
        let images = try dbQueue.read { db in
            try ClipItem.filter(Column("kind") == ClipKind.image.rawValue)
                .filter(Column("ocr_text") != nil)
                .fetchAll(db)
        }
        guard !images.isEmpty else { return }
        try dbQueue.write { db in
            for item in images {
                var cleared = item
                cleared.ocrText = nil
                try db.execute(sql: "UPDATE clip_item SET ocr_text = NULL, search_text = ? WHERE id = ?",
                               arguments: [Self.searchText(for: cleared), item.id])
            }
        }
    }

    /// Images that haven't been through OCR yet
    public func pendingOCR() throws -> [ClipItem] {
        try dbQueue.read { db in
            try ClipItem
                .filter(Column("kind") == ClipKind.image.rawValue && Column("ocr_text") == nil)
                .order(Column("created_at").desc)
                .fetchAll(db)
        }
    }

    // MARK: Deleting

    public func delete(id: Int64) throws {
        // After deleting, leave it all to orphan cleanup rather than deleting "this item's image file"
        // directly: files are named by content hash, so two records with the same pixels (say, one
        // that also carries HTML) share one file, and deleting by row would delete the other's image
        // too. Large representations in assets/ (multi-MB web archives) weren't handled at all:
        // deleting the record freed no space until the next expiry cleanup.
        try dbQueue.write { db in
            guard let item = try ClipItem.fetchOne(db, key: id) else { return }
            _ = try item.delete(db)
        }
        try removeOrphanFiles()
    }
}

/// One page of search results. fuzzyIDs marks which ones aren't exact matches; the panel gives
/// them their own section.
public struct SearchPage: Sendable {
    public let items: [ClipItem]
    public let fuzzyIDs: Set<Int64>

    public init(items: [ClipItem], fuzzyIDs: Set<Int64>) {
        self.items = items
        self.fuzzyIDs = fuzzyIDs
    }
}

public struct StoreStats: Equatable {
    public var count: Int
    public var imageCount: Int
    public var pinnedCount: Int
    public var diskBytes: Int

    public init(count: Int, imageCount: Int, pinnedCount: Int = 0, diskBytes: Int) {
        self.count = count
        self.imageCount = imageCount
        self.pinnedCount = pinnedCount
        self.diskBytes = diskBytes
    }
}

extension HistoryStore {
    // MARK: Cleanup

    /// Deletes expired, unpinned records and their image files, and cleans up orphaned images
    /// along the way. Returns the number of rows deleted.
    @discardableResult
    public func purge(policy: RetentionPolicy, now: Date = Date()) throws -> Int {
        let textCutoff = now.addingTimeInterval(-Double(policy.textDays) * 86_400)
        let imageCutoff = now.addingTimeInterval(-Double(policy.imageDays) * 86_400)
        let fileCutoff = now.addingTimeInterval(-Double(policy.fileDays) * 86_400)
        // Age is measured from last use, not from "copied at": something in constant use shouldn't expire
        let age = SQL("COALESCE(used_at, created_at)").sqlExpression
        let removed = try dbQueue.write { db in
            try ClipItem
                .filter(Column("pinned") == false)
                .filter(
                    (Column("kind") == ClipKind.text.rawValue && age < textCutoff)
                    || (Column("kind") == ClipKind.image.rawValue && age < imageCutoff)
                    || (Column("kind") == ClipKind.file.rawValue && age < fileCutoff)
                )
                .deleteAll(db)
        }
        try removeOrphanFiles()
        if removed > 0 { compactIfFragmented() }
        return removed
    }

    /// Deletes files on disk that no record references. Scans both directories.
    ///
    /// Can't delete by row: files are named by content hash and two records may point at the same
    /// file, so deleting one would delete the other's file too. So it's always "collect references,
    /// scan the directory, delete what isn't referenced".
    ///
    /// This used to scan only images/. When a row is deleted, clip_asset goes with it through the
    /// foreign-key cascade, but nothing handled the files in assets/: every expired large RTF, HTML
    /// or web archive stayed on disk forever.
    ///
    /// The whole pass, including listing and deleting files, runs inside one database access.
    /// `record()` writes its files inside a write transaction, and DatabaseQueue serialises every
    /// access, so a clip can't land between "which files are referenced" and "delete the rest".
    /// Taking the snapshot inside and deleting outside left exactly that window: a file written just
    /// after the snapshot looked like an orphan and was deleted under its new row.
    private func removeOrphanFiles() throws {
        try dbQueue.read { db in
            let previews = Set(try String.fetchAll(db, sql: "SELECT content FROM clip_item WHERE kind = 'image'"))
            let spilled = Set(try String.fetchAll(db, sql:
                "SELECT file_name FROM clip_asset WHERE file_name IS NOT NULL AND in_images = 0"))
            let viaImages = Set(try String.fetchAll(db, sql:
                "SELECT file_name FROM clip_asset WHERE file_name IS NOT NULL AND in_images = 1"))
            let keepInImages = previews.union(viaImages)
            var firstFailure: Error?
            for (directory, keep) in [(self.imagesDirectory, keepInImages), (self.assetsDirectory, spilled)] {
                do {
                    let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
                    for name in files where !keep.contains(name) {
                        do {
                            try FileManager.default.removeItem(at: directory.appendingPathComponent(name))
                        } catch {
                            if !Self.isMissingFile(error) { firstFailure = firstFailure ?? error }
                        }
                    }
                } catch {
                    // assets/ does not exist until the first large representation is saved.
                    // A missing directory is already clean; unreadable is not the same thing.
                    if !Self.isMissingFile(error) { firstFailure = firstFailure ?? error }
                }
            }
            if let firstFailure { throw firstFailure }
        }
    }

    private static func isMissingFile(_ error: Error) -> Bool {
        guard let error = error as? CocoaError else { return false }
        return error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile
    }

    /// A failed file removal must not prevent database compaction or other files being removed.
    /// Retrying a clear repeats this sweep even when its database rows have already gone.
    private func finishClearing() throws {
        var failure: Error?
        do { try removeOrphanFiles() } catch { failure = error }
        do { try compact() } catch { failure = failure ?? error }
        if let failure { throw failure }
    }

    /// Deletes every item, pinned ones included. Not reachable from the UI: there, pinned items
    /// are cleared only by `clearPinned`, so that no bulk action on the history can take them along.
    public func clearAll() throws {
        try dbQueue.write { db in
            _ = try ClipItem.deleteAll(db)
        }
        try finishClearing()
    }

    /// Deletes the history, pinned items excepted. Returns how many went.
    ///
    /// "Clear history" and "clear on quit" both come here. Pinning is an explicit "keep this", and
    /// clear-on-quit used to take pinned items with it every time the app closed, which made pinning
    /// meaningless for anyone with that switch on.
    @discardableResult
    public func clearHistory() throws -> Int {
        let removed = try dbQueue.write { db in
            try ClipItem.filter(Column("pinned") == false).deleteAll(db)
        }
        try finishClearing()
        return removed
    }

    /// Deletes the pinned items and nothing else. Its own action with its own button, so that the
    /// history actions never have to say whether they include pinned items: they never do.
    @discardableResult
    public func clearPinned() throws -> Int {
        let removed = try dbQueue.write { db in
            try ClipItem.filter(Column("pinned") == true).deleteAll(db)
        }
        try finishClearing()
        return removed
    }

    /// Clears what was recorded in the recent past.
    ///
    /// You've just pasted something sensitive and want it gone, without clearing the whole history.
    /// Clearing by time window is a practical compromise; Alfred offers 5- and 15-minute options.
    ///
    /// Pinned items are left alone: pinning is an explicit "keep this", and a time-based clear
    /// shouldn't sweep it away. Returns the number deleted so the UI can say exactly what happened.
    @discardableResult
    public func clearRecent(within interval: TimeInterval) throws -> Int {
        let cutoff = Date().addingTimeInterval(-interval)
        // Measure time the same way as the list and expiry cleanup: if it was used, go by when it
        // was used. Looking only at "copied at", a password copied yesterday and just pasted out of
        // the history wouldn't be removed by "Clear last 5 minutes", even though the user believes it was.
        let age = SQL("COALESCE(used_at, created_at)").sqlExpression
        let removed = try dbQueue.write { db in
            try ClipItem.filter(Column("pinned") == false)
                .filter(age >= cutoff)
                .deleteAll(db)
        }
        try finishClearing()
        return removed
    }

    // MARK: Stats

    public func stats() throws -> StoreStats {
        let (count, imageCount, pinnedCount) = try dbQueue.read { db -> (Int, Int, Int) in
            let total = try ClipItem.fetchCount(db)
            let images = try ClipItem.filter(Column("kind") == ClipKind.image.rawValue).fetchCount(db)
            let pinned = try ClipItem.filter(Column("pinned") == true).fetchCount(db)
            return (total, images, pinned)
        }
        var bytes = 0
        if let url = databaseURL {
            for suffix in ["", "-wal", "-shm"] {
                let p = url.path + suffix
                bytes += (try? FileManager.default.attributesOfItem(atPath: p)[.size] as? Int) ?? 0
            }
        }
        // Both directories must be counted. assets holds the large on-disk representations (RTFD,
        // HTML and web archives over 256 KB), and counting only images badly under-reports: in one
        // measured database, com.apple.webarchive alone was 9 MB, all of it in assets.
        for directory in [imagesDirectory, assetsDirectory] {
            let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            for name in files {
                let p = directory.appendingPathComponent(name).path
                bytes += (try? FileManager.default.attributesOfItem(atPath: p)[.size] as? Int) ?? 0
            }
        }
        return StoreStats(count: count, imageCount: imageCount, pinnedCount: pinnedCount, diskBytes: bytes)
    }
}
