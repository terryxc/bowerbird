import BowerbirdCore
import SwiftUI

enum SettingsPage: String, CaseIterable, Identifiable {
    case general, shortcuts, history, ignoredApps, about
    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .general: "General"
        case .shortcuts: "Shortcuts"
        case .history: "History"
        case .ignoredApps: "Ignore"
        case .about: "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .shortcuts: "keyboard"
        case .history: "clock"
        case .ignoredApps: "eye.slash"
        case .about: "info.circle"
        }
    }
}

/// Settings window sizes and layout, measured from WeChat Input Method's settings panel:
/// the sidebar is slightly darker than the content area, items are 38 tall, and the selection is a
/// rounded pill. The content area is white with grouped cards; rows inside a card are separated by
/// hairlines inset to where the title starts.
enum SettingsMetrics {
    // Sized against WeChat Input Method's settings window (about 715 × 566): a settings window
    // that is larger than the apps around it feels out of place, and on a 13-inch screen it crowds
    // the display. General, the tallest page, fits without scrolling at this height.
    static let windowWidth: CGFloat = 700
    static let windowHeight: CGFloat = 560

    static let sidebarWidth: CGFloat = 180
    static let sidebarPadding: CGFloat = 10
    /// Height reserved for the traffic-light buttons
    static let sidebarTopInset: CGFloat = 38
    static let sidebarItemHeight: CGFloat = 38
    static let sidebarItemRadius = Radius.row
    static let sidebarIconSize: CGFloat = 15
    static let sidebarFontSize: CGFloat = 13

    static let contentPadding: CGFloat = 20
    /// The title sits this far below the window's top edge; the content column has no title bar
    /// above it (that space belongs to the sidebar's traffic lights), so it starts at the top.
    static let contentTopPadding: CGFloat = 22
    static let pageTitleFontSize: CGFloat = 17
    static let cardSpacing: CGFloat = 12
    static let cardRadius = Radius.card
    static let cardHorizontalPadding: CGFloat = 16

    static let rowMinHeight: CGFloat = 40
    static let rowWithSubtitleMinHeight: CGFloat = 50
    static let rowTitleFontSize: CGFloat = 13
    static let rowSubtitleFontSize: CGFloat = 11
    static let captionFontSize: CGFloat = 11

    /// Shared width for the fixed-width controls in the right column.
    ///
    /// Both pickers and steppers use it so their right edges line up. A segmented control was tried
    /// once, but it grows to fit its content and ignores the given width ("System / Light / Dark"
    /// overflowed), leaving three rows of controls with three different right edges. See "Control
    /// choices" below.
    static let controlWidth: CGFloat = 150
    /// Width for a pair of text buttons that sit in one card and should line up (About). Elsewhere
    /// a button hugs its label; a lone wide button in a row looks wrong.
    static let pairedButtonWidth: CGFloat = 120

    /// Sizes for a row of small options live in ChipMetrics, shared with the panel's format bar

    /// Width of the shortcut recorder itself; narrower than controlWidth, aligned right
    static let shortcutFieldWidth: CGFloat = 120

    /// Hit area of the icon button at the end of each row, and the point size of its symbol
    static let rowActionSize: CGFloat = 20
    static let rowActionSymbolSize: CGFloat = 12
    /// App icon at the start of a row, and the symbol that stands in when the app isn't installed
    static let rowIconSize: CGFloat = 20
    static let rowIconSymbolSize: CGFloat = 14
    /// Minimum height of the empty-state text in a card, so the card doesn't collapse into a strip
    static let emptyStateMinHeight: CGFloat = 64
}

// MARK: - Control choices
//
// Settings pages use only these controls, so the same kind of interaction looks the same on every page:
//
// | Interaction                  | Control                                         | Width         |
// | ---------------------------- | ----------------------------------------------- | ------------- |
// | On/off                       | Toggle, switch style                            | intrinsic     |
// | Pick one (more than 2 items) | Picker, menu style                              | controlWidth  |
// | Number                       | Stepper plus right-aligned value                | controlWidth  |
// | Action                       | Button, bordered, small                         | intrinsic     |
// | Destructive action           | Same, plus destructive role                     | intrinsic     |
// | Status                       | 9 pt dot plus subtitle; button only if needed   | intrinsic     |
// | Action on a single item      | Icon button at the end of that item's row       | rowActionSize |
//
// Two hard rules:
// 1. Pick-one is always a menu picker, never a segmented control, even with only three options.
//    Language has seven options and must be a menu; mixing both kinds in one card looks bad.
// 2. An action on a single item goes at the end of that item's own row, not in a separate row of
//    buttons under the card. That would need select-then-click, an extra step, and it wouldn't be
//    clear which item the button acts on.
extension SettingsMetrics {
}

