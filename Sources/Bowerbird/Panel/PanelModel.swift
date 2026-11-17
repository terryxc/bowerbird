import AppKit
import BowerbirdCore
import Combine
import Foundation
import SwiftUI

@MainActor
final class PanelModel: ObservableObject {
    /// When the list's contents change, the format bar has to be recomputed. The selected row may now
    /// be a different item, or the same item may simply have gained some text (the "Text in Image"
    /// cell only appears once OCR has produced a result).
    ///
    /// This used to rely on `reload` remembering to call it by hand at the end. That was correct while
    /// there was a single call site, but "the format bar matches the selected item" is an invariant of
    /// this type and shouldn't depend on callers remembering.
    @Published var items: [ClipItem] = [] { didSet { refreshVariants() } }
    @Published var selectedIndex = 0 { didSet { if selectedIndex != oldValue { refreshVariants() } } }
    /// Don't re-search when the value is unchanged: SwiftUI's TextField writes the original value back
    /// once when it mounts, and if that also triggered a reload, refreshFormats would wipe out the
    /// format just chosen on the format bar
    @Published var query = "" { didSet { if query != oldValue { scheduleSearch() } } }
    /// Show only one kind of clip. nil is every kind. A temporary choice like the query: it is
    /// cleared when the panel opens.
    @Published var kindFilter: ClipKind? { didSet { if kindFilter != oldValue { scheduleSearch() } } }
    /// The choices of the kind menu in the search row, in menu order
    static let kindFilterChoices: [ClipKind?] = [nil, .text, .image, .file]

    /// The name of a kind as the menu shows it
    static func kindFilterLabel(_ kind: ClipKind?) -> String {
        switch kind {
        case nil: L("All")
        case .text: L("Text")
        case .image: L("Images")
        case .file: L("Files")
        }
    }

    /// What the kind menu's button says
    var kindFilterLabel: String {
        switch kindFilter {
        case nil: L("All")
        case .text: L("Text")
        case .image: L("Images")
        case .file: L("Files")
        }
    }

    /// The ways the selected item can be taken. A single cell means there's no choice, so the whole
    /// format bar is hidden.
    @Published private(set) var variants: [ClipVariant] = [.asCaptured]
    /// Which cell is currently selected
    @Published var variant: ClipVariant = .asCaptured
    /// What the "Paste" hint at the bottom should say. On the first cell it just says "Paste".
    var pasteHintLabel: String {
        Self.pasteTitle(for: variant)
    }

    /// "Paste", "Paste Path", "Paste Text in Image": each a whole phrase in the strings table.
    /// They used to be put together from "Paste %@" and the format's name, which only reads right
    /// in English: French got "Coller Texte de l’image", Russian "Вставить Текст с изображения".
    static func pasteTitle(for variant: ClipVariant) -> String {
        switch variant {
        case .asCaptured: L("Paste")
        case .plainText: L("Paste as Plain Text")
        case .path: L("Paste Path")
        case .recognizedText: L("Paste Text in Image")
        }
    }

    /// The name of this cell on the format bar.
    ///
    /// The first cell used to always be called "As Captured", but it stood for three different things:
    /// text in its original format, the file itself, and the image itself. Naming it by kind is clearer.
    /// Formatted / Plain Text, File / Path, Image / Text in Image: two cells side by side tell you
    /// "what you'll get if you switch".
    func label(for variant: ClipVariant) -> String {
        switch variant {
        case .asCaptured:
            switch selected?.kind {
            case .file: return L("File")
            case .image: return L("Image")
            default: return L("Formatted")
            }
        case .plainText: return L("Plain Text")
        case .path: return L("Path")
        case .recognizedText: return L("Text in Image")
        }
    }

    /// Which search results are fuzzy matches; the list gives them a group of their own
    @Published private(set) var fuzzyIDs: Set<Int64> = []

    /// Which representations the selected item has stored. Only type and size, never the content:
    /// holding ↓ over a run of images can't afford to read several MB from disk on every row change.
    private var selectedAssets: [ClipAssetSummary] = []
    /// Whether the first batch has arrived. Until then the list is also empty, but that isn't
    /// "no history". The empty state has to wait for this to be true, otherwise every open briefly
    /// flashes "No history yet".
    @Published private(set) var loaded = false
    /// Incremented every time the panel opens; SwiftUI uses it to put focus back in the search field
    @Published var focusToken = 0
    /// Which app was frontmost when the panel was summoned. Pasting waits for it to regain focus.
    var pasteTarget: NSRunningApplication?

