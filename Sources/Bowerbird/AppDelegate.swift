import AppKit
import BowerbirdCore
import Combine
import KeyboardShortcuts

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var store: HistoryStore!
    private var watcher: ClipboardWatcher!
    private var panelModel: PanelModel!
    private var panel: PanelController!
    private var ocrQueue: OCRQueue!
    private var retention: RetentionScheduler!
    private var settingsWindow: SettingsWindowController!
    private var cancellables = Set<AnyCancellable>()
    /// How long a changed "keep for" waits before it deletes anything
    private static let retentionGrace: TimeInterval = 8
    private var statusBar: StatusBarController!
    private var isClearingOnQuit = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // The menu bar is normally hidden, but ⌘C / ⌘V / ⌘A rely on the main menu for dispatch; the full
        // set shows only while the settings window is open. See MainMenu.
        MainMenu.start()
        AppSettings.shared.appearance.apply()
        // User-visible text in Core also uses the language the app has chosen.
        // This closure is called in the background (computing titles for file clips while recording),
        // so it must not touch the main-thread settings object. It used to use MainActor.assumeIsolated
        // to pretend it was on the main thread, which became a crash once capture moved to the
        // background. The language rarely changes; when it does, refresh this snapshot.
        LocalizationSnapshot.update(bundle: AppSettings.shared.localizationBundle,
                                    locale: AppSettings.shared.language.locale)
        CoreLocalization.provider = { key, arguments in
            LocalizationSnapshot.string(key, arguments)
        }
        do {
            store = try HistoryStore.standard()
        } catch {
            NSLog("open store failed: \(error)")
            // Rebuilding replaces the user's whole history with an empty database, so first work out
            // why it failed to open. This used to rebuild on any error, and the SQLITE_BUSY thrown when
            // "another instance holds the lock" looks exactly like "file corrupted" in the catch. With
            // two copies of Bowerbird running, the second one could wipe the history on launch.
            let failure = StoreOpenFailure.classify(error)
            guard failure.justifiesRebuild else {
                let alert = NSAlert()
                alert.messageText = L("Clipboard history database could not be opened")
                // Only a lock points at another copy. Anything else (full disk, permissions) used to
                // get the same "another copy may be running" advice, which sends people looking for a
                // process that doesn't exist.
                alert.informativeText = failure == .busy
                    ? L("Another copy of Bowerbird may be running. Quit it and open Bowerbird again.")
                    : L("Check that the disk has free space and that the Bowerbird folder in Application Support can be written to, then open Bowerbird again.")
                alert.runModal()
                NSApp.terminate(nil)
                return
            }
            // The database really is broken: rename the old one to keep it, create an empty one; if
            // that fails too, quit. If we can't even get the data directory there is nothing to rebuild,
            // so quit. This used to be try!, which crashed on launch when the directory wasn't writable
            // (disk full, permissions changed)
            guard let base = try? FileManager.default.url(for: .applicationSupportDirectory,
                                                          in: .userDomainMask,
                                                          appropriateFor: nil, create: true)
                .appendingPathComponent("Bowerbird", isDirectory: true) else {
                NSApp.terminate(nil)
                return
            }
            // The database runs in WAL mode, so its -wal and -shm files move with it. Left behind, the
            // new empty database would open next to the old log and SQLite could replay those frames
            // into it; the kept copy would also lose whatever was committed but not yet checkpointed.
            for suffix in ["", "-wal", "-shm"] {
                let file = base.appendingPathComponent("history.sqlite" + suffix)
                let kept = base.appendingPathComponent("history.sqlite.broken" + suffix)
                try? FileManager.default.removeItem(at: kept)
                try? FileManager.default.moveItem(at: file, to: kept)
            }
            do {
                store = try HistoryStore.standard()
                let alert = NSAlert()
                alert.messageText = L("Clipboard history database was rebuilt")
                alert.informativeText = L("The old database could not be opened and was renamed to history.sqlite.broken.")
                alert.runModal()
            } catch {
                NSLog("recreate store failed: \(error)")
                NSApp.terminate(nil)
                return
            }
        }
        ocrQueue = OCRQueue(store: store, isEnabled: { AppSettings.shared.recognizeText })
        settingsWindow = SettingsWindowController(store: store)
        // The background callback should only capture store: it is Sendable and built for cross-thread
        // use. Capturing all of self makes it far too easy to touch ocrQueue, panel or panelModel on a
        // background thread after recording, and those all belong to the main thread.
        let store = self.store!
        watcher = ClipboardWatcher(
            ignoredBundleIDs: { Set(AppSettings.shared.ignoredBundleIDs) },
            isPaused: { AppSettings.shared.paused },
            policy: {
                let settings = AppSettings.shared
                var kinds: Set<ClipKind> = []
                if settings.captureText { kinds.insert(.text) }
                if settings.captureImages { kinds.insert(.image) }
                if settings.captureFiles { kinds.insert(.file) }
                return CapturePolicy(kinds: kinds,
                                     acceptsRemote: settings.captureFromOtherDevices,
                                     ignorePatterns: settings.ignorePatterns)
            },
            // Called back on a background queue: recording (hashing, writing image files, writing the DB)
            // shouldn't hold the main thread either
            onCapture: { [weak self] capture, bundle in
                do {
                    let item = try store.record(capture, sourceBundleID: bundle)
                    NSLog("recorded \(item.kind.rawValue)")
                    Task { @MainActor in self?.recorded(item) }
                } catch {
                    NSLog("record failed: \(error)")
                }
            }
        )
        watcher.start()
        panelModel = PanelModel(store: store)
        // Hiding the panel and "using up a clip" are two different things: without Accessibility
        // permission, Return first copies the content and keeps the panel open to explain; that
        // step only does the latter.
        panelModel.onDismiss = { [weak self] in self?.panel.hide() }
        panelModel.onResumePaste = { Paster.sendPaste(activating: $0) }
        panelModel.onActivate = { [weak self] item, copyOnly, variant in
            guard let self else { return }
            // Send ⌘V only once focus is back in the target app: the panel is no longer the key
            // window, and the app that was frontmost when the panel was summoned is frontmost again.
            // Both readings are checked: isActive is the cached flag, frontmostApplication is asked
            // fresh, and the keystroke goes wherever focus is at the moment it lands.
            let target = self.panelModel.pasteTarget
            Paster.paste(item, store: self.store, watcher: self.watcher,
                         copyOnly: copyOnly, variant: variant,
                         readyToPaste: { [weak self] in
                             guard let self else { return true }
                             guard let target else { return !self.panel.panel.isKeyWindow }
                             return !self.panel.panel.isKeyWindow && target.isActive
                                 && NSWorkspace.shared.frontmostApplication == target
                         })
            // Once used, move it to the top. The panel is already hidden, so it opens in the new order next
            // time.
            if AppSettings.shared.moveToTopWhenUsed, let id = item.id {
                try? self.store.touch(id: id)
            }
            // Text recognized in an image doesn't otherwise exist in the history; the next copy washes
            // it away, and getting it back means finding that image and doing it again. So record it
            // explicitly: the clipboard writes we make ourselves are stamped and the watcher skips
            // them all, so we can't rely on it to record this.
            //
            // Record it after the move-to-top: this is "the thing just obtained", so it belongs first.
            // Keep the image's source so the icon in the list matches.
            if variant == .recognizedText, let text = item.ocrText, !text.isEmpty {
                let capture = ClipCapture(assets: [.init(type: .string, data: Data(text.utf8))],
                                          kind: .text, text: text)
                _ = try? self.store.record(capture, sourceBundleID: item.sourceBundleID)
            }
        }
        panelModel.onOpenSettings = { [weak self] in
            guard let self else { return }
            self.panel.hide()
            self.settingsWindow.show()
        }
        panel = PanelController(model: panelModel)
        KeyboardShortcuts.onKeyUp(for: .togglePanel) { [weak self] in self?.panel.toggle() }
        ocrQueue.onUpdated = { [weak self] _ in
            guard let self, self.panel.panel.isVisible else { return }
            self.panelModel.reload()
        }
        ocrQueue.enqueuePending()
        NotificationCenter.default.addObserver(forName: .bowerbirdRecognizeTextEnabled,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.ocrQueue.enqueuePending() }
        }
        retention = RetentionScheduler(
            store: store,
            policy: { AppSettings.shared.retentionPolicy },
            onPurged: { [weak self] removed in
                guard let self, removed > 0 else { return }
                NSLog("purged \(removed) items")
                if self.panel.panel.isVisible { self.panelModel.reload() }
                // The History page shows the counts
                NotificationCenter.default.post(name: .bowerbirdStoreChanged, object: nil)
            }
        )
        retention.start()
        // A shorter "keep for" applies soon, not at the next hourly pass: having chosen "Keep 1 Day",
        // finding last month's clips still in the panel reads as the setting not working.
        //
        // Not at once, though. Expiry can't be undone, and a pop-up is easy to mis-pick: the pass
        // waits a few seconds after the last change, and choosing the old value again within that
        // time leaves everything in place (the pass reads the settings when it runs).
        // objectWillChange fires before the change, hence the hop to the next turn before reading.
        var lastPolicy = AppSettings.shared.retentionPolicy
        var pending: DispatchWorkItem?
        AppSettings.shared.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                let policy = AppSettings.shared.retentionPolicy
                guard policy != lastPolicy else { return }
                lastPolicy = policy
                pending?.cancel()
                let work = DispatchWorkItem { [weak self] in self?.retention.runOnce() }
                pending = work
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.retentionGrace, execute: work)
            }
            .store(in: &cancellables)
        statusBar = StatusBarController(
            onOpenPanel: { [weak self] in self?.panel.show() },
            onOpenSettings: { [weak self] in self?.settingsWindow.show() }
        )
        // Do **not** ask for permission at launch. The user has just installed it and hasn't pressed
        // Return once, and is asked "allow it to control your computer?". At that moment they have no
        // reason to agree, and the system prompt appears only once ever; after a denial the app stays
        // crippled for them for good. Instead we ask the first time they press Return to paste; see
        // PanelModel.askForAccessibility. Here we only show the current state in the menu bar and then
        // follow the permission object.
        AccessibilityPermission.shared.$isTrusted
            .receive(on: DispatchQueue.main)
            .sink { [weak self] trusted in self?.statusBar.setAccessibilityMissing(!trusted) }
            .store(in: &cancellables)
        // When pause or the icon is changed in the settings window, the menu bar must follow at once.
        // The settings object sends this notification for any change; we don't filter by which one.
        // Rebuilding the menu is cheap, while "missing one" is a real bug (the menu bar showing a
        // long-stale state). objectWillChange fires before the change, so read on the next turn to
        // get the new value.
        AppSettings.shared.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.statusBar.refresh() }
            .store(in: &cancellables)
        NotificationCenter.default.addObserver(forName: .bowerbirdHistoryCleared, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.panelModel.reload() }
        }
        NotificationCenter.default.addObserver(forName: .bowerbirdStoreChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.panelModel.reload() }
        }
        // Another Bowerbird was launched: it found us running, quit itself and sent this notification.
        // The user clicked the icon wanting to see the panel, so show it on their behalf.
        DistributedNotificationCenter.default().addObserver(
            forName: SingleInstance.showPanelNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.panel.show() }
        }
    }

    /// A clip was just recorded in the background; continue on the main thread
    private func recorded(_ item: ClipItem) {
        ocrQueue.enqueue(item)
        if panel.panel.isVisible { panelModel.reload() }
    }

    /// Finish queued captures before clearing. On failure keep the app open so the user can fix
    /// the problem and retry; applicationWillTerminate is too late to cancel or report failure.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard AppSettings.shared.clearOnQuit, let store else { return .terminateNow }
        guard !isClearingOnQuit else { return .terminateLater }
        isClearingOnQuit = true
        panel?.hide()
        Task {
            await watcher?.stopAndWait()
            NSPasteboard.general.clearContents()
            do {
                _ = try await Task.detached(priority: .userInitiated) { try store.clearHistory() }.value
                sender.reply(toApplicationShouldTerminate: true)
            } catch {
                isClearingOnQuit = false
                sender.reply(toApplicationShouldTerminate: false)
                watcher?.start()
                NotificationCenter.default.post(name: .bowerbirdStoreChanged, object: nil)
                HistoryCleanupAlert.present()
            }
        }
        return .terminateLater
    }

    // MARK: App menu actions (sent up the responder chain to here)

    @objc func showSettings(_ sender: Any?) { settingsWindow.show() }
    @objc func showAbout(_ sender: Any?) { settingsWindow.show(page: .about) }

}