struct SettingsView: View {
    private static let contentScrollSpace = "bowerbird.settings.content"
    let store: HistoryStore
    @State private var page: SettingsPage = .general
    /// Geometry for the thin scroll indicator; see the panel list for the same arrangement
    @State private var contentScroll = ScrollTracker()

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: SettingsMetrics.sidebarWidth)
                // The sidebar is one step darker than the content area. Darkening it with a
                // Color.primary overlay doesn't work: in dark mode primary is white, so it would
                // lighten instead. Each mode gets an explicit value.
                .background(AppColors.sidebarBackground)
            Rectangle()
                .fill(AppColors.separator)
                .frame(width: Hairline.width)
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(AppColors.contentBackground)
        }
        .frame(width: SettingsMetrics.windowWidth, height: SettingsMetrics.windowHeight)
        // "About Bowerbird" in the app menu switches to the About page
        .onReceive(NotificationCenter.default.publisher(for: .bowerbirdSettingsPageRequested)) { note in
            if let requested = note.object as? SettingsPage { page = requested }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            Spacer().frame(height: SettingsMetrics.sidebarTopInset)
            ForEach(SettingsPage.allCases) { item in
                SidebarItem(page: item, selected: page == item) { page = item }
            }
            Spacer()
        }
        .padding(SettingsMetrics.sidebarPadding)
    }

    private var detail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SettingsMetrics.cardSpacing) {
                Text(page.title)
                    .font(.system(size: SettingsMetrics.pageTitleFontSize, weight: .semibold))
                    .padding(.bottom, 2)
                switch page {
                case .general: GeneralSettingsPage()
                case .shortcuts: ShortcutsSettingsPage()
                case .history: HistorySettingsPage(store: store)
                case .ignoredApps: IgnorePage()
                case .about: AboutPage(store: store)
                }
            }
            .padding(.horizontal, SettingsMetrics.contentPadding)
            .padding(.bottom, SettingsMetrics.contentPadding)
            .padding(.top, SettingsMetrics.contentTopPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ScrollGeometryReporter(space: Self.contentScrollSpace, tracker: contentScroll))
        }
        // The hidden title bar is a safe-area inset the scroll view would otherwise honour, pushing
        // the title down by a title bar's height for nothing
        .ignoresSafeArea(.container, edges: .top)
        // The same thin indicator as the panel. The system scroller, with a mouse attached, is the
        // legacy kind: a permanent track and a thumb that nearly fills it when the page is only a
        // little taller than the window, which is exactly how a long Ignore list looked.
        .scrollIndicators(.never)
        .thinScrollIndicator(space: Self.contentScrollSpace, tracker: contentScroll)
        // Scroll back to the top when the page changes. One ScrollView hosts every page; without
        // rebuilding it, the next page starts wherever the previous one was scrolled to, with the
        // title and first card out of view.
        .id(page)
    }
}

/// Grouped card. Rows inside draw their own dividers; the card only handles background and corners.
struct SettingsCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .background(AppColors.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: SettingsMetrics.cardRadius))
            .overlay(
                RoundedRectangle(cornerRadius: SettingsMetrics.cardRadius)
                    .strokeBorder(AppColors.separator, lineWidth: Hairline.width)
            )
    }
}

struct SettingsRow<Trailing: View, Leading: View>: View {
    let title: LocalizedStringKey
    var subtitle: LocalizedStringKey? = nil
    /// An already-localized subtitle. Text with plural rules must be resolved through L() first and
    /// passed in here; interpolating into a LocalizedStringKey directly skips the stringsdict.
    var subtitleText: String? = nil
    /// Small item before the title, such as a status dot
    var leading: () -> Leading
    @ViewBuilder let trailing: Trailing

    init(title: LocalizedStringKey, subtitle: LocalizedStringKey? = nil, subtitleText: String? = nil,
         @ViewBuilder leading: @escaping () -> Leading,
         @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.subtitleText = subtitleText
        self.leading = leading
        self.trailing = trailing()
    }

    init(title: LocalizedStringKey, subtitle: LocalizedStringKey? = nil, subtitleText: String? = nil,
         @ViewBuilder trailing: () -> Trailing) where Leading == EmptyView {
        self.init(title: title, subtitle: subtitle, subtitleText: subtitleText,
                  leading: { EmptyView() }, trailing: trailing)
    }

    var body: some View {
        HStack(spacing: 14) {
            leading()
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: SettingsMetrics.rowTitleFontSize))
                if let subtitleText {
                    Text(subtitleText)
                        .font(.system(size: SettingsMetrics.rowSubtitleFontSize))
                        .foregroundStyle(.secondary)
                } else if let subtitle {
                    Text(subtitle)
                        .font(.system(size: SettingsMetrics.rowSubtitleFontSize))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, SettingsMetrics.cardHorizontalPadding)
        .padding(.vertical, 8)
        .frame(minHeight: subtitle == nil && subtitleText == nil
               ? SettingsMetrics.rowMinHeight : SettingsMetrics.rowWithSubtitleMinHeight)
    }
}