    let store: HistoryStore
    /// (item, copy without pasting, which cell)
    var onActivate: ((ClipItem, Bool, ClipVariant) -> Void)?
    /// Hides the panel. Called after an item is used, or when the panel is no longer needed.
    var onDismiss: (() -> Void)?
    /// Permission just arrived: finish the paste that couldn't go through earlier. The argument is the
    /// app to paste into.
    ///
    /// Like onActivate and onDismiss, this is one of the panel's outward edges: the panel decides
    /// "whether to resume, and into which app"; how ⌘V actually gets sent is Paster's business, and the
    /// model shouldn't know about it.
    var onResumePaste: ((NSRunningApplication) -> Void)?
    /// The gear at the bottom: hides the panel and opens Settings
    var onOpenSettings: (() -> Void)?

    private let permission: any AccessibilityState
    /// The pasteboard's current generation. Used to detect "the user copied something else after the
    /// pending paste was set up".
    private let changeCount: () -> Int

    private var searchWork: DispatchWorkItem?
    private var cancellables = Set<AnyCancellable>()

    /// Whether there is more to fetch. If the previous batch came back short, we've hit the end.
    private var hasMore = true
    /// A next batch is being fetched; avoids triggering it repeatedly while scrolling
    private var isLoadingMore = false
    /// Bumped by every reload. A fetch that comes back after a newer reload started belongs to a list
    /// that no longer exists and is thrown away.
    ///
    /// Fetches run on a concurrent queue, so results can land out of order. Checking only
    /// `items.count == offset` wasn't enough: a reload's first page usually has exactly `pageSize`
    /// rows, the same as the old offset, so a batch fetched before a delete was appended after it and
    /// repeated a row, and duplicate ids in ForEach are undefined behaviour. An older reload could
    /// likewise land after a newer one and put back a stale list.
    private var listGeneration = 0

    /// How many items each fetch brings in. Not a performance need: on a 5000-item store, fetching
    /// 200 takes 3.2 ms and fetching all 5.1 ms. `content` holds every clip's full text, so there is
    /// no point reading thousands of long texts at once; batches keep it bounded. It must be clearly
    /// more than one screen of rows (a dozen or so), or "scrolled to the bottom" is true the moment
    /// the panel opens and loading fires over and over. Used to be a setting (50 to 500); nobody
    /// needs to tune it.
    private let pageSize = 100
    /// Hard cap on the total number of items loaded, so scrolling can never eat unbounded memory.
    /// Raycast stops loading regardless of hasMore when memory is tight, for the same reason.
    private static let maximumLoaded = 5_000

    /// Permission state and "has the pasteboard changed" are injected, defaulting to the real thing.
    /// Tests need to be in control: asking the system for real would make every test's result depend
    /// on whether this machine granted permission, and request() pops up the system dialog on the spot.
    init(store: HistoryStore,
         permission: any AccessibilityState = AccessibilityPermission.shared,
         changeCount: @escaping () -> Int = { NSPasteboard.general.changeCount }) {
        self.store = store
        self.permission = permission
        self.changeCount = changeCount
        // Permission is granted in System Settings, and by the time it is we're most likely no longer
        // frontmost. Watch for that moment and finish the paste that failed when the user pressed
        // Return. That's exactly what they wanted; making them come back and press it again would be
        // us cutting corners.
        permission.isTrustedChanged
            .dropFirst()
            .sink { [weak self] trusted in
                guard trusted else { return }
                self?.accessibilityGranted()
            }
            .store(in: &cancellables)
    }

    var selected: ClipItem? {
        items.indices.contains(selectedIndex) ? items[selectedIndex] : nil
    }

    /// The format bar only takes up those 32 points when there's actually something to choose.
    /// An image being recognized is the one exception: it has only one cell right now but is about to
    /// get a second, so the bar is reserved up front with a greyed-out placeholder. See isRecognizing.
    var showsFormatBar: Bool { variants.count > 1 || isRecognizing }

