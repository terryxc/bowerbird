import BowerbirdCore
import SwiftUI

struct ItemRow: View {
    let item: ClipItem
    let index: Int
    let selected: Bool
    /// The current search query, used to bold the matching part of the title
    var query: String = ""
    var onPaste: () -> Void = {}
    var onPastePlain: () -> Void = {}
    var onCopy: () -> Void = {}
    var onRevealInFinder: () -> Void = {}
    var onTogglePin: () -> Void = {}
    var onDelete: () -> Void = {}
    /// On right-click, move the selection to this row first
    var onContextMenu: () -> Void = {}
    /// The key currently bound to an action, drawn in the menu's right column. The view doesn't reach
    /// into global settings itself; it's passed in from outside.
    var key: (PanelAction) -> (String, NSEvent.ModifierFlags)? = { _ in nil }

    /// Only paints the background and never touches the selection; selection follows clicks only
    @State private var hovering = false

    var body: some View {
        HStack(spacing: PanelMetrics.rowIconSpacing) {
            RowIcon(item: item)
            title
                .font(.system(size: PanelMetrics.rowTitleFontSize))
                .lineLimit(1)
                .truncationMode(.tail)
            // Pinned rows are all listed under the "Pinned" group, whose header already states their
            // status; a status pin on the row itself would be redundant.
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, PanelMetrics.rowHorizontalPadding)
        .frame(height: PanelMetrics.rowHeight)
        .background(
            RoundedRectangle(cornerRadius: PanelMetrics.rowCornerRadius)
                // The selected state is a very faint wash of the accent colour, with the text keeping
                // its normal colour. Filling the whole row with saturated purple and white text stood
                // out too much in a list, and was one of the main reasons it used to look clunky.
                //
                // Hover has its own layer, the same purple but much fainter, showing which row a click
                // would land on. It only paints the background and doesn't change the selection;
                // selection follows clicks only.
                .fill(selected ? AppColors.accentWash : (hovering ? AppColors.rowHover : .clear))
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        // Context menu: takes up no visual space, yet gives the mouse every action.
        //
        // The menu depends on the kind: images have no "Paste as Plain Text" to speak of, files get
        // "Paste Path" instead and can also be revealed in Finder. Both kinds of text get the same set:
        // "Paste as Plain Text" is redundant for plain-text-only items, but items of the same kind are
        // easier to recognize when their menus look the same.
        .overlay(RowContextMenu(entries: menuEntries, onOpen: onContextMenu))
    }

    /// Only builds an attributed string when there's a match. Without a search it takes the cheapest
    /// `Text(String)` path: an attributed title costs far more to draw than a plain one. See
    /// SearchHighlight.title.
    @ViewBuilder
    private var title: some View {
        if let marked = SearchHighlight.title(item.displayTitle, query: query) {
            Text(marked)
        } else {
            Text(item.displayTitle)
        }
    }

    /// Which entries this item gets. Built together with the item, so when the item changes (e.g. OCR
    /// produced a result) the row is rebuilt and the menu updates with it.
    private func menuEntries() -> [RowContextMenu.Entry] {
        var entries: [RowContextMenu.Entry] = [
            .init(title: L("Paste"), key: key(.paste), action: onPaste),
        ]
        switch item.kind {
        case .file:
            entries.append(.init(title: L("Paste Path"),
                                 key: key(.pastePlainText), action: onPastePlain))
        case .text:
            // For plain-text-only items this pastes the same thing, but a menu that always looks the
            // same is easier to recognize; the extra entry costs less than "same-kind items with
            // different menus"
            entries.append(.init(title: L("Paste as Plain Text"),
                                 key: key(.pastePlainText), action: onPastePlain))
        case .image:
            // Only once there are words to paste; before OCR lands the entry would do nothing
            if item.hasRecognizedText {
                entries.append(.init(title: L("Paste Text in Image"),
                                     key: key(.pastePlainText), action: onPastePlain))
            }
        }
        entries.append(.init(title: L("Copy"), key: key(.copy), action: onCopy))
        if item.kind == .file {
            entries.append(.init(title: L("Reveal in Finder"), action: onRevealInFinder))
        }
        entries.append(.init(title: L(item.pinned ? "Unpin" : "Pin"),
                             key: key(.togglePin), separatorBefore: true, action: onTogglePin))
        entries.append(.init(title: L("Delete"), key: key(.delete), action: onDelete))
        return entries
    }



    /// The first nine rows get ⌘N; the rest get nothing.
    ///
    /// The selected row used to also grow pin and delete icon buttons. They're gone: these two actions
    /// have labelled buttons with keycaps in the bottom bar, the full set in the context menu, and a
    /// shortcut each, so another copy at the end of the row was a fourth path. And since selection now
    /// follows clicks only, it's no faster either: click the row, then click the icon, is two steps,
    /// same as right-click plus a click. Without them every row looks the same, and ⌘N doesn't
    /// suddenly vanish on the selected row.
    @ViewBuilder
    private var trailing: some View {
        if index < 9 {
            Text(verbatim: "⌘\(index + 1)")
                .font(.system(size: PanelMetrics.rowShortcutFontSize, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(Color.secondary.opacity(max(0.25, 0.6 - 0.04 * Double(index))))
        }
    }
}

/// The icon at the start of the row.
///
/// Resolved in this order: for files, the file's own icon first (you can tell at a glance whether it's
/// a PDF or an image), then the source app's icon, and if neither is available, a symbol for the
/// content kind.
///
/// That last layer is required: things copied while the screen is locked come from
/// `com.apple.loginwindow`, and apps not installed in /Applications can't be looked up either. These
/// rows used to show up as a blank whitish square.
private struct RowIcon: View {
    let item: ClipItem

    var body: some View {
        Group {
            if let image = resolvedImage {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
            } else {
                Image(systemName: symbolName)
                    .font(.system(size: PanelMetrics.rowIconSize * 0.72, weight: .regular))
                    .foregroundStyle(.secondary)
                    .frame(width: PanelMetrics.rowIconSize, height: PanelMetrics.rowIconSize)
            }
        }
        .frame(width: PanelMetrics.rowIconSize, height: PanelMetrics.rowIconSize)
    }

    private var resolvedImage: NSImage? {
        if item.kind == .file, let path = item.filePaths.first,
           let icon = AppIconCache.shared.icon(forFileAt: path) {
            return icon
        }
        return AppIconCache.shared.icon(for: item.sourceBundleID)
    }

    private var symbolName: String {
        switch item.kind {
        case .text: "text.alignleft"
        case .image: "photo"
        case .file: "doc"
        }
    }
}
