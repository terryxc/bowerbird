import AppKit
import BowerbirdCore

/// Main thread only: writing the clipboard and posting key events are main-thread work.
@MainActor
enum Paster {
    /// Called after the panel has closed and the frontmost app has regained focus.
    ///
    /// `variant` says which form of this clip is wanted; `.asCaptured` writes back every stored
    /// representation as-is.
    static func paste(_ item: ClipItem, store: HistoryStore, watcher: ClipboardWatcher,
                      copyOnly: Bool, variant: ClipVariant = .asCaptured,
                      readyToPaste: @escaping () -> Bool = { true }) {
        write(item, store: store, watcher: watcher, variant: variant)
        guard !copyOnly, AccessibilityPermission.shared.isTrusted else { return }
        // If it's still not ready after 0.4 s, send it anyway. Trying is better than doing nothing
        whenReady(readyToPaste, within: 0.4) { _ in sendCommandV() }
    }

    /// Sends a single ⌘V: the content is already on the clipboard, only the keystroke is missing.
    ///
    /// Used for "Accessibility permission was just granted, so finish the paste that couldn't go
    /// through earlier". At that moment the user is still in System Settings and the target app is in
    /// the background, so bring it to the front first and wait until it really has focus. The wait is
    /// longer than usual, since switching apps is much slower than hiding a panel.
    ///
    /// If it won't come forward, drop it rather than forcing it. On this path it's uncertain who is
    /// frontmost (the user may still be in System Settings), and forcing a ⌘V would push content into
    /// a window we never meant to paste into. The content is on the clipboard; they can press ⌘V
    /// themselves.
    static func sendPaste(activating target: NSRunningApplication) {
        target.activate()
        whenReady({ target.isActive }, within: 1.5) { ready in
            if ready { sendCommandV() }
        }
    }

    /// Waits for the condition to hold, then continues once it does (or the time runs out). Checks every 10
    /// ms.
    ///
    /// This used to be a fixed 0.05 s wait, which was a guess: when the machine was busy or the target
    /// was a slow app, the keystroke arrived before focus came back and the paste silently did nothing.
    ///
    /// If the condition still doesn't hold at the deadline, the caller decides what to do: on the
    /// hide-the-panel path we know who is frontmost, so sending anyway is worth it; on the path that
    /// brings another app to the front we don't, so we give up.
    private static func whenReady(_ ready: @escaping () -> Bool,
                                  within seconds: TimeInterval,
                                  do action: @escaping (_ ready: Bool) -> Void) {
        poll(ready, until: Date().addingTimeInterval(seconds), do: action)
    }

    private static func poll(_ ready: @escaping () -> Bool, until deadline: Date,
                             do action: @escaping (Bool) -> Void) {
        if ready() { action(true); return }
        guard Date() < deadline else { action(false); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
            poll(ready, until: deadline, do: action)
        }
    }

    /// Puts **every** representation of this clip back on the clipboard exactly as stored.
    ///
    /// Replaying as-is is the key: no conversion, each type goes back the way it was stored, and the
    /// target app sees exactly what it would have seen from the original copy, so formatting is
    /// neither lost nor garbled.
    private static func write(_ item: ClipItem, store: HistoryStore,
                              watcher: ClipboardWatcher, variant: ClipVariant) {
        let pb = NSPasteboard.general
        pb.clearContents()

        // The panel's rows carry only the first 20,000 characters of the body (the list never
        // shows more). What gets pasted must be the whole thing: plain text made from the body, a
        // long list of file paths and pre-v2 clips all read it.
        let item = item.id.flatMap { try? store.item(id: $0) } ?? item

        // Which slot gets what is decided in one place only: ClipVariant
        let stored = (item.id.flatMap { try? store.assets(for: $0) }) ?? []
        let assets = item.payload(for: variant, assets: stored)

        if assets.isEmpty {
            // Data from before v2 has no assets; write it back the old way
            writeLegacy(item, store: store, to: pb)
        } else {
            writeAssets(assets, to: pb)
        }

        // Recognize our own write by changeCount alone.
        //
        // We used to also stamp the pasteboard with app.bowerbird.mac.own, two mechanisms doing the
        // same job, and the stamp travelled with the content: when another tool republished the same
        // NSPasteboardItem (sync tools, "copy again" features), the stamp went along and that clip
        // was never recorded.
        watcher.markOwnWrite()
    }

    /// Rebuilds the NSPasteboardItems in their original order and writes them out in one go.
    ///
    /// New captures preserve item boundaries. Old captures have no item index and keep the
    /// per-type occurrence fallback; their original boundaries cannot be recovered retroactively.
    static func writeAssets(_ assets: [ClipCapture.Asset], to pb: NSPasteboard) {
        var countsByType: [NSPasteboard.PasteboardType: Int] = [:]
        var items: [Int: NSPasteboardItem] = [:]

        for asset in assets {
            // The old multi-file type is only recognized when written at the pasteboard root, not inside an
            // item
            if asset.type == PasteboardTypes.legacyFilenames { continue }
            let index = asset.pasteboardItemIndex ?? countsByType[asset.type, default: 0]
            countsByType[asset.type, default: 0] += 1
            let item = items[index] ?? NSPasteboardItem()
            item.setData(asset.data, forType: asset.type)
            items[index] = item
        }

        if let legacy = assets.first(where: { $0.type == PasteboardTypes.legacyFilenames }) {
            pb.setData(legacy.data, forType: legacy.type)
        }
        if !items.isEmpty {
            pb.writeObjects(items.keys.sorted().compactMap { items[$0] })
        }
    }

    /// Clips recorded before v2 have only a single representation
    private static func writeLegacy(_ item: ClipItem, store: HistoryStore, to pb: NSPasteboard) {
        switch item.kind {
        case .text:
            pb.setString(item.content, forType: .string)
        case .image:
            if let image = NSImage(contentsOf: store.imageURL(for: item)) {
                pb.writeObjects([image])
            }
        case .file:
            pb.writeObjects(item.filePaths.map { URL(fileURLWithPath: $0) as NSURL })
        }
    }

    /// The device-dependent bit for the left Command key.
    ///
    /// With only `.maskCommand` set, some apps can't tell from the event whether left or right ⌘ was
    /// pressed, treat it as no modifier, and the paste silently fails. Flycut found this first
    /// (TermiT/Flycut#18); Clipy and Maccy both kept this extra bit.
    private static let leftCommandDeviceBit: UInt64 = 0x0000_0008

    private static func sendCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)

        // Suppress the user's own keyboard input while posting synthetic events, so physical keys don't get
        // mixed into this paste
        source?.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitSystemDefinedEvents],
            state: .eventSuppressionStateSuppressionInterval
        )

        let keyV = KeyboardLayout.keyCode(for: "v")
        let flags = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | leftCommandDeviceBit)

        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyV, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyV, keyDown: false) else { return }
        down.flags = flags
        up.flags = flags
        // Post to the session-level event stream, as Clipy and Maccy do. HID level inserts further
        // down, and in some cases its ordering and suppression behaviour are less reliable than session
        // level.
        down.post(tap: .cgSessionEventTap)
        up.post(tap: .cgSessionEventTap)
    }
}
