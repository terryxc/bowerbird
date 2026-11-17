import AppKit

/// Formats that can be chosen when pasting.
///
/// Pasteboard types can't be used as options directly. Copying a link puts both `public.url` and
/// `public.utf8-plain-text` on the pasteboard, yet both paste the same, and offering them as two
/// options would make the format bar pop up every time a link is copied. So types are first merged
/// into groups a person can understand, and **if only one group remains there is no choice and the
/// bar isn't shown at all**.
///
/// This only covers how pasteboard types are grouped. The chips offered in the panel are a separate
/// thing; see `ClipVariant`. A file's "path" and an image's "text in image" are not pasteboard types.
public enum PasteFormat: String, CaseIterable, Identifiable, Sendable {
    case richText
    case html
    case plainText
    case image
    case pdf
    case file

    public var id: String { rawValue }

    /// Pasteboard types that belong to this group
    var types: [NSPasteboard.PasteboardType] {
        switch self {
        case .richText: [.rtfd, .rtf]
        case .html: [.html]
        // public.text is the parent UTI of public.utf8-plain-text, and browsers and Qt apps often include it;
        // public.url is always present when a link is copied, but pastes no differently from plain text.
        // Merge both so copying a link doesn't bring up the format bar.
        case .plainText: [.string, .URL, .init("public.text")]
        case .image: [.png, PasteboardTypes.jpeg, .tiff]
        case .pdf: [.pdf]
        case .file: [.fileURL, PasteboardTypes.legacyFilenames]
        }
    }

    /// Name shown in the panel. The key is also the English source string in Localizable.strings.
    public var labelKey: String {
        switch self {
        case .richText: "Rich Text"
        case .html: "Web"
        case .plainText: "Plain Text"
        case .image: "Image"
        case .pdf: "PDF"
        case .file: "File"
        }
    }

    private static let byType: [NSPasteboard.PasteboardType: PasteFormat] = {
        var map: [NSPasteboard.PasteboardType: PasteFormat] = [:]
        for format in allCases {
            for type in format.types { map[type] = format }
        }
        return map
    }()

    public static func group(for type: NSPasteboard.PasteboardType) -> PasteFormat? {
        byType[type]
    }

    /// Which groups this history item contains.
    ///
    /// The order follows storage order, which was already sorted by `PasteboardTypes.preferredOrder`
    /// when recorded, so richer formats naturally come first.
    public static func groups(in assets: [ClipCapture.Asset]) -> [PasteFormat] {
        groups(types: assets.map(\.type))
    }

    public static func groups(in summaries: [ClipAssetSummary]) -> [PasteFormat] {
        groups(types: summaries.map(\.type))
    }

    private static func groups(types: [NSPasteboard.PasteboardType]) -> [PasteFormat] {
        var found: [PasteFormat] = []
        for type in types {
            guard let group = group(for: type), !found.contains(group) else { continue }
            found.append(group)
        }
        return found
    }

    /// Options the format bar should show. At most two: "as captured" and "plain text".
    ///
    /// Offering two to four chips adapted to the content is doable, and measurements support it
    /// (for Word and WPS content the four results really do differ). But the product decision is to
    /// match Alfred, Maccy and Clipy and offer only two: every extra always-visible chip costs
    /// attention, and "force RTF only, no HTML" is a fine-grained operation that is rarely needed.
    /// "As captured" already keeps the formatting intact, which was the problem to solve in the first place.
    ///
    /// An empty array means the bar isn't shown: either the item has only one representation, or it
    /// has no plain-text representation at all (e.g. an image copied from a web page), so there is no choice.
    public static func distinctFormats(in summaries: [ClipAssetSummary]) -> [PasteFormat] {
        distinct(summaries, all: groups(in: summaries), type: \.type)
    }

    public static func distinctFormats(in assets: [ClipCapture.Asset]) -> [PasteFormat] {
        distinct(assets, all: groups(in: assets), type: \.type)
    }

    private static func distinct<T>(_ items: [T], all: [PasteFormat],
                                    type: (T) -> NSPasteboard.PasteboardType) -> [PasteFormat] {
        guard all.count > 1, all.contains(.plainText) else { return [] }
        // What plain text writes out must differ from "as captured", otherwise both chips do the same thing
        guard select(items, to: .plainText, type: type).map(type) != items.map(type) else { return [] }
        return [.plainText]
    }

    /// Representations to write back to the pasteboard when a group is chosen. nil means "as captured":
    /// write everything unchanged.
    ///
    /// Only the chosen group is written, **with a plain-text fallback appended**. Without it, ⌘V does
    /// nothing when the target app accepts none of them, which feels broken. With it, the intent
    /// "don't use the web format" still holds, because the target app prefers the earlier, richer one.
    public static func filter(_ assets: [ClipCapture.Asset],
                              to format: PasteFormat?) -> [ClipCapture.Asset] {
        select(assets, to: format, type: \.type)
    }

    /// Total bytes written out for the chosen group; shown at the right end of the action row so the result is clear.
    public static func byteSize(_ assets: [ClipCapture.Asset], to format: PasteFormat?) -> Int {
        filter(assets, to: format).reduce(0) { $0 + $1.data.count }
    }

    public static func byteSize(_ summaries: [ClipAssetSummary], to format: PasteFormat?) -> Int {
        select(summaries, to: format, type: \.type).reduce(0) { $0 + $1.byteSize }
    }

    /// Picks the chosen group plus the plain-text fallback. Content and summaries share this logic so
    /// the byte count shown in the panel always matches what is actually written.
    private static func select<T>(_ items: [T], to format: PasteFormat?,
                                  type: (T) -> NSPasteboard.PasteboardType) -> [T] {
        guard let format else { return items }
        var kept = items.filter { group(for: type($0)) == format }
        guard !kept.isEmpty else { return items }
        if format != .plainText,
           let fallback = items.first(where: { type($0) == .string }) {
            kept.append(fallback)
        }
        return kept
    }
}
