import CoreGraphics

/// Panel size presets.
///
/// Alfred has no drag-to-resize: the width is an integer in the theme file (community recreations
/// of the default theme mostly use 560 pt; the official minimum is 400), and the clipboard window
/// follows the theme width. Raycast doesn't allow dragging either and only offers three Interface
/// Size presets. Same idea here: fixed presets, no resize handle.
///
/// The medium preset, 760×480, matches Raycast's clipboard history as measured (750×474).
enum PanelSize: String, CaseIterable, Identifiable, Codable {
    case small, medium, large
    var id: String { rawValue }

    var dimensions: CGSize {
        switch self {
        case .small: CGSize(width: 640, height: 420)
        case .medium: CGSize(width: 760, height: 480)
        case .large: CGSize(width: 920, height: 580)
        }
    }

    /// Number of rows the list shows in full; used in Settings to give an intuitive description.
    /// Row height changes with the text size, and so does the row count, so this reads the
    /// current preset's dimensions.
    @MainActor
    var visibleRows: Int {
        let listHeight = dimensions.height
            - PanelMetrics.searchHeight
            - PanelMetrics.footerHeight
            - PanelMetrics.listVerticalPadding * 2
        return Int(listHeight / PanelMetrics.rowHeight)
    }
}

/// Fixed layout metrics inside the panel, based on measurements of Raycast's clipboard history.
///
/// Easy things to get wrong: text should be small (title 13, search 15, not 18 and 20),
/// icons should stay small (20, not 22; 16 turned out too small, see rowIconSize), the left column takes only 40% of the width and leaves
/// the rest to the preview, and the selection uses a light grey fill, not a saturated accent colour.
enum PanelMetrics {
    /// How much the current preset scales text up. Every font size goes through this; see PanelTextSize.
    @MainActor
    static func scaled(_ base: CGFloat) -> CGFloat {
        AppSettings.shared.panelTextSize.scaled(base)
    }

    static let cornerRadius = Radius.window

    /// Full height of the search row.
    /// 18.5 above and below the text; at the standard preset that is exactly the old 52.
    @MainActor static var searchHeight: CGFloat { searchFontSize + 37 }
    @MainActor static var searchFontSize: CGFloat { scaled(15) }
    /// Horizontal content inset shared by the whole panel. The search row and the footer hint bar
    /// use it directly; the list gets the same value from listHorizontalPadding + rowHorizontalPadding,
    /// so the search text, the row icons and the footer hints all share one left edge.
    static let contentInset: CGFloat = 18
    static let searchHorizontalPadding = contentInset

    /// Footer shortcut hint bar
    static let footerHeight: CGFloat = 34
    @MainActor static var footerFontSize: CGFloat { scaled(11) }
    /// Key caps in the footer hints. Square; sized to suit 11 pt text
    @MainActor static var keyCapSize: CGFloat { footerFontSize + 4 }
    /// Padding of each individual hint; this is the size of the hover background
    static let footerHintPaddingH: CGFloat = 5
    static let footerHintPaddingV: CGFloat = 2

    /// The two lines of text shown when the list is empty
    @MainActor static var emptyStateFontSize: CGFloat { scaled(12) }
    static let emptyStateSpacing: CGFloat = 4

    /// Fraction of the panel width taken by the left list; the rest goes to the preview
    static let listWidthFraction: CGFloat = 0.4

    static let listHorizontalPadding: CGFloat = 8
    static let listVerticalPadding: CGFloat = 6
    @MainActor static var sectionHeaderFontSize: CGFloat { scaled(11) }

