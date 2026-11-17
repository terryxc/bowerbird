import AppKit
import BowerbirdCore
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

/// Right column: the mode at the top, a bottom row with actions on the left and info on the right,
/// and everything in between given to the content.
///
/// This used to be an Information table (source, type, word count, character count and copy time,
/// one row each). Easy to read, but it ate almost a third of the preview's height. Going back to
/// Alfred's approach left two lines of small text in the bottom-right corner.
///
/// Adding the format bar ran into another problem: the image's "Copy Text" button sat centred under
/// the image, so with one more strip on top the right column became four horizontal bands (format
/// bar, content, button, two lines of metadata), each saying its own thing. So this version squeezes
/// the metadata into one line and uses the freed line as an action row, with the button moved to the
/// left end. Net height doesn't increase, and images can now be truly centred in the whole content
/// area.
struct PreviewPane: View {
    @ObservedObject var model: PanelModel
    let store: HistoryStore

    var body: some View {
        if let item = model.selected {
            VStack(spacing: 0) {
                if model.showsFormatBar {
                    FormatBar(model: model)
                    Rectangle()
                        .fill(AppColors.separator)
                        .frame(height: PanelMetrics.hairline)
                }
                VStack(spacing: 0) {
                    content(for: item)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    actionRow(for: item)
                }
                .padding(.horizontal, PanelMetrics.previewPadding)
                // There's already a separator under the format bar; a full 18 on top of it looks too loose
                .padding(.top, model.showsFormatBar
                         ? PanelMetrics.previewTopInsetUnderFormatBar
                         : PanelMetrics.previewPadding)
                .padding(.bottom, PanelMetrics.previewBottomInset)
            }
        } else {
            Color.clear
        }
    }

    /// Whichever cell is selected on the format bar is what the preview draws, where the content
    /// differs: a file switched to "Path" shows just those lines of paths, an image switched to
    /// "Text in Image" shows the recognized text. Text is the exception, see below.
    @ViewBuilder
    private func content(for item: ClipItem) -> some View {
        switch item.kind {
        case .text:
            // Always plain text, whichever format is chosen. Rendering the real styling was tried
            // twice: recoloured for the panel it broke on every page whose "default" colour wasn't
            // grey enough, and drawn on its own white page it put a white block in the dark panel.
            // Maccy, Raycast and Alfred all preview plain text and keep the formats for pasting; the
            // format bar and the line under the preview say what will be pasted.
            TextPreview(text: item.content, query: model.query)
        case .image:
            if model.variant == .recognizedText {
                TextPreview(text: item.ocrText ?? "", query: model.query)
            } else {
                ImagePreview(item: item, store: store)
            }
        case .file:
            if model.variant == .path {
                TextPreview(text: item.pathText, query: model.query)
            } else {
                FilePreview(item: item)
            }
        }
    }

    // MARK: Action row

    /// The left end is what you can do with this item; the right end is "what you'll get".
    ///
    /// The right end has two states: on "As Captured" it shows facts (count, size, time); with a
    /// specific group chosen it switches to the consequence, in the accent colour. The left end is
    /// always actions, so a web image that has both a button and a format bar doesn't collide either.
    private func actionRow(for item: ClipItem) -> some View {
        HStack(spacing: PanelMetrics.actionRowSpacing) {
            action(for: item)
            Spacer(minLength: 8)
            Text(metaLine(for: item))
                .font(.system(size: PanelMetrics.previewMetaFontSize))
                .monospacedDigit()
                .foregroundStyle(model.variant == .asCaptured ? Color.secondary : AppColors.accent)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(height: PanelMetrics.actionRowHeight)
        .padding(.top, PanelMetrics.actionRowTopGap)
    }

    @ViewBuilder
    private func action(for item: ClipItem) -> some View {
        switch item.kind {
        case .image:
            // Recognized text no longer gets a separate button: it's a cell on the format bar, and
            // switching to it lets you see it before deciding, which beats pressing a button blind.
            EmptyView()
        case .file:
            // Not greyed out based on "does the file still exist": that means touching the file
            // system, which can freeze the whole UI on a disconnected network volume, and the preview
            // already says the file can't be found. If the file is gone, clicking this just does
            // nothing in Finder, which costs less than a freeze.
            let path = item.filePaths.first ?? ""
            PanelActionButton(title: L("Reveal in Finder")) {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            }
        case .text:
            EmptyView()
        }
    }

    // MARK: Metadata

    private func metaLine(for item: ClipItem) -> String {
        if model.variant != .asCaptured {
            return L("%@ only · %@", model.label(for: model.variant),
                     Format.bytes(model.selectedFormatBytes))
        }
        return "\(measureLine(for: item)) · \(copiedLine(for: item))"
    }

    /// Text shows line and character counts, images show dimensions and size, files show size.
    ///
    /// The first number used to be a "word count", computed by splitting on spaces. Chinese doesn't use
    /// spaces between words, so "营收 增长 23%，高于预期。" would count as 3 words, purely because there
    /// happen to be spaces there. Switched to line count: it holds for any language, and it's actually
    /// useful when pasting code or lists.
    private func measureLine(for item: ClipItem) -> String {
        switch item.kind {
        case .text:
            let lines = item.content.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).count
            let chars = L("%lld chars", item.content.count)
            return lines > 1 ? "\(L("%lld lines", lines)) · \(chars)" : chars
        case .image:
            return "\(item.imageWidth ?? 0) × \(item.imageHeight ?? 0) · \(Format.bytes(item.byteSize))"
        case .file:
            return Format.bytes(item.byteSize)
        }
    }

