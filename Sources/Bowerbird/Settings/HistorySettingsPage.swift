import BowerbirdCore
import SwiftUI

/// History page: what gets recorded, how long it's kept, how to clear it. List ordering belongs to the panel, not here.
struct HistorySettingsPage: View {
    let store: HistoryStore
    @ObservedObject private var settings = AppSettings.shared
    @State private var stats = StoreStats(count: 0, imageCount: 0, diskBytes: 0)
    @State private var isClearing = false
    /// The last recognition on/off change still in flight; the next one waits for it
    @State private var recognitionChange: Task<Void, Never>?

    var body: some View {
        // No captions on this page: three cards, each obvious from its first row (what is kept, how it
        // is read, how it is cleared). Captions over some cards and not others broke the rhythm.
        SettingsCard {
            // "Record or not" and "keep how long" are two halves of one question: not recording is
            // keeping for zero days. One pop-up holds both, first item "Don't record", the rest
            // retention days. It looks like the other pick-one controls on this page, with no need
            // for a separate toggle plus stepper.
            kindRow(title: "Text", enabled: $settings.captureText, days: $settings.textDays)
            SettingsDivider()
            kindRow(title: "Images", enabled: $settings.captureImages, days: $settings.imageDays)
            SettingsDivider()
            kindRow(title: "Files", subtitle: "Only the path is stored, so this costs nothing",
                    enabled: $settings.captureFiles, days: $settings.fileDays)
        }

        SettingsCard {
            SettingsRow(title: "Recognize Text in Images") {
                SettingsToggle(isOn: Binding(
                    get: { settings.recognizeText },
                    set: { on in
                        settings.recognizeText = on
                        // Turning it off drops the recognised text too, otherwise it stays searchable;
                        // turning it back on queues those images for recognition again automatically.
                        //
                        // Each step waits for the previous one. Off then quickly on used to queue the
                        // images while the forgetting was still running: they still had text, so they
                        // were skipped as done, and then the text was cleared, leaving them without any.
                        let previous = recognitionChange
                        let store = store
                        recognitionChange = Task {
                            await previous?.value
                            if on {
                                NotificationCenter.default.post(name: .bowerbirdRecognizeTextEnabled, object: nil)
                            } else {
                                // Rewrites search_text for every image with recognised text; with many
                                // images that's not main-thread work
                                await Task.detached(priority: .userInitiated) {
                                    try? store.forgetRecognizedText()
                                }.value
                                NotificationCenter.default.post(name: .bowerbirdHistoryCleared, object: nil)
                            }
                        }
                    }
                ))
            }
            SettingsDivider()
            // The screenshots folder is not watched. Screenshots saved as files never touch the
            // clipboard; collecting them would mean asking for access to the Desktop folder, relying
            // on the Spotlight index, and waiting for the floating thumbnail to go away before the file
            // is written, and even then it's flaky (Clipy's version of this broke several times). To
            // get screenshots into history, press ⌃⇧⌘4, or set the save location to "Clipboard" under
            // "Options" in ⇧⌘5. That's the same advice Alfred and Maccy give.
            //
            // Files are never collected: what comes over Universal Clipboard is only a temporary
            // address that expires after a few minutes
            SettingsRow(title: "Save From Other Devices") {
                SettingsToggle(isOn: $settings.captureFromOtherDevices)
            }
        }

        SettingsCard {
            // "How much space" and "clear it" are two sides of the same thing, so they share a row:
            // the subtitle says how much there is and how big, the button on the right clears it.
            // Nothing in this menu touches pinned items; they have their own row below. One rule, no
            // per-item caveats: a bulk action on the history never takes a pinned item with it.
            SettingsRow(title: "Clear History", subtitleText: storageSummary) {
                Menu {
                    ForEach(ClearWindow.allCases) { window in
                        Button(LocalizedStringKey(window.titleKey)) { pendingClear = .recent(window) }
                    }
                    Divider()
                    Button("Everything", role: .destructive) { pendingClear = .history }
                } label: {
                    Text("Clear…").frame(maxWidth: .infinity)
                }
                .modifier(SettingsButtonStyle())
                .frame(width: Self.clearControlWidth)
                .disabled(isClearing)
            }
            SettingsDivider()
            // A plain button: there is only one thing to do, so no menu. Both controls are given the
            // same outer width, with labels that fill it, so they line up exactly.
            SettingsRow(title: "Clear Pinned Items", subtitleText: pinnedSummary) {
                Button { pendingClear = .pinned } label: {
                    Text("Clear…").frame(maxWidth: .infinity)
                }
                .modifier(SettingsButtonStyle())
                .frame(width: Self.clearControlWidth)
                .disabled(isClearing || (stats.pinnedCount == 0 && !clearNeedsRetry))
            }
            SettingsDivider()
            SettingsRow(title: "Clear on Quit", subtitle: "Nothing is left behind after you quit") {
                SettingsToggle(isOn: $settings.clearOnQuit)
            }
        }
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: .bowerbirdStoreChanged)) { _ in refresh() }
        .confirmationDialog(pendingClear?.question ?? "", isPresented: confirmBinding, titleVisibility: .visible,
                            presenting: pendingClear) { scope in
            Button(scope.confirmTitle, role: .destructive) { perform(scope) }
            Button("Cancel", role: .cancel) {}
        } message: { scope in
            Text(scope.note)
        }
    }

    /// The two Clear controls share this outer width
    private static let clearControlWidth: CGFloat = 72

    /// Retention steps. Alfred uses 24 hours / 7 days / 1 month / 3 months, which is enough;
    /// seven steps can't be taken in at a glance, four are actual choices. A value the user set
    /// earlier that isn't a step gets added in.
    private static let retentionLadder = [1, 7, 30, 90]

    /// One row per kind, modelled on Alfred: checkbox first, so "☑ Text ... Keep 30 days" reads as a
    /// sentence from left to right. Unchecking fades the whole row, pop-up included.
    /// A version with the checkbox at the end next to the pop-up was tried; the two controls crowded
    /// together like a pair of unrelated parts.
    private func kindRow(title: LocalizedStringKey, subtitle: LocalizedStringKey? = nil,
                         enabled: Binding<Bool>, days: Binding<Int>) -> some View {
        var ladder = Self.retentionLadder
        if !ladder.contains(days.wrappedValue) {
            ladder.append(days.wrappedValue)
            ladder.sort()
        }
        return SettingsRow(title: title, subtitle: subtitle, leading: {
            Toggle("", isOn: enabled)
                .labelsHidden()
                .toggleStyle(.checkbox)
                .tint(AppColors.accentFill)
        }) {
            SettingsPopUp(selection: days, options: ladder.map {
                .init(value: $0, title: L("Keep %lld days", $0))
            })
            .modifier(SettingsPopUpStyle())
            .disabled(!enabled.wrappedValue)
            .opacity(enabled.wrappedValue ? 1 : 0.5)
        }
    }

    /// The clear action waiting for confirmation
    private enum ClearScope: Identifiable {
        case recent(ClearWindow)
        /// The whole history, pinned items excepted
        case history
        /// The pinned items and nothing else
        case pinned

        var id: String {
            switch self {
            case .recent(let window): "recent-\(window.rawValue)"
            case .history: "history"
            case .pinned: "pinned"
            }
        }

        var question: LocalizedStringKey {
            switch self {
            case .recent(let window): LocalizedStringKey(window.questionKey)
            case .history: "Clear all clipboard history?"
            case .pinned: "Clear all pinned items?"
            }
        }

        var note: LocalizedStringKey {
            switch self {
            case .recent, .history: "Pinned items are kept. This cannot be undone."
            case .pinned: "This cannot be undone."
            }
        }

        var confirmTitle: LocalizedStringKey {
            switch self {
            case .recent: "Clear Recent"
            case .history: "Clear Everything"
            case .pinned: "Clear Pinned"
            }
        }
    }

    @State private var pendingClear: ClearScope?
    @State private var clearNeedsRetry = false

    private var confirmBinding: Binding<Bool> {
        Binding(get: { pendingClear != nil }, set: { if !$0 { pendingClear = nil } })
    }

    /// Clearing is followed by a VACUUM, which rewrites the whole database and grows linearly with
    /// its size: measured 37 ms for a 16 MB database, several seconds for a few hundred MB. So it
    /// runs off the main thread; the counts below keep their old values until it's done, then update.
    private func perform(_ scope: ClearScope) {
        guard !isClearing else { return }
        isClearing = true
        let store = self.store
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    switch scope {
                    case .recent(let window): _ = try store.clearRecent(within: window.interval)
                    case .history: _ = try store.clearHistory()
                    case .pinned: _ = try store.clearPinned()
                    }
                }.value
                clearNeedsRetry = false
                NotificationCenter.default.post(name: .bowerbirdHistoryCleared, object: nil)
            } catch {
                clearNeedsRetry = true
                // Rows may already have gone while an attachment could not be removed.
                NotificationCenter.default.post(name: .bowerbirdStoreChanged, object: nil)
                HistoryCleanupAlert.present()
            }
            isClearing = false
            refresh()
        }
    }

    private var pinnedSummary: String {
        stats.pinnedCount > 0 ? L("Pinned: %lld", stats.pinnedCount) : L("No pinned items")
    }

    /// Always the current counts; after a clear they simply update. When empty, say so plainly rather
    /// than reporting the 40 KB an empty database takes.
    private var storageSummary: String {
        guard stats.count > 0 else { return L("No items") }
        return "\(L("%lld items, %lld images", stats.count, stats.imageCount)) · \(Format.bytes(stats.diskBytes))"
    }

    /// Counts how much space is used: two COUNTs plus a stat of every file in images/ and assets/.
    /// Measured 24 ms for 3,500 items and 500 image files, growing linearly with the file count;
    /// on the main thread that's a visible hitch when switching to this page. So it runs in the
    /// background and fills in when done; nobody minds this line appearing a few dozen ms later.
    private func refresh() {
        let store = self.store
        Task.detached(priority: .utility) {
            guard let fresh = try? store.stats() else { return }
            await MainActor.run { stats = fresh }
        }
    }
}

extension Notification.Name {
    static let bowerbirdHistoryCleared = Notification.Name("bowerbirdHistoryCleared")
    /// Expiry removed something in the background; whoever shows counts should count again
    static let bowerbirdStoreChanged = Notification.Name("bowerbirdStoreChanged")
    /// Text recognition turned back on: images not yet recognised need to be queued again
    static let bowerbirdRecognizeTextEnabled = Notification.Name("bowerbirdRecognizeTextEnabled")
}
