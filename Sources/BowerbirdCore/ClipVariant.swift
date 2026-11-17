import AppKit

/// The ways to take the same clip, i.e. the options on the panel's format bar.
///
/// Kept separate from `PasteFormat`: that one describes "how pasteboard types are grouped", a fact of
/// the storage layer; this one describes "the ways a person can ask for this clip". `recognizedText`
/// used to be squeezed into `PasteFormat`, yet it has no matching pasteboard type. The cost was
/// per-type special cases scattered across three places: the title, the byte count, and the content
/// actually written out; change one and forget another. Now the rule lives only here, and all three
/// callers ask it.
public enum ClipVariant: String, Hashable, Sendable {
    /// Untouched: write back exactly what was stored
    case asCaptured
    /// Only the plain-text representation
    case plainText
    /// The file paths, one per line
    case path
    /// Text recognized in the image
    case recognizedText
}

public extension ClipItem {
    /// Which option is "the other way to take it": the path for files, the recognized text for images,
    /// plain text for text. An image with no recognized text has no second option. This table lives
    /// only here; `variants` is derived from it.
    var textVariant: ClipVariant {
        if !filePaths.isEmpty { return .path }
        if kind == .image { return hasRecognizedText ? .recognizedText : .asCaptured }
        return .plainText
    }

    /// The cells on the format bar. The first is always "as captured"; a single cell means there is
    /// no choice and the bar is hidden.
    ///
    /// Only the second ways that change what the preview shows get a cell: a file's path and the
    /// text in an image. Plain text for a rich-text clip does not: the preview is plain text either
    /// way, so two cells with the same picture under them only looked broken. That way is reached
    /// with ⇧⌘↩, the row menu and the footer hint instead (see `textVariant`).
    func variants(assets: [ClipAssetSummary]) -> [ClipVariant] {
        let second = textVariant
        guard second != .asCaptured, second != .plainText else { return [.asCaptured] }
        return [.asCaptured, second]
    }

    var hasRecognizedText: Bool { !(ocrText ?? "").isEmpty }

    /// What gets written back to the clipboard when this option is chosen. `assets` is every stored
    /// representation.
    ///
    /// Neither the path nor the text in an image exists in any clipboard representation: one is
    /// derived from the file location, the other is recognized by us. So a plain-text representation
    /// is made here.
    func payload(for variant: ClipVariant, assets: [ClipCapture.Asset]) -> [ClipCapture.Asset] {
        switch variant {
        case .asCaptured:
            return assets
        case .plainText:
            // Only the plain-text representation. If there is none, make one from the stored body.
            // Going through PasteFormat.filter, content with only HTML would hit "nothing to pick, so
            // give everything", and "Paste as Plain Text" would paste the whole formatted content instead.
            if let plain = assets.first(where: { $0.type == .string }) { return [plain] }
            return [.init(type: .string, data: Data(content.utf8))]
        case .path:
            return [.init(type: .string, data: Data(pathText.utf8))]
        case .recognizedText:
            return [.init(type: .string, data: Data((ocrText ?? "").utf8))]
        }
    }

    /// How many bytes will be written in total if this option is chosen. The count in the panel's
    /// bottom-right corner uses it; it must follow the same rules as what is actually written,
    /// otherwise it reports a false number.
    func byteCount(for variant: ClipVariant, summaries: [ClipAssetSummary]) -> Int {
        switch variant {
        case .asCaptured: return PasteFormat.byteSize(summaries, to: nil)
        // Mirrors payload(.plainText) exactly: the first plain string, or the body made into one.
        // Going through PasteFormat added up the whole plain-text group (URL and public.text too)
        // and fell back to every representation when there was none, so the number overstated what
        // actually goes out.
        case .plainText:
            return summaries.first { $0.type == .string }?.byteSize ?? content.utf8.count
        case .path: return pathText.utf8.count
        case .recognizedText: return (ocrText ?? "").utf8.count
        }
    }
}