    /// Today shows only the time; anything else includes the date
    private func copiedLine(for item: ClipItem) -> String {
        if Calendar.current.isDateInToday(item.createdAt) {
            return L("Copied Today %@", item.createdAt.formatted(date: .omitted, time: .shortened))
        }
        return L("Copied %@", item.createdAt.formatted(date: .abbreviated, time: .shortened))
    }
}

// MARK: - Format bar

/// The strip at the top of the preview. The first cell is always "As Captured" and is selected by
/// default, so if you do nothing, Return behaves exactly as it always did.
private struct FormatBar: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        HStack(spacing: ChipMetrics.spacing) {
            ForEach(model.variants, id: \.self) { variant in
                TextChip(verbatim: model.label(for: variant),
                         selected: variant == model.variant) {
                    model.variant = variant
                }
            }
            // An image still being recognized: show a non-clickable placeholder first; once recognition
            // finishes it's replaced by the real "Text in Image". It's a cell rather than a line of
            // text elsewhere because it occupies exactly that cell's spot: what you see is "an option
            // is about to appear here", not "there's some progress somewhere".
            if model.isRecognizing {
                Text("Recognizing…")
                    .font(.system(size: ChipMetrics.fontSize))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, ChipMetrics.paddingH)
                    .frame(height: ChipMetrics.height)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, PanelMetrics.formatBarLeadingInset)
        .padding(.trailing, PanelMetrics.contentInset)
        .frame(height: PanelMetrics.formatBarHeight)
    }
}

// MARK: - The three kinds of content

struct TextPreview: View {
    static let textScrollSpace = "bowerbird.preview.text"
    /// The most characters the preview draws. However long the item, this is only a preview; pasting
    /// uses the full text.
    ///
    /// It's a constant with nothing to do with the main thread (the rich text preview also reads it
    /// when truncating long text in the background), so it's explicitly nonisolated; things inside a
    /// View follow the main thread by default.
    nonisolated static let characterLimit = 20_000
    /// @State rather than @StateObject: **own it, but don't subscribe to it.**
    ///
    /// This view's body never reads the tracker; the scroll indicator itself does (the
    /// @ObservedObject in ScrollIndicator). @StateObject would declare a dependency we never use on
    /// our behalf, so every frame of scrolling would re-run this view's body for nothing.
    ///
    /// The savings are actually small: measured 0.23 → 0.19 ms per scroll with AX-driven scrolling,
    /// and synthesized scroll-wheel events don't reach the app on macOS 26, so the cumulative effect of
    /// a real finger swipe can't be measured. It stays mainly not for the 0.04 ms but because
    /// @StateObject here states something that isn't true.
    @State private var scroll = ScrollTracker()
    let text: String
    /// The search query. Matches are highlighted in the body text too; highlighting only on the left
    /// and not on the right would make you search a screenful of text all over again.
    var query: String = ""

    /// The panel's font size and the body text colour for the current appearance; the base for the
    /// whole text
    @MainActor
    static var baseAttributes: [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: PanelMetrics.previewTextFontSize),
         .foregroundColor: NSColor.labelColor]
    }

    private var content: NSAttributedString {
        let shown = String(text.prefix(Self.characterLimit))
        let marked = NSMutableAttributedString(string: shown, attributes: Self.baseAttributes)
        SearchHighlight.mark(marked, query: query)
        return marked
    }

    var body: some View {
        PreviewTextView(content: content, contentID: contentID, tracker: scroll)
            .thinScrollIndicator(tracker: scroll)
    }

    /// These determine what gets drawn; the body text is rebuilt only when one of them changes.
    /// Using 20,000 characters of text itself as the identity is too expensive, so use its length plus
    /// a hash.
    private var contentID: String {
        "\(text.count)-\(text.hashValue)-\(query)-\(PanelMetrics.previewTextFontSize)"
    }
}

/// Decoded preview images, keyed by file URL.
///
/// The limit counts **decoded pixels**, not images. NSCache has no limit at all by default and only
/// evicts under system memory pressure, and a 3024×1964 screenshot decodes to 26 MB.
/// Measured: holding ↓ across 30 full-screen screenshots grew resident memory from 8 MB to 804 MB,
/// and none of it came back short of scrolling to the 31st; with a 128 MB limit it was 233 MB, and
/// the floor with no caching at all is already 111 MB (AppKit's own decode cache).
///
/// Limiting by count is wrong: a 16×16 favicon and a 6K screenshot aren't the same thing.
/// 128 MB is about five full-screen screenshots, which is about as many as the panel shows at once;
/// re-decoding ones scrolled past earlier costs tens of milliseconds, cheaper than holding on to them.
@MainActor
final class PreviewImageCache {
    static let shared = PreviewImageCache()
    private let cache = NSCache<NSURL, NSImage>()

