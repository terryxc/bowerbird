import Foundation
import GRDB

enum Migrations {
    /// The directories are needed because two migrations touch files on disk (merging images stored twice into one).
    static func migrator(imagesDirectory: URL, assetsDirectory: URL) -> DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1") { db in
            try db.create(table: "clip_item") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("kind", .text).notNull()
                t.column("content", .text).notNull()
                t.column("content_hash", .text).notNull().unique()
                t.column("source_bundle_id", .text)
                t.column("created_at", .datetime).notNull()
                t.column("byte_size", .integer).notNull().defaults(to: 0)
                t.column("image_width", .integer)
                t.column("image_height", .integer)
                t.column("ocr_text", .text)
                t.column("pinned", .boolean).notNull().defaults(to: false)
            }
            try db.create(index: "idx_clip_created", on: "clip_item", columns: ["created_at"])
            try db.create(index: "idx_clip_pinned", on: "clip_item", columns: ["pinned"])
        }
        m.registerMigration("v2_assets") { db in
            // One history entry can have several pasteboard representations. Storing only one means
            // formatted content copied from Word or Feishu comes back as plain text when pasted from
            // history: the formatting is lost at insert time.
            try db.create(table: "clip_asset") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("item_id", .integer).notNull()
                    .references("clip_item", onDelete: .cascade)
                t.column("type", .text).notNull()
                t.column("value", .blob)          // small representations inline
                t.column("file_name", .text)      // large representations on disk
                t.column("ordinal", .integer).notNull().defaults(to: 0)
                t.column("byte_size", .integer).notNull().defaults(to: 0)
            }
            try db.create(index: "idx_asset_item", on: "clip_asset", columns: ["item_id"])

            // The list title used to be computed from content; with multiple representations it can't be, so compute it at insert time and store it
            try db.alter(table: "clip_item") { t in
                t.add(column: "title", .text).notNull().defaults(to: "")
            }
        }
        m.registerMigration("v3_asset_location") { db in
            // Sweep orphans first. If clip_item was deleted directly with the sqlite3 CLI, the CLI's
            // default foreign_keys=OFF means the cascade doesn't run, leaving clip_asset rows that
            // point at items that no longer exist. The foreign key check during migration hits them
            // and the whole migration fails, and the fallback above is "can't open, rename and
            // rebuild", so a dozen junk rows cost the entire history. Orphans are useless anyway;
            // just delete them.
            try db.execute(sql: """
                DELETE FROM clip_asset
                WHERE item_id NOT IN (SELECT id FROM clip_item)
                """)

            // A spilled representation may point into the images directory: images are already stored
            // separately for the preview, and both directories name files by content hash, so
            // referencing that one avoids storing an identical copy.
            try db.alter(table: "clip_asset") { t in
                t.add(column: "in_images", .boolean).notNull().defaults(to: false)
            }
        }

        m.registerMigration("v4_used_at_and_search_text") { db in
            try db.alter(table: "clip_item") { t in
                // Recorded after pasting from history; the list sorts by it. created_at remains
                // "copied at", so the UI doesn't lie.
                t.add(column: "used_at", .datetime)
                // Body text with diacritics stripped and case and width normalised, plus OCR text;
                // search only looks at this column. Computed at insert time, zero cost at query time.
                // Alfred runs a custom function at query time, which is why it has to warn that large
                // libraries get slow.
                t.add(column: "search_text", .text)
            }
        }

        // The next two used to be full-table scans run on every launch. They were always one-off data
        // fixes and belong in migrations: with a thousand images, every launch read all inline images
        // to hash them, eating several hundred MB before the first frame; and rows whose preview file
        // was lost could never be merged, so they were scanned in vain every time.
        m.registerMigration("v5_merge_duplicate_images") { db in
            // For large representations in assets/, if images/ already has a preview with the same
            // name (same hash), reference that instead and delete the copy on disk
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, file_name FROM clip_asset WHERE file_name IS NOT NULL AND in_images = 0
                """)
            for row in rows {
                let name: String = row["file_name"]
                let preview = imagesDirectory.appendingPathComponent("\(name).png")
                guard FileManager.default.fileExists(atPath: preview.path) else { continue }
                try? FileManager.default.removeItem(at: assetsDirectory.appendingPathComponent(name))
                try db.execute(sql: "UPDATE clip_asset SET in_images = 1, file_name = ? WHERE id = ?",
                               arguments: ["\(name).png", row["id"] as Int64])
            }
        }

        m.registerMigration("v6_unline_inline_images") { db in
            // Small images stored inline in the database that also exist in images/ are switched to
            // reference the file. If the preview file is missing, the database copy is the only one left; leave it alone.
            let rows = try Row.fetchAll(db, sql: """
                SELECT a.id, a.value, i.content
                FROM clip_asset a JOIN clip_item i ON i.id = a.item_id
                WHERE i.kind = 'image' AND a.value IS NOT NULL
                  AND a.type = CASE
                      WHEN i.content LIKE '%.png' THEN 'public.png'
                      WHEN i.content LIKE '%.jpg' THEN 'public.jpeg'
                      WHEN i.content LIKE '%.tiff' THEN 'public.tiff'
                  END
                """)
            for row in rows {
                let value: Data = row["value"]
                let fileName: String = row["content"]
                guard fileName.hasPrefix(Hash.sha256(value)),
                      FileManager.default.fileExists(
                        atPath: imagesDirectory.appendingPathComponent(fileName).path)
                else { continue }
                try db.execute(sql: """
                    UPDATE clip_asset SET value = NULL, file_name = ?, in_images = 1 WHERE id = ?
                    """, arguments: [fileName, row["id"] as Int64])
            }
        }

        m.registerMigration("v7_rebuild_search_text") { db in
            // An image's content is its preview file name (a hash) and a file item's is a JSON array of
            // paths. Both used to be folded into search_text verbatim, so typing a single letter found
            // every image. Recompute using ClipItem.searchableText's rules, filling in NULLs from old data.
            let items = try ClipItem.fetchAll(db)
            for item in items {
                try db.execute(sql: "UPDATE clip_item SET search_text = ? WHERE id = ?",
                               arguments: [HistoryStore.searchText(for: item), item.id])
            }
        }

        m.registerMigration("v8_list_order_index") { db in
            // The list and search both sort the same way: pinned first, then "most recently used or
            // copied", ties broken by id descending. No index matched this order before, so SQLite
            // had to scan the whole table and build a temporary B-tree: measured 11.2 ms for twenty
            // thousand items, and one or two ms even for a thousand, paid on every panel open and
            // every search keystroke. With an index on the same expression it's 0.15 ms.
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_clip_order
                ON clip_item(pinned DESC, COALESCE(used_at, created_at) DESC, id DESC)
                """)
            // The two original indexes can go. The list, search, expiry purge and purge-by-time queries
            // all use the expression above; the only one still sorting by created_at alone is "images
            // not yet OCRed", which has to scan the whole table anyway (it filters on ocr_text IS NULL,
            // which no index serves). Dropping the index only adds a sort of the result set, and that
            // query runs once per launch. pinned has only two values, so SQLite never uses it.
            // Keeping them isn't free: every insert has to maintain them.
            try db.execute(sql: "DROP INDEX IF EXISTS idx_clip_created")
            try db.execute(sql: "DROP INDEX IF EXISTS idx_clip_pinned")
        }

        m.registerMigration("v9_pasteboard_item_boundaries") { db in
            try db.alter(table: "clip_asset") { t in
                // Old item boundaries cannot be recovered. NULL retains their legacy replay.
                t.add(column: "pasteboard_item_index", .integer)
            }
        }

        return m
    }
}
