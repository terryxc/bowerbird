import Foundation
import GRDB

public enum ClipKind: String, Codable, Sendable {
    case text, image, file
}

public struct ClipItem: Codable, Equatable, Identifiable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "clip_item"

    public var id: Int64?
    public var kind: ClipKind
    /// text: the body; image: the image file name; file: a JSON array of paths
    public var content: String
    public var contentHash: String
    public var sourceBundleID: String?
    public var createdAt: Date
    /// When it was last pasted out of the history. The list sorts by the later of this and createdAt.
    public var usedAt: Date?
    /// Normalised searchable text; see HistoryStore.fold
    public var searchText: String?
    public var byteSize: Int
    public var imageWidth: Int?
    public var imageHeight: Int?
    /// nil = not recognised yet; "" = recognised, but no text
    public var ocrText: String?
    public var pinned: Bool
    /// The line shown in the list. Computed and stored at insert time; with multiple
    /// representations it can no longer be derived from content on the fly.
    public var title: String

    enum CodingKeys: String, CodingKey {
        case id, kind, content, pinned, title
        case contentHash = "content_hash"
        case sourceBundleID = "source_bundle_id"
        case createdAt = "created_at"
        case usedAt = "used_at"
        case searchText = "search_text"
        case byteSize = "byte_size"
        case imageWidth = "image_width"
        case imageHeight = "image_height"
        case ocrText = "ocr_text"
    }

    public init(id: Int64? = nil, kind: ClipKind, content: String, contentHash: String,
                sourceBundleID: String?, createdAt: Date, byteSize: Int,
                imageWidth: Int? = nil, imageHeight: Int? = nil, ocrText: String? = nil,
                pinned: Bool = false, title: String = "") {
        self.id = id
        self.kind = kind
        self.content = content
        self.contentHash = contentHash
        self.sourceBundleID = sourceBundleID
        self.createdAt = createdAt
        self.byteSize = byteSize
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        self.ocrText = ocrText
        self.pinned = pinned
        self.title = title
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    /// The time used for sorting and grouping the list: time of use if used, otherwise time copied
    public var sortDate: Date { usedAt ?? createdAt }

    /// Absolute paths for the file kind; other kinds return an empty array.
    public var filePaths: [String] {
        guard kind == .file, let data = content.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    /// Which text of this item search should look at.
    ///
    /// `content` can't be used directly: for images it's the preview file name (a 64-digit hex
    /// hash), so typing "a" would find every image in the database; for files it's a JSON array of
    /// paths, escaped slashes and all. Images have no searchable text of their own; they rely on the
    /// OCR output.
    var searchableText: String {
        switch kind {
        case .text: return content
        case .image: return ""
        case .file: return pathText
        }
    }

    /// How a file item is pasted as plain text: one path per line, matching Finder's
    /// "Copy as Pathname".
    ///
    /// The plain text already on the pasteboard can't be used: Finder puts only the file name
    /// there, and `public.url` holds a file reference address like `file:///.file/id=…`. Neither is
    /// a path.
    public var pathText: String {
        filePaths.joined(separator: "\n")
    }

    /// The one-line title shown in the list.
    ///
    /// Old data has an empty title (the column didn't exist before v2); in that case it's computed
    /// from content, the same as before.
    ///
    /// Only text keeps the title stored at capture time (its first line, which never changes).
    /// Image and file titles are worked out at display time: they carry a localized label, and the
    /// stored one is frozen in whatever language was active when the item was copied. Chinese users
    /// saw "Image: 1818x724 (166 KB)" in the list. The one exception is a file item whose
    /// path list was cut short by the list's content limit; its paths can't be read back, so the
    /// stored title stands in.
    public var displayTitle: String {
        switch kind {
        case .text:
            return title.isEmpty ? derivedTitle(text: content) : title
        case .image:
            return derivedTitle(text: "")
        case .file:
            return filePaths.isEmpty && !title.isEmpty ? title : derivedTitle(text: "")
        }
    }

    /// The list title keeps at most this many characters
    public static let titleLimit = 200

    /// The most body text the list and preview ever need.
    ///
    /// The preview only draws the first 20,000 characters anyway; anything more can't be seen.
    /// Truncating to this length when fetching the list means a few multi-MB texts in a page of
    /// 100 don't get read fully into memory. Pasting goes through clip_asset and isn't subject to
    /// this limit.
    public static let previewCharacterLimit = 20_000

    /// Works out what to display based on kind. For text, pass the searchable plain text.
    public func derivedTitle(text: String) -> String {
        switch kind {
        case .text:
            let firstLine = text.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline).first
            let line = (firstLine.map(String.init) ?? text).trimmingCharacters(in: .whitespaces)
            // Truncation is required. For long text with no line breaks, the "first line" is the
            // whole text: a 3 MB text would store 3 MB in both the title and content columns,
            // while the list only has room for one line.
            return String(line.prefix(Self.titleLimit))
        case .image:
            // Pixel sizes go in as text: %lld with a locale adds grouping, and "2,790×1,730" reads
            // as two numbers apiece. The preview writes them ungrouped too.
            return CoreLocalization.string("Image: %@×%@ (%@)", String(imageWidth ?? 0), String(imageHeight ?? 0),
                                           Format.bytes(byteSize))
        case .file:
            let paths = filePaths
            let name = paths.first.map { ($0 as NSString).lastPathComponent } ?? ""
            return paths.count > 1
                ? CoreLocalization.string("File: %@ and %lld more", name, paths.count - 1)
                : CoreLocalization.string("File: %@", name)
        }
    }
}

public enum Format {
    public static func bytes(_ n: Int) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f.string(fromByteCount: Int64(n))
    }
}

/// Core doesn't know which UI language the app chose, so the app injects how to fetch strings at
/// launch. The default just formats the key, so unit tests get the English source text directly.
public enum CoreLocalization {
    /// (key, arguments) -> the formatted string.
    ///
    /// Strings are fetched from any thread (inserts run on a background queue), hence the lock.
    /// The app installs it once at launch and swaps it when the language changes; reads far
    /// outnumber writes.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var stored: (String, [CVarArg]) -> String = { key, args in
        args.isEmpty ? key : String(format: key, arguments: args)
    }

    public static var provider: (String, [CVarArg]) -> String {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }

    static func string(_ key: String, _ arguments: CVarArg...) -> String {
        provider(key, arguments)
    }
}