    private static let costLimit = 128 * 1024 * 1024

    private init() { cache.totalCostLimit = Self.costLimit }

    func cached(at url: URL) -> NSImage? { cache.object(forKey: url as NSURL) }

    func store(_ image: NSImage, at url: URL) {
        cache.setObject(image, forKey: url as NSURL, cost: Self.decodedBytes(of: image))
    }

    /// Roughly how many bytes it takes once decoded. NSImage doesn't report this, so estimate it as the
    /// first representation's pixel count times 4 bytes per pixel. The cache needs a comparable scale,
    /// not an exact value.
    private static func decodedBytes(of image: NSImage) -> Int {
        guard let rep = image.representations.first else { return 0 }
        return rep.pixelsWide * rep.pixelsHigh * 4
    }
}

private struct ImagePreview: View {
    let item: ClipItem
    let store: HistoryStore
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.media))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: item.id) {
            let url = store.imageURL(for: item)
            if let cached = PreviewImageCache.shared.cached(at: url) {
                image = cached
                return
            }
            // Decode in the background, store in the cache back on the main thread; the cache itself
            // lives on the main thread
            let loaded = await Task.detached(priority: .userInitiated) {
                ImageBox(NSImage(contentsOf: url))
            }.value.image
            if let loaded { PreviewImageCache.shared.store(loaded, at: url) }
            // The selection moved on while this was decoding: keep it in the cache, but the view
            // now belongs to another item and must not be overwritten with this one
            guard !Task.isCancelled else { return }
            image = loaded
        }
    }
}

private struct FilePreview: View {
    let item: ClipItem
    @State private var thumbnail: NSImage?
    /// nil means not checked yet. Checking touches the file system, which can freeze the whole UI on
    /// a disconnected network volume, so it isn't computed in body; it's handed to the thumbnail task.
    @State private var exists: Bool?

    private var path: String { item.filePaths.first ?? "" }

    var body: some View {
        VStack(spacing: PanelMetrics.filePreviewSpacing) {
            Spacer(minLength: 0)
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: PanelMetrics.fileThumbnailSize,
                           maxHeight: PanelMetrics.fileThumbnailSize)
            }
            if exists != false {
                Text(abbreviatedPath)
                    .font(.system(size: PanelMetrics.previewMetaFontSize, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
            } else {
                Text("File no longer exists")
                    .font(.system(size: PanelMetrics.previewTextFontSize))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: item.id) {
            let path = self.path
            // The previous item's verdict doesn't apply to this one
            exists = nil
            let present = await Task.detached { FileManager.default.fileExists(atPath: path) }.value
            // After each wait, check the selection hasn't moved on: a slow volume answering late
            // used to paint "File no longer exists", or its thumbnail, under the next item
            guard !Task.isCancelled else { return }
            exists = present
            let loaded = await Self.loadThumbnail(path: path, exists: present)
            guard !Task.isCancelled else { return }
            thumbnail = loaded
        }
    }

    /// Replace the home directory with ~ so user names don't show up in mockups and screenshots
    private var abbreviatedPath: String {
        (path as NSString).abbreviatingWithTildeInPath
    }

    /// Nothing here touches the disk on the main thread.
    ///
    /// The existence check was moved off the main thread so a stalled network volume can't freeze the
    /// panel, but this function used to check again and ask NSWorkspace for the file's icon, both on
    /// the main thread, which undid it. A missing file gets the generic icon for its type, which needs
    /// no disk access; a present one gets its QuickLook thumbnail, with the file's own icon fetched off
    /// the main thread as the fallback.
    private static func loadThumbnail(path: String, exists: Bool) async -> NSImage? {
        let url = URL(fileURLWithPath: path)
        guard exists else {
            let type = UTType(filenameExtension: url.pathExtension) ?? .data
            return NSWorkspace.shared.icon(for: type)
        }
        let side = PanelMetrics.fileThumbnailSize
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: side, height: side),
                                                   scale: 2, representationTypes: .thumbnail)
        let thumbnail: NSImage? = await withCheckedContinuation { cont in
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in
                cont.resume(returning: ImageBox(rep?.nsImage))
            }
        }.image
        if let thumbnail { return thumbnail }
        return await Task.detached { ImageBox(NSWorkspace.shared.icon(forFile: path)) }.value.image
    }
}

/// Carries an NSImage out of a detached task. NSImage is Sendable only from the macOS 26 SDK on;
/// older toolchains refuse to let it cross an isolation boundary, and an image that was just
/// created on a background thread and is not shared with anything else is safe to hand over.
private struct ImageBox: @unchecked Sendable {
    let image: NSImage?
    init(_ image: NSImage?) { self.image = image }
}
