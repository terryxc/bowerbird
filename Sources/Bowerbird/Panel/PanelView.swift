import BowerbirdCore
import SwiftUI

struct PanelView: View {
    private static let listScrollSpace = "bowerbird.panel.list"
    /// @State rather than @StateObject: **own it, but don't subscribe to it.**
    ///
    /// This view's body never reads the tracker; the scroll indicator reads it itself
    /// (the @ObservedObject in ScrollIndicator). @StateObject would declare a dependency on our
    /// behalf that's never used, so every frame of scrolling would re-run this view's body for nothing.
    ///
    /// The actual saving is small: 0.23 → 0.19 ms per scroll step measured with AX-driven scrolling,
    /// and synthesised scroll-wheel events don't reach the app on macOS 26, so the cumulative effect
    /// of a real finger swipe can't be measured. It's kept mainly not for those 0.04 ms but because
    /// @StateObject here would state something that isn't true.
    @State private var listScroll = ScrollTracker()
    @ObservedObject var model: PanelModel
    /// The footer hints read the real key bindings and the paused bar reads the paused state; both
    /// must follow changes made in Settings
    @ObservedObject private var settings = AppSettings.shared
    /// The warning in the footer and the explanation card both follow this
    @ObservedObject private var permission = AccessibilityPermission.shared
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            searchField
            hairline
            if model.showsPermissionCard {
                AccessibilityCard(
                    targetName: model.pasteTarget?.localizedName,
                    hasAsked: permission.hasAsked,
                    onGrant: { model.grantAccessibility() },
                    onDismiss: { model.dismissPermissionCard() },
                    onShowInFinder: { permission.showInFinder() }
                )
                hairline
            }
            if settings.paused {
                pausedBar
                hairline
            }
            GeometryReader { geo in
                HStack(spacing: 0) {
                    list
                        .frame(width: geo.size.width * PanelMetrics.listWidthFraction)
                    verticalHairline
                    PreviewPane(model: model, store: model.store)
                        .frame(maxWidth: .infinity)
                }
            }
            if showsFooter {
                hairline
                footer
            }
        }
        .onAppear { searchFocused = true }
        .onChange(of: model.focusToken) { _, _ in searchFocused = true }
        // Picking a kind from the menu leaves focus on its button; the caret belongs in the field
        .onChange(of: model.kindFilter) { _, _ in searchFocused = true }
    }


    /// Not a filled text box: the row is just text and a caret, separated by the hairline below,
    /// as in Alfred and Raycast.
    private var searchField: some View {
        HStack(spacing: PanelMetrics.contentInset) {
            TextField(text: $model.query) {
                Text("Search clipboard history…").foregroundStyle(.tertiary)
            }
            .textFieldStyle(.plain)
            .font(.system(size: PanelMetrics.searchFontSize))
            .focused($searchFocused)
            // Return goes through here rather than the key monitor: while an input method is composing,
            // Return belongs to the input method and never gets here
            .onSubmit {
                // Return performs whatever action is bound to it; if nothing is bound, it does nothing
                if let action = PanelAction.allCases.first(where: { settings.shortcut(for: $0)?.isBareReturn == true }) {
                    model.perform(action)
                }
            }
            kindMenu
        }
        .padding(.horizontal, PanelMetrics.searchHorizontalPadding)
        // The whole row is the text field; no drag handle here. We tried shrinking the field to 24 pt
        // in the middle with a strip above and below as handles. It looked no different, but clicks on
        // those strips no longer placed the caret, and the search row lost its "the whole row is
        // input" feel. Not worth it for a handle.
        .frame(height: PanelMetrics.searchHeight)
    }

    /// The kind filter at the right end of the search row, as in Raycast: the current kind and a
    /// chevron, a native menu on click. No key of its own; the mouse is the way in.
    private var kindMenu: some View {
        Menu {
            Picker("", selection: $model.kindFilter) {
                ForEach(PanelModel.kindFilterChoices, id: \.self) { kind in
                    Text(PanelModel.kindFilterLabel(kind)).tag(kind)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: 4) {
                Text(model.kindFilterLabel)
                Image(systemName: "chevron.down")
                    .font(.system(size: PanelMetrics.footerFontSize - 2, weight: .semibold))
            }
            .font(.system(size: PanelMetrics.footerFontSize))
            // Secondary until a kind is chosen; then the accent, so a short list is explained at a glance
            .foregroundStyle(model.kindFilter == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(AppColors.accent))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    /// A bar across the panel below the search field while paused.
    ///
    /// Originally the only sign was the menu bar icon dimmed by 40%. That bit of transparency isn't
    /// enough to signal a state: during the JPEG testing nothing got recorded, and even I thought it
    /// was a bug. Opening the panel is the most frequent action, so the state is sure to be seen
    /// here, and you can resume right there without reaching for the menu bar.
    private var pausedBar: some View {
        HStack(spacing: PanelMetrics.statusBarSpacing) {
            Image(systemName: "pause.circle.fill")
            Text("Paused. New copies are not being saved.")
                .lineLimit(1)
            Spacer(minLength: 8)
            PanelActionButton(title: L("Resume Recording")) { settings.paused = false }
        }
        .font(.system(size: PanelMetrics.footerFontSize))
        .foregroundStyle(.secondary)
        .padding(.horizontal, PanelMetrics.contentInset)
        .frame(height: PanelMetrics.statusBarHeight)
        .background(AppColors.subtleFill)
    }

    /// With the hint bar turned off, nothing is drawn. If there's no Accessibility permission and
    /// Return is meant to paste, that warning matters more than the 34 pt saved, so it still shows.
    private var showsFooter: Bool {
        settings.showsFooterHints || needsAccessibilityWarning
    }

    /// Without permission nothing can be pasted, so warn about it. Don't repeat it when the
    /// explanation card is already open.
    private var needsAccessibilityWarning: Bool {
        !permission.isTrusted && !model.showsPermissionCard
    }

    /// Keyboard hints along the bottom, following Raycast. They explain the keys and also give the
    /// panel a clean bottom edge.
    private var footer: some View {
        HStack(spacing: 14) {
            if needsAccessibilityWarning {
                // Without Accessibility permission Return only copies, so don't say "Paste" here.
                //
                // Like the hints next to it, this is only a hint and doesn't take clicks. It already
                // says which key to press: press Return and the explanation card opens and spells it
                // out. Making it clickable would give the card two entry points and two situations
                // (one where copied content is already in hand, one where it isn't), and the same
                // card would need two sets of wording. Not worth half as much copy again for a minor path.
                Label("Enter only copies. Grant Accessibility to paste.",
                      systemImage: "exclamationmark.triangle")
            }
            HStack(spacing: 14) {
                if !needsAccessibilityWarning {
                    // When a format is chosen, put it in the hint so nobody has to read the small
                    // print in the bottom-right corner.
                    // Actions whose key was removed don't show at all: this row is keyboard hints,
                    // and with no key there's nothing to hint. Mouse users have double-click and the
                    // context menu
                    if let keys = keyCaps(.paste) {
                        hint(model.pasteHintLabel, keys: keys)
                    }
                    // The other way to paste this item: plain text, the file's path, the words in an
                    // image. Hinted whenever the item has one and it isn't what Return already does,
                    // because it is easy to forget the key exists. An image without recognised text
                    // has no second way, so no hint.
                    if let keys = keyCaps(.pastePlainText), let item = model.selected,
                       item.textVariant != .asCaptured, item.textVariant != model.variant {
                        hint(PanelModel.pasteTitle(for: item.textVariant), keys: keys)
                    }
                    if let keys = keyCaps(.copy) {
                        hint("Copy", keys: keys)
                    }
                    // Only hint when there really is a choice; shown and hidden together with the format bar
                    if model.showsFormatBar, let keys = keyCaps(.cycleFormat) {
                        hint("Format", keys: keys)
                    }
                }
                // Only the three used every time are hinted. Pin and delete are occasional actions;
                // their keys are listed on the Shortcuts page in Settings and in the context menu.
                // Every extra entry in an always-visible row costs attention.
                Spacer(minLength: 0)
            }
            // A gear on the far right goes straight to Settings. It's in the menu bar too, but with
            // the panel open you shouldn't have to reach for the menu bar.
            FooterIconButton(symbol: "gearshape", help: "Settings…") { model.onOpenSettings?() }
        }
        .font(.system(size: PanelMetrics.footerFontSize))
        .foregroundStyle(.secondary)
        .padding(.horizontal, PanelMetrics.contentInset)
        .frame(height: PanelMetrics.footerHeight)
    }

    /// The key cap in the context menu's right column; reads the same binding as the footer hints.
    private func menuKey(_ action: PanelAction) -> (String, NSEvent.ModifierFlags)? {
        guard let shortcut = settings.shortcut(for: action),
              let equivalent = shortcut.menuKeyEquivalent else { return nil }
        return (equivalent, shortcut.flags)
    }

    /// Key caps always come from the real binding. ⌘P, ⌘⌫ and ⌘↩ used to be hard-coded, and once
    /// a key was changed the hints lied.
    /// nil means the action has no key.
    private func keyCaps(_ action: PanelAction) -> [String]? {
        settings.shortcut(for: action)?.keyCaps
    }

    /// This row only explains keys; it doesn't take clicks.
    ///
    /// It was once made of buttons, since the space was there anyway and mouse users could use it
    /// too. But in practice nobody saw them as buttons; they look exactly like a row of shortcut
    /// notes. Mouse users have double-click and the context menu, and explanation and action
    /// shouldn't be mixed in one place.
    private func hint(_ label: LocalizedStringKey, keys: [String]) -> some View {
        FooterHint(label: label, keys: keys)
    }

    private func hint(_ text: String, keys: [String]) -> some View {
        FooterHint(label: LocalizedStringKey(text), keys: keys)
    }

    private var hairline: some View {
        Rectangle()
            .fill(AppColors.separator)
            .frame(height: PanelMetrics.hairline)
    }

    private var verticalHairline: some View {
        Rectangle()
            .fill(AppColors.separator)
            .frame(width: PanelMetrics.hairline)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                        if let header = sectionHeader(at: index) {
                            Text(header)
                                .font(.system(size: PanelMetrics.sectionHeaderFontSize, weight: .medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, PanelMetrics.rowHorizontalPadding)
                                .padding(.top, index == 0 ? PanelMetrics.sectionHeaderTopInset
                                                          : PanelMetrics.sectionHeaderGap)
                                .padding(.bottom, PanelMetrics.sectionHeaderBottomInset)
                        }
                        // Row actions always go by the item's id, never by index: the list can
                        // refresh while the context menu is open, and by index a click could act on a
                        // different item that moved up into that slot.
                        ItemRow(item: item,
                                index: index,
                                selected: item.id == model.selectedID,
                                query: model.query,
                                onPaste: { model.activate(id: item.id, copyOnly: false) },
                                onPastePlain: { model.pastePlainText(id: item.id) },
                                onCopy: { model.activate(id: item.id, copyOnly: true) },
                                onRevealInFinder: { model.revealInFinder(id: item.id) },
                                onTogglePin: { model.togglePin(id: item.id) },
                                onDelete: { model.delete(id: item.id) },
                                onContextMenu: { model.select(id: item.id) },
                                key: menuKey)
                            .id(item.id)
                            // Deletion follows iOS lists: the row slides out to the left and fades,
                            // and the rows below spring up to fill the gap
                            .transition(.asymmetric(
                                insertion: .opacity,
                                removal: .move(edge: .leading).combined(with: .opacity)))
                            // Double-clicking a list item to run the default action is the most
                            // standard mouse habit on macOS; Finder, Mail and Xcode all do it.
                            // Without it, mouse users would have to dig through the context menu
                            // or click the row along the bottom.
                            .onTapGesture(count: 2) {
                                model.select(id: item.id)
                                model.perform(.paste)
                            }
                            // Selection follows clicks, not hover. Paste, copy, pin and delete in
                            // the footer all act on the selected item, and on the way to the footer
                            // the mouse crosses other rows. If hover selected, by the time you
                            // clicked the selection would already be whatever row you passed over.
                            // Finder and Mail also select only on click.
                            //
                            // The single tap uses simultaneousGesture: with a plain single-tap
                            // gesture next to the double-tap, SwiftUI holds the single tap until the
                            // double-tap window passes (about half a second), so a click takes
                            // ages to select.
                            .simultaneousGesture(TapGesture().onEnded { model.select(id: item.id) })
                            .onAppear { model.loadMoreIfNeeded(currentIndex: index) }
                    }
                }
                .padding(.horizontal, PanelMetrics.listHorizontalPadding)
                .background(ScrollGeometryReporter(space: Self.listScrollSpace, tracker: listScroll,
                                                   verticalMargin: PanelMetrics.listVerticalPadding))
            }
            // The top and bottom space is a margin on the scroll view, not padding on the content.
            //
            // The difference shows in scrollTo: padding is part of the content and scrolls out with
            // it when the first item is scrolled to the top, so "first open" and "reopen after
            // scrolling" differed by 6 pt at the top, measured from screenshots (section header at
            // 67 pt vs 61 pt). A margin belongs to the scroll view itself, and scrollTo respects it.
            .contentMargins(.vertical, PanelMetrics.listVerticalPadding, for: .scrollContent)
            .scrollIndicators(.never)
            .thinScrollIndicator(space: Self.listScrollSpace, tracker: listScroll)
            .onChange(of: model.selectedIndex) { _, newValue in
                guard model.items.indices.contains(newValue) else { return }
                proxy.scrollTo(model.items[newValue].id)
            }
        }
        .overlay {
            if model.loaded, model.items.isEmpty { emptyState }
        }
    }

    /// Two lines of text for when the list is empty.
    ///
    /// Without it, a search with no results leaves the left column blank and the right pane blank,
    /// and you can't tell "no matches" from "broken". It only takes the list column: the right pane
    /// only shows something once something is selected, so leaving it blank is correct.
    private var emptyState: some View {
        VStack(spacing: PanelMetrics.emptyStateSpacing) {
            if model.query.isEmpty {
                Text("Nothing here yet")
                Text("Copy something and it will show up here")
                    .foregroundStyle(.tertiary)
            } else {
                Text(L("No matches for “%@”", model.query))
            }
        }
        .font(.system(size: PanelMetrics.emptyStateFontSize))
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .padding(.horizontal, PanelMetrics.contentInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Section headers: pinned items lead as their own group, the rest are split into
    /// "Today / Yesterday / date", and a header appears only above the first item of its section.
    /// During search the fuzzy matches go at the end as their own "Close matches" group. They
    /// aren't ordered by day, so mixing them into the date sections would be a lie.
    private func sectionHeader(at index: Int) -> String? {
        guard model.items.indices.contains(index) else { return nil }
        let item = model.items[index]
        let previous = index > 0 ? model.items[index - 1] : nil
        if model.isFuzzy(item) {
            return previous.map(model.isFuzzy) == true ? nil : L("Close matches")
        }
        if item.pinned {
            return previous == nil ? L("Pinned") : nil
        }
        // Group by sortDate, the same key used for sorting: an item that was just pasted moves to
        // the top and should appear under "Today", not still carry the label of the day it was copied
        let label = dayLabel(for: item.sortDate)
        if let previous, !previous.pinned, dayLabel(for: previous.sortDate) == label {
            return nil
        }
        return label
    }

    private func dayLabel(for date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return L("Today") }
        if calendar.isDateInYesterday(date) { return L("Yesterday") }
        return date.formatted(date: .abbreviated, time: .omitted)
    }
}

private struct FooterHint: View {
    let label: LocalizedStringKey
    let keys: [String]

    var body: some View {
        HStack(spacing: 4) {
            Text(label)
            ForEach(keys, id: \.self) { key in
                Text(key)
                    .frame(minWidth: PanelMetrics.keyCapSize, minHeight: PanelMetrics.keyCapSize)
                    .background(
                        RoundedRectangle(cornerRadius: Radius.chip)
                            .fill(AppColors.subtleFill)
                    )
            }
        }
        .padding(.horizontal, PanelMetrics.footerHintPaddingH)
        .padding(.vertical, PanelMetrics.footerHintPaddingV)
    }
}

/// The only button in the footer hint bar: the gear. The icon looks clickable, which sets it apart
/// from the notes next to it
private struct FooterIconButton: View {
    let symbol: String
    let help: LocalizedStringKey
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: PanelMetrics.footerFontSize + 1, weight: .medium))
                .frame(width: PanelMetrics.rowActionSize, height: PanelMetrics.rowActionSize)
                .background(
                    RoundedRectangle(cornerRadius: Radius.chip)
                        .fill(hovering ? AppColors.subtleFill : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovering = $0 }
    }
}