/// Divider inside a card: inset to where the title starts, running to the card's right edge.
/// That is how WeChat Input Method does it.
struct SettingsDivider: View {
    var body: some View {
        Rectangle()
            .fill(AppColors.separator)
            .frame(height: Hairline.width)
            .padding(.leading, SettingsMetrics.cardHorizontalPadding)
    }
}

/// Explanatory text above a card
struct SettingsCaption: View {
    let text: LocalizedStringKey

    var body: some View {
        Text(text)
            .font(.system(size: SettingsMetrics.captionFontSize))
            .foregroundStyle(.secondary)
            // Aligned with the card's left edge, no extra inset
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SidebarItem: View {
    let page: SettingsPage
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: page.symbol)
                    .font(.system(size: SettingsMetrics.sidebarIconSize))
                    .frame(width: 20)
                Text(page.title)
                    .font(.system(size: SettingsMetrics.sidebarFontSize))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: SettingsMetrics.sidebarItemHeight)
            .foregroundStyle(selected ? Color.white : Color.primary)
            .background(background)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    private var background: some View {
        RoundedRectangle(cornerRadius: SettingsMetrics.sidebarItemRadius)
            .fill(fill)
    }

    private var fill: Color {
        if selected { return AppColors.accentFill }
        return hovering ? AppColors.accentWashHover : Color.clear
    }
}

// MARK: - Shared control styles
//
// Each control's style is written once here and applied in pages via a modifier, leaving pages no
// room to improvise.

/// Action buttons: always small and bordered; destructive actions add the destructive role
struct SettingsButtonStyle: ViewModifier {
    var prominent: Bool = false
    var destructive: Bool = false

    func body(content: Content) -> some View {
        Group {
            if prominent {
                content.buttonStyle(.borderedProminent).tint(AppColors.accentFill)
            } else {
                content.buttonStyle(.bordered)
            }
        }
        .controlSize(.small)
    }
}

/// A text button for the right column of a row. Natural width, or a fixed one when buttons in the
/// same card should line up.
struct SettingsActionButton: View {
    let title: LocalizedStringKey
    var width: CGFloat? = nil
    let action: () -> Void

    init(_ title: LocalizedStringKey, width: CGFloat? = nil, action: @escaping () -> Void) {
        self.title = title
        self.width = width
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            if let width {
                Text(title).frame(width: width)
            } else {
                Text(title)
            }
        }
        .modifier(SettingsButtonStyle())
    }
}

/// Switch. The app's accent colour is purple, while system switches follow the system accent colour,
/// usually blue. Two accent colours in one window: five blue switches on the History page next to the
/// purple sidebar and chips stood out badly.
struct SettingsToggle: View {
    @Binding var isOn: Bool

    var body: some View {
        Toggle("", isOn: $isOn)
            .labelsHidden()
            .toggleStyle(.switch)
            .tint(AppColors.accentFill)
            // Small, like the pickers, steppers and buttons in the same column. The default size
            // is noticeably taller than they are, giving one column two control heights.
            .controlSize(.small)
    }
}

/// The text shown when a card has no items. Making it a settings row would look like an option
/// called "None".
struct SettingsEmptyText: View {
    let text: LocalizedStringKey

    var body: some View {
        Text(text)
            .font(.system(size: SettingsMetrics.rowTitleFontSize))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, SettingsMetrics.cardHorizontalPadding)
            .frame(maxWidth: .infinity, minHeight: SettingsMetrics.emptyStateMinHeight)
    }
}

/// Status dot: green when on, grey when off.
struct StatusDot: View {
    var on = true

    var body: some View {
        Circle()
            .fill(on ? AppColors.ok : Color.secondary.opacity(0.35))
            .frame(width: 9, height: 9)
    }
}

/// Icon button at the end of an item's row, e.g. "remove this app from the list".
/// Normally secondary grey; on hover the symbol darkens to the text colour. It used to fill red on
/// hover, as the panel's delete button does; in a settings list that read as an alarm for what is
/// only "take this off the list".
struct RowActionButton: View {
    let symbol: String
    let help: LocalizedStringKey
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: SettingsMetrics.rowActionSymbolSize, weight: .medium))
                .foregroundStyle(hovering ? Color.primary : Color.secondary)
                .frame(width: SettingsMetrics.rowActionSize,
                       height: SettingsMetrics.rowActionSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovering = $0 }
    }
}
