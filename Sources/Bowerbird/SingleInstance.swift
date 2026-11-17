import AppKit

/// Only one Bowerbird at a time.
///
/// macOS itself only blocks "the same bundle path launched twice". People who get the DMG usually do
/// this: double-click it once inside the disk image (Gatekeeper's App Translocation copies it into a
/// read-only random directory under /private/var/folders/…/AppTranslocation/), then drag the app into
/// /Applications and double-click it a second time. The paths differ, so Launch Services treats them
/// as two apps, and two birds show up side by side in the menu bar.
///
/// The duplicate icon is only the symptom. Both instances have the same bundle id and write the same
/// history.sqlite, and the two ClipboardWatchers each poll the pasteboard every 0.5 seconds, recording
/// the same content twice.
enum SingleInstance {
    /// Cross-process "show the panel".
    ///
    /// When the user clicks the icon again, they want to see the panel, not start another copy of the
    /// app. DistributedNotificationCenter is one of the few channels that works directly between
    /// non-sandboxed apps without an App Group.
    static let showPanelNotification = Notification.Name("app.bowerbird.mac.showPanel")

    /// A candidate instance. Keeps only the two fields the decision needs, so tests can build one
    /// easily; NSRunningApplication has no public initializer, so writing tests against real objects
    /// is impossible.
    struct Peer: Equatable {
        var processIdentifier: pid_t
        var isTerminated: Bool

        init(processIdentifier: pid_t, isTerminated: Bool = false) {
            self.processIdentifier = processIdentifier
            self.isTerminated = isTerminated
        }
    }

    /// The candidate, other than ourselves, that's still alive.
    ///
    /// We exclude ourselves because this process is already in Launch Services' registry at this
    /// point; isTerminated matters because an instance that just quit lingers in the registry for a
    /// short while.
    static func peer(among candidates: [Peer], selfPID: pid_t) -> Peer? {
        candidates.first { $0.processIdentifier != selfPID && !$0.isTerminated }
    }

    /// Whether this process may continue launching.
    ///
    /// false means "one is already running": the panel has been handed over to that one, and the
    /// caller should quit.
    @MainActor
    static func claim() -> Bool {
        // No bundle id means the executable in .build is being run directly (swift run, debugging).
        // Blocking there would only get in the way, and it can't see the same Launch Services record
        // anyway.
        guard let bundleID = Bundle.main.bundleIdentifier, !bundleID.isEmpty else { return true }
        let candidates = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .map { Peer(processIdentifier: $0.processIdentifier, isTerminated: $0.isTerminated) }
        guard peer(among: candidates,
                   selfPID: ProcessInfo.processInfo.processIdentifier) != nil else { return true }
        // Not activate(): an LSUIElement app has no windows and no Dock icon, so activating it does
        // nothing visible on screen, and the user would just think the click did nothing.
        DistributedNotificationCenter.default().postNotificationName(
            showPanelNotification, object: nil, userInfo: nil, deliverImmediately: true)
        return false
    }
}