    /// Row height. It was 40 at first, copied from Raycast, but that suits 14 pt text plus a subtitle.
    /// Our rows hold only a 20 pt icon and a single-line 13 pt title, so 40 left 60% empty and the
    /// list looked loose. macOS's own single-line 13 pt lists (sidebar "Large" size) use 32.
    /// We use 34: 7 above and below the icon, 9 above and below the text, and room for a 20 pt trailing button.
    @MainActor static var rowHeight: CGFloat { rowTitleFontSize + 21 }
    static let rowCornerRadius = Radius.row
    /// Section headers: the first sits flush with the top of the list; the others leave a gap after the previous section
    static let sectionHeaderTopInset: CGFloat = 2
    static let sectionHeaderGap: CGFloat = 8
    static let sectionHeaderBottomInset: CGFloat = 2
    static let rowHorizontalPadding: CGFloat = contentInset - listHorizontalPadding
    /// Leading row icon. 16 was too small in a 40-high row and app icon details turned to mush;
    /// 20 is legible without overpowering the 13 pt title.
    static let rowIconSize: CGFloat = 20
    static let rowIconSpacing: CGFloat = 10
    @MainActor static var rowTitleFontSize: CGFloat { scaled(13) }
    @MainActor static var rowShortcutFontSize: CGFloat { scaled(11) }
    /// Hit area of the trailing row action button; same height as ChipMetrics.height
    static let rowActionSize: CGFloat = 20
    static let previewPadding = contentInset
    /// Preview body text. It used to be 12, which is the secondary-text size; this is content meant
    /// to be read as paragraphs, and macOS body text is 13.
    @MainActor static var previewTextFontSize: CGFloat { scaled(13) }
    /// Metadata at the bottom right of the preview; the path in file previews uses it too
    @MainActor static var previewMetaFontSize: CGFloat { scaled(11) }
    /// File preview: thumbnail side length, and the gap between the thumbnail and the path
    static let fileThumbnailSize: CGFloat = 200
    static let filePreviewSpacing: CGFloat = 12

    /// Format bar at the top of the preview. Same height as the footer hint bar; no new number.
    /// The chip sizes themselves live in ChipMetrics, shared with the Settings window.
    static let formatBarHeight: CGFloat = 32
    /// Leading position of the format bar.
    ///
    /// The chips are borderless capsules, so the eye reads the left edge of the **text**, not of the
    /// background. With the background aligned to contentInset, the labels sit one padding to the right
    /// of the body text below and look crooked. So it steps back by one padding, lining up the first
    /// chip's text with the body text. Buttons in the action row are the opposite: they have a border,
    /// the border is the real edge, so they align by the box.
    static let formatBarLeadingInset = contentInset - ChipMetrics.paddingH

    /// Status bar shown under the search field while paused. Same height as the format bar.
    static let statusBarHeight = formatBarHeight
    static let statusBarSpacing: CGFloat = 6

    /// Permission explanation card. Its height follows the content (as many lines as the copy
    /// needs), not a round number.
    static let permissionCardPaddingV: CGFloat = 14
    @MainActor static var permissionTitleFontSize: CGFloat { rowTitleFontSize }
    /// Height of the title line. The icon and the trailing button both align to it, so all three
    /// share one centre line rather than each centring on the whole text block.
    @MainActor static var permissionTitleLineHeight: CGFloat { permissionTitleFontSize + 4 }
    static let permissionIconSize: CGFloat = 15
    /// Between lines. Slightly tighter than normal line spacing, so the four lines read as one
    /// paragraph rather than four separate hints.
    static let permissionLineSpacing: CGFloat = 3
    /// Between the text and the button. Noticeably larger than the line spacing, so the button
    /// doesn't look like a fifth line of body text.
    static let permissionButtonGap: CGFloat = 10

    /// Bottom row of the preview: actions on the left, metadata on the right
    static let actionRowHeight: CGFloat = 32
    /// A small gap between the action row and the content so they don't touch
    static let actionRowTopGap: CGFloat = 4
    /// Between the buttons and the metadata in the action row
    static let actionRowSpacing: CGFloat = 12
    /// Top inset of the content area. There is already a divider under the format bar,
    /// so a full 18 looks too loose; reduced to 12.
    static let previewTopInsetUnderFormatBar: CGFloat = 12
    static let previewBottomInset: CGFloat = 12

    /// Custom-drawn scroll indicator
    static let scrollIndicatorWidth: CGFloat = 3
    static let scrollIndicatorInset: CGFloat = 3
    static let scrollIndicatorMinLength: CGFloat = 24

    /// Divider width: one physical pixel
    static var hairline: CGFloat { Hairline.width }
}