    /// The selected image is still having its text recognized.
    ///
    /// If you copy a screenshot and open the panel immediately, the "Text in Image" cell pops up on
    /// its own a few seconds later, with no explanation in between. You don't know what the app is
    /// doing during those seconds, or whether to wait. With this state the format bar can show a
    /// non-clickable "Recognizing…" first.
    ///
    /// The criterion is the OCR queue's own (see OCRQueue.enqueue): recognition is on, it's an image,
    /// and there's no result yet. `ocrText` being nil means "not recognized yet"; an empty string means
    /// "recognized, and the image has no text", which should no longer show as recognizing.
    var isRecognizing: Bool {
        guard AppSettings.shared.recognizeText,
              let item = selected, item.kind == .image else { return false }
        return item.ocrText == nil
    }

    /// Total bytes that will be pasted for the current cell. Uses the same rules as what actually gets
    /// written (ClipVariant) instead of computing it separately. Previously three places each
    /// special-cased files and images, and changing one left the other two stale.
    var selectedFormatBytes: Int {
        selected?.byteCount(for: variant, summaries: selectedAssets) ?? 0
    }

    /// Changing items goes back to the first cell. It's a temporary choice tied to the item, not a
    /// global switch.
    ///
    /// Only reset when the selected **item** changes. It used to reset on every reload, so when an
    /// image got its OCR result and the list refreshed, the "Plain Text" you'd just picked bounced back
    /// to "Formatted", and Return pasted the formatted version.
    private func refreshVariants() {
        guard !holdsVariantRefresh else { return }
        guard let item = selected, let id = item.id else {
            variants = [.asCaptured]
            variant = .asCaptured
            selectedAssets = []
            variantsItemID = nil
            return
        }
        // Files and images have known cells without hitting the database; only text needs to check
        // which representations it stored
        selectedAssets = item.kind == .text ? ((try? store.assetSummaries(for: id)) ?? []) : []
        variants = item.variants(assets: selectedAssets)
        if variantsItemID != id || !variants.contains(variant) {
            variant = .asCaptured
            variantsItemID = id
        }
    }

    /// Which item was selected the last time the format bar was computed
    private var variantsItemID: Int64?
    /// Set while a reload swaps the list and then the selection. Between the two steps the old
    /// index points at some other row; computing the format bar there took that row for the
    /// selection, and pinning an item (which moves it) reset the format just chosen for it.
    private var holdsVariantRefresh = false

    /// ⇥ moves to the next cell, ⇧⇥ to the previous one, wrapping at the ends
    func cycleFormat(_ delta: Int) {
        guard showsFormatBar else { return }
        let current = variants.firstIndex(of: variant) ?? 0
        variant = variants[((current + delta) % variants.count + variants.count) % variants.count]
    }

    /// ⌥1…⌥6 jump straight to a cell
    func selectFormat(at position: Int) {
        guard showsFormatBar, variants.indices.contains(position - 1) else { return }
        variant = variants[position - 1]
    }

    func reset() {
        // The user may have granted permission while the panel was closed (ticked the box in System
        // Settings and never came back). Opening the panel is the most frequent action, so this is the
        // cheapest moment to check.
        //
        // The reverse, "permission revoked", can't be detected; that's on the system. See the measured
        // notes in AccessibilityPermission.
        permission.refresh()
        showsPermissionCard = false
        // File icons are cached by path; re-resolve them on every open so a changed icon is picked up
        AppIconCache.shared.forgetFileIcons()
        // Order matters: query's didSet schedules a search. Cancelling first and assigning afterwards
        // would schedule it again, causing a spurious refresh about 80 ms after the panel opens, which
        // also bounces the chosen format back to the first cell
        kindFilter = nil
        query = ""
        searchWork?.cancel()
        selectedIndex = 0
        focusToken += 1
        reload()
    }

