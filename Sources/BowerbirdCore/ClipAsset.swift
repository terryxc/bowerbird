import AppKit
import Foundation
import GRDB

/// One pasteboard representation of a history item.
///
/// A single copy puts the same content on the pasteboard in several formats at once (RTFD, RTF,
/// HTML, plain text), and the receiver picks the richest one it understands. Storing only one means
/// only that one can be pasted, and the formatting is lost. That was the root cause of "copied from
/// Word, pasted from history as plain text".
///
/// Large representations go to disk; small ones are inlined. Stuffing a multi-MB RTFD into an SQLite
/// row bloats the database and slows queries.
public struct ClipAsset: Codable, Equatable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "clip_asset"

    public var id: Int64?
    public var itemID: Int64
    /// rawValue of `NSPasteboard.PasteboardType`
    public var type: String
    /// Small representations are inlined directly
    public var value: Data?
    /// File name of a large representation written to disk
    public var fileName: String?
    /// This file lives in the images directory rather than the assets directory.
    /// Images already have a separate copy stored for the preview, and both sides are named by content
    /// hash, so referencing it avoids storing it a second time.
    public var inImagesDirectory: Bool
    /// Order when writing back to the pasteboard. Some apps pick by the order of types on the pasteboard,
    /// so the order must be preserved.
    public var ordinal: Int
    public var pasteboardItemIndex: Int?
    public var byteSize: Int

    enum CodingKeys: String, CodingKey {
        case id, type, value, ordinal
        case itemID = "item_id"
        case fileName = "file_name"
        case byteSize = "byte_size"
        case inImagesDirectory = "in_images"
        case pasteboardItemIndex = "pasteboard_item_index"
    }

    public init(id: Int64? = nil, itemID: Int64, type: String, value: Data? = nil,
                fileName: String? = nil, inImagesDirectory: Bool = false,
                ordinal: Int, byteSize: Int, pasteboardItemIndex: Int? = nil) {
        self.id = id
        self.itemID = itemID
        self.type = type
        self.value = value
        self.fileName = fileName
        self.inImagesDirectory = inImagesDirectory
        self.ordinal = ordinal
        self.byteSize = byteSize
        self.pasteboardItemIndex = pasteboardItemIndex
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    /// Above this size a representation goes to disk instead of being inlined in the database
    public static let inlineLimit = 256 * 1024
}

/// The type and size of one representation, without its content.
///
/// That is all the panel needs to draw the format bar; reading a multi-MB RTFD back from disk would be
/// pure waste.
public struct ClipAssetSummary: Equatable, Sendable {
    public let type: NSPasteboard.PasteboardType
    public let byteSize: Int

    public init(type: NSPasteboard.PasteboardType, byteSize: Int) {
        self.type = type
        self.byteSize = byteSize
    }
}
