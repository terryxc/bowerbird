import AppKit
import Foundation

/// The content parsed from a single copy action.
///
/// No longer "one representation" but **all** the representations on the pasteboard worth keeping.
/// Keeping only one was the root cause of lost formatting: copying from Word puts both RTF and plain
/// text on the pasteboard, and if only the plain text is stored, only plain text can be pasted back.
public struct ClipCapture: Equatable, Sendable {
    /// One representation
    public struct Asset: Equatable, Sendable {
        public let type: NSPasteboard.PasteboardType
        public let data: Data
        /// Original pasteboard item. Nil is reserved for captures made before item boundaries
        /// were stored; those still use the legacy per-type occurrence order when replayed.
        public let pasteboardItemIndex: Int?

        public init(type: NSPasteboard.PasteboardType, data: Data, pasteboardItemIndex: Int? = nil) {
            self.type = type
            self.data = data
            self.pasteboardItemIndex = pasteboardItemIndex
        }
    }

    public let assets: [Asset]
    /// Which branch the list icon and preview take; decided once at capture time
    public let kind: ClipKind
    /// Plain text for search and display
    public let text: String
    /// Images only
    public let imageSize: CGSize?
    /// Files only
    public let filePaths: [String]

    public init(assets: [Asset], kind: ClipKind, text: String,
                imageSize: CGSize? = nil, filePaths: [String] = []) {
        self.assets = assets
        self.kind = kind
        self.text = text
        self.imageSize = imageSize
        self.filePaths = filePaths
    }

    /// The size shown in the UI.
    ///
    /// For files it is the size of the referenced files, not the few dozen bytes of the file URL;
    /// what the user wants to know is how big the file is.
    ///
    /// For images it is the size of the image itself (`previewType` is the stored copy). It used to
    /// be the sum of all representations: copying a 152-byte image from a web page, accompanied by
    /// 200 KB of HTML, showed "Image: 8x8 (200 KB)" in the list.
    /// Every other kind still uses the sum of all representations, since that is what the item
    /// actually takes up.
    public func displayBytes(previewType: NSPasteboard.PasteboardType? = nil) -> Int {
        if kind == .file {
            return filePaths.reduce(0) { total, path in
                total + (((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int) ?? 0)
            }
        }
        if kind == .image, let previewType, let bytes = data(for: previewType) {
            return bytes.count
        }
        return assets.reduce(0) { $0 + $1.data.count }
    }

    /// How many bytes this history item actually takes in the store
    public var storedBytes: Int { assets.reduce(0) { $0 + $1.data.count } }

    public func data(for type: NSPasteboard.PasteboardType) -> Data? {
        assets.first { $0.type == type }?.data
    }

    /// Content fingerprint.
    ///
    /// One hash over every (type, data) pair rather than just the plain text: the same text with
    /// different formatting is different content. Each segment is prefixed with its length;
    /// otherwise ("ab","c") and ("a","bc") would collide (as they do in Clipy's approach).
    public var contentHash: String {
        var buffer = Data()
        // Keep existing single-item hashes stable. Multi-item captures must include their
        // boundaries, or two different groupings of the same formats would deduplicate.
        let hasMultipleItems = assets.contains { ($0.pasteboardItemIndex ?? 0) > 0 }
        if hasMultipleItems { buffer.appendLengthPrefixed(Data("pasteboard-items-v1".utf8)) }
        for asset in assets {
            if hasMultipleItems {
                buffer.appendLengthPrefixed(Data(String(asset.pasteboardItemIndex ?? 0).utf8))
            }
            buffer.appendLengthPrefixed(Data(asset.type.rawValue.utf8))
            buffer.appendLengthPrefixed(asset.data)
        }
        return Hash.sha256(buffer)
    }
}

private extension Data {
    mutating func appendLengthPrefixed(_ value: Data) {
        var length = UInt64(value.count).bigEndian
        Swift.withUnsafeBytes(of: &length) { append(contentsOf: $0) }
        append(value)
    }
}