    /// Re-fetches the first batch.
    ///
    /// When keepSelectionOn is an item id, the selection follows that item to its new position after
    /// the refresh. Pinning moves an item to the top of the list; if the selection didn't follow,
    /// pressing ⌘P again would act on a different item.
    ///
    /// A refresh shrinks the already-loaded batches back to the first one. The list is in reverse
    /// chronological order, so when new content arrives the user is most likely looking at the top;
    /// keeping thousands of rows and inserting into them makes the scroll position jump around.
    ///
    /// selectsFirst is for a changed search: the results are a different list, ranked, and the top
    /// one is the likely target, so the selection goes there (as in Spotlight and Raycast). Every
    /// other refresh keeps the row the user was on: a new copy arriving above should not move them.
    func reload(keepSelectionOn id: Int64? = nil, animated: Bool = false, selectsFirst: Bool = false) {
        let q = query
        let kind = kindFilter
        let store = self.store
        let size = pageSize
        hasMore = true
        isLoadingMore = false
        listGeneration += 1
        let generation = listGeneration
        DispatchQueue.global(qos: .userInitiated).async {
            let page = (try? Self.page(store: store, query: q, kind: kind, limit: size, offset: 0))
                ?? SearchPage(items: [], fuzzyIDs: [])
            let result = page.items
            DispatchQueue.main.async { [weak self] in
                guard let self, self.listGeneration == generation, self.query == q, self.kindFilter == kind else { return }
                // When pinning, the row slides into the "Pinned" group; when deleting, it fades out
                // and the rows below move up. Nothing teleports: the row's id is unchanged, so SwiftUI
                // moves it from the old position to the new one.
                // Searching and paging aren't animated: when the whole batch is swapped out, things
                // flying everywhere is just disorienting.
                // The curve follows iOS lists: a spring with a tiny bit of overshoot at the end, not a
                // linear ease-in-out
                self.holdsVariantRefresh = true
                withAnimation(animated ? .spring(duration: 0.45, bounce: 0.18) : nil) {
                    self.items = result
                }
                self.fuzzyIDs = page.fuzzyIDs
                self.loaded = true
                self.hasMore = result.count == size
                if let id, let index = result.firstIndex(where: { $0.id == id }) {
                    self.selectedIndex = index
                } else if selectsFirst || self.items.isEmpty {
                    self.selectedIndex = 0
                } else if self.selectedIndex >= self.items.count {
                    self.selectedIndex = self.items.count - 1
                }
                self.holdsVariantRefresh = false
                self.refreshVariants()
            }
        }
    }

    /// Called when the list renders a row. Once we reach the last screenful, fetch the next batch.
    ///
    /// The trigger is the third-to-last row rather than the last one: waiting until you've actually
    /// scrolled to the bottom means the user sees a hitch. Fetching slightly early makes paging
    /// seamless.
    func loadMoreIfNeeded(currentIndex index: Int) {
        guard hasMore, !isLoadingMore else { return }
        guard index >= items.count - 3 else { return }
        guard items.count < Self.maximumLoaded else {
            hasMore = false
            return
        }
        isLoadingMore = true

        let q = query
        let kind = kindFilter
        let store = self.store
        let size = pageSize
        let offset = items.count
        let generation = listGeneration
        DispatchQueue.global(qos: .userInitiated).async {
            let page = (try? Self.page(store: store, query: q, kind: kind, limit: size, offset: offset))
                ?? SearchPage(items: [], fuzzyIDs: [])
            let next = page.items
            DispatchQueue.main.async { [weak self] in
                // A reload started while fetching: this batch continues a list that's gone. The reload
                // already cleared isLoadingMore, so leave it alone.
                guard let self, self.listGeneration == generation else { return }
                self.isLoadingMore = false
                guard self.query == q, self.kindFilter == kind, self.items.count == offset else { return }
                self.items += next
                self.fuzzyIDs.formUnion(page.fuzzyIDs)
                self.hasMore = next.count == size
            }
        }
    }

    /// Only queries the database and touches nothing on the main thread; it's called on a background
    /// queue in the first place
    private nonisolated static func page(store: HistoryStore, query: String, kind: ClipKind?,
                             limit: Int, offset: Int) throws -> SearchPage {
        query.isEmpty
            ? SearchPage(items: try store.fetchRecent(limit: limit, offset: offset, kind: kind), fuzzyIDs: [])
            : try store.searchPage(query, limit: limit, offset: offset, kind: kind)
    }

    func moveSelection(_ delta: Int) {
        guard !items.isEmpty else { return }
        selectedIndex = min(max(selectedIndex + delta, 0), items.count - 1)
        // Holding the keyboard down should page too, not just mouse scrolling
        loadMoreIfNeeded(currentIndex: selectedIndex)
    }

    /// Home and End, or ⌘↑ and ⌘↓. "Last" is the last loaded row; the next batch loads from there.
    func moveSelectionToEnd(_ end: ListEnd) {
        guard !items.isEmpty else { return }
        selectedIndex = end == .first ? 0 : items.count - 1
        loadMoreIfNeeded(currentIndex: selectedIndex)
    }

    enum ListEnd { case first, last }

    /// Page Up and Page Down move by as many rows as the list shows at once
    func moveSelection(pages: Int) {
        moveSelection(pages * max(1, AppSettings.shared.panelSize.visibleRows))
    }

    func revealInFinder(id: Int64?) {
        guard let path = item(with: id)?.filePaths.first else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    /// All panel actions go through here: keyboard, bottom hints and double-click alike
    func perform(_ action: PanelAction) {
        // While the card is showing, Return presses its primary button. It's the only thing on screen
        // still waiting for an answer; pressing Return to trigger "can't paste" again is pointless.
        if showsPermissionCard, action == .paste {
            grantAccessibility()
            return
        }
        switch action {
        // "Using an item" has exactly one entry point, activate(id:), and the keyboard is no exception.
        // The keyboard used to go through a separate activateSelected that called onActivate itself.
        // Two entry points doing the same thing meant the missing-permission handling was added to
        // only one of them: clicking opened the explanation card, pressing Return did nothing visible.
        // The panel stayed open, the content was on the pasteboard, and nobody said why.
        case .paste: activate(id: selectedID, copyOnly: false)
        case .copy: activate(id: selectedID, copyOnly: true)
        case .pastePlainText: activate(id: selectedID, copyOnly: false, variant: selected?.textVariant)
        case .cycleFormat: cycleFormat(1)
        case .togglePin: togglePinSelected()
        case .delete: deleteSelected()
        }
    }

    func isFuzzy(_ item: ClipItem) -> Bool {
        item.id.map(fuzzyIDs.contains) ?? false
    }

    /// Activates a row by id, for ⌘1–9 and mouse clicks.
    ///
    /// The format follows the selected item. If the clicked row is a different one, use "As Captured":
    /// pasting one row with another row's format choice is wrong.
    /// Row actions always look up the item by id, never by index.
    ///
    /// The context menu runs a nested event loop, and the list keeps refreshing while it's open (new
    /// content arriving, OCR results). With indices, choosing "Delete" in the menu might delete a
    /// different item that has moved up into that position.
    func activate(id: Int64?, copyOnly: Bool, variant override: ClipVariant? = nil) {
        guard let item = item(with: id) else { return }
        // The format bar follows the selected item; other rows use the first cell
        let chosen = override ?? (item.id == selected?.id ? variant : .asCaptured)
        // We want to paste but can't: copy the content to the pasteboard first (that needs no
        // permission, and the user pressed Return for exactly this content, so they shouldn't leave
        // empty-handed). Keep the panel open and let the card explain.
        guard copyOnly || permission.isTrusted else {
            onActivate?(item, true, chosen)
            askForAccessibility()
            return
        }
        onDismiss?()
        onActivate?(item, copyOnly, chosen)
    }

    /// Selects this item (when a row is clicked or right-clicked)
    func select(id: Int64?) {
        guard let id, let index = items.firstIndex(where: { $0.id == id }) else { return }
        selectedIndex = index
    }

    /// The id of the selected item. Rows use it to decide whether they're selected, instead of
    /// comparing indices.
    var selectedID: Int64? { selected?.id }

    /// "Paste as Plain Text": files paste their path, images paste their recognized text, text pastes
    /// as plain text
    func pastePlainText(id: Int64?) {
        guard let item = item(with: id) else { return }
        activate(id: id, copyOnly: false, variant: item.textVariant)
    }

    /// ⌘1…⌘9 mean "the Nth row", i.e. whatever is on that row on screen at that moment, so looking it
    /// up by position is unambiguous.
    func activate(at index: Int, copyOnly: Bool) {
        guard items.indices.contains(index) else { return }
        activate(id: items[index].id, copyOnly: copyOnly)
    }

    func item(with id: Int64?) -> ClipItem? {
        guard let id else { return nil }
        return items.first { $0.id == id }
    }

    func deleteSelected() {
        delete(id: selected?.id)
    }

    /// Deletes by id, for mouse clicks. The keyboard path goes through here too.
    func delete(id: Int64?) {
        guard let id, item(with: id) != nil else { return }
        // Deleting an item is more than deleting a row: afterwards orphaned files get swept (two
        // full-table queries plus two directory scans), measured at 3.6 to 4.8 ms on a library of 3,500
        // items and 500 image files. On the main thread, holding ⌘⌫ to delete repeatedly means a
        // stutter each time.
        //
        // Moving it to the background doesn't make "the row disappears" any slower: reload is already
        // asynchronous, and the row never disappeared at this exact moment anyway.
        let store = self.store
        Task { [weak self] in
            do {
                try await Task.detached(priority: .userInitiated) { try store.delete(id: id) }.value
            } catch {
                HistoryCleanupAlert.present()
            }
            self?.reload(animated: true)
            NotificationCenter.default.post(name: .bowerbirdStoreChanged, object: nil)
        }
    }

    func togglePinSelected() {
        togglePin(id: selected?.id)
    }

    /// Pins or unpins by id, for mouse clicks.
    func togglePin(id: Int64?) {
        guard let id, let item = item(with: id) else { return }
        try? store.setPinned(id: id, !item.pinned)
        reload(keepSelectionOn: id, animated: true)
    }

    // MARK: Accessibility permission

    /// Whether the explanation card under the search field is showing
    @Published private(set) var showsPermissionCard = false

    /// The paste to send once permission arrives.
    ///
    /// Records only the changeCount at the moment Return was pressed and a deadline, not the item. The
    /// content was already written to the pasteboard when Return was pressed (copying needs no
    /// permission); resuming only needs one ⌘V. If the user copies something else in the meantime, the
    /// changeCount no longer matches and this resume is dropped: they want what they just copied, not
    /// the old thing we're holding on to.
    struct PendingPaste {
        let changeCount: Int
        let expires: Date

        /// Whether this still counts now that permission has arrived.
        ///
        /// Two gates. Expired doesn't count: the user has most likely walked away, and suddenly pasting
        /// something into some window half an hour later is alarming. A changed pasteboard doesn't
        /// count either: they want what they just copied, not the old thing we're holding on to.
        func stillWanted(now: Date, changeCount current: Int) -> Bool {
            now < expires && current == changeCount
        }
    }

    private var pendingPaste: PendingPaste?

    /// The upper bound on how long the user may dawdle in System Settings. Past it, nothing is
    /// resumed: they've most likely walked away, and suddenly pasting something into some window half
    /// an hour later is alarming.
    ///
    /// Five minutes is measured: knowing exactly where to click, it took me 42 seconds from clicking
    /// "Turn On…" to ticking the switch. A first-timer has to find Bowerbird in a long list of apps and
    /// then get through Touch ID; several times that is normal. The card's title says in plain words
    /// "it will paste once you grant access"; too short a limit means we break our own promise.
    /// What actually prevents a wrong paste is whether the pasteboard changed, not this number.
    ///
    /// Same number as AccessibilityPermission.watchLimit; change them together.
    private static let pendingPasteWindow: TimeInterval = 300

    /// Return was pressed to paste but there's no permission: the content is already copied, so open
    /// the card to explain, and record this paste to resume once permission arrives.
    private func askForAccessibility() {
        pendingPaste = PendingPaste(changeCount: changeCount(),
                                    expires: Date().addingTimeInterval(Self.pendingPasteWindow))
        // The card pushes out from under the search field and the list moves down. The curve matches
        // the list's animations.
        withAnimation(.spring(duration: 0.34, bounce: 0.14)) { showsPermissionCard = true }
    }

    /// The card's primary button: hide the panel first, then request permission.
    ///
    /// The panel's job is done at this point: everything else happens on the system side, and when
    /// permission arrives accessibilityGranted pastes the pending item. The panel doesn't need to be
    /// standing around. (It also used to sit at window level 1000, which put the system's "would like
    /// to control this computer" dialog underneath it with its buttons out of reach; the level is
    /// ordinary now, but hiding first is still the right order.)
    func grantAccessibility() {
        onDismiss?()
        permission.request()
    }

    /// "Not Now". The content is already on the pasteboard and the panel has done its job, so hide it.
    func dismissPermissionCard() {
        pendingPaste = nil
        showsPermissionCard = false
        onDismiss?()
    }

    /// Permission arrived. Finish the paste that couldn't go through earlier; that's what the user is
    /// waiting for.
    private func accessibilityGranted() {
        showsPermissionCard = false
        guard let pending = pendingPaste else { return }
        pendingPaste = nil
        guard pending.stillWanted(now: Date(), changeCount: changeCount()),
              let target = pasteTarget, !target.isTerminated else { return }
        // The panel was most likely hidden long ago; hiding it again guarantees ⌘V doesn't land in our
        // own window
        onDismiss?()
        onResumePaste?(target)
    }

    private func scheduleSearch() {
        searchWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.reload(selectsFirst: true) }
        searchWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
    }
}
