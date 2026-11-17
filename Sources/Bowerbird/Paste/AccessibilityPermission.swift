import AppKit
import ApplicationServices
import Combine

/// Everything the panel needs from the Accessibility permission, which is four things: can we paste
/// now, tell me when we can, go and ask for it, and ask the system again.
///
/// This seam exists so the panel can be tested. Otherwise every test would depend on whether the
/// machine running it has granted the permission, and `request()` would really show the system prompt.
@MainActor
protocol AccessibilityState: AnyObject {
    var isTrusted: Bool { get }
    var isTrustedChanged: AnyPublisher<Bool, Never> { get }
    func request()
    func refresh()
}

extension AccessibilityPermission: AccessibilityState {
    var isTrustedChanged: AnyPublisher<Bool, Never> { $isTrusted.eraseToAnyPublisher() }
}

/// The Accessibility permission: the single source of truth for its state, and the single entry point
/// for requesting it.
///
/// This used to be scattered across four places, each checking on its own: once at launch (with the
/// system prompt), once when the panel opened, once when the Settings page appeared, and again before
/// every paste. The four copies of the state knew nothing of each other, so none noticed another change.
/// Now there is only this one; it broadcasts changes itself, and the panel, menu bar and Settings page
/// all watch it.
///
/// Only the "granted" direction works; "revoked" can't be detected. That is a system limitation, not
/// something missing here; see the measurements above refresh().
@MainActor
final class AccessibilityPermission: ObservableObject {
    static let shared = AccessibilityPermission()

    @Published private(set) var isTrusted: Bool

    /// We have already asked the system once.
    ///
    /// The system's "grant access?" prompt can only appear while TCC has no decision yet; after it has
    /// been shown once, further calls silently return false and nothing happens. So the first time we use
    /// the system prompt (it adds us to the list itself, which is the easiest path), and after that we
    /// jump straight to the page in System Settings.
    private(set) var hasAsked: Bool {
        get { UserDefaults.standard.bool(forKey: Self.askedKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.askedKey) }
    }

    private static let askedKey = "accessibilityAsked"

    /// Polling while we wait for the permission to be granted.
    ///
    /// The system's `com.apple.accessibility.api` notification is undocumented and not always delivered;
    /// it isn't sent when the app is removed from the list entirely. When it arrives it's faster; when it
    /// doesn't, this poll is the fallback.
    private var poll: Timer?

    private init() {
        isTrusted = AXIsProcessTrusted()
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.accessibility.api"), object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                // The notification arrives slightly before the permission table updates, so check now and
                // again a little later
                AccessibilityPermission.shared.refresh()
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(500))
                    AccessibilityPermission.shared.refresh()
                }
            }
        }
    }

    /// Check again.
    ///
    /// Only "granted" can be detected; "revoked" cannot. We tried; it can't be done.
    /// Measured: revoke the permission without restarting the process, then check
    /// repeatedly for two minutes twenty seconds:
    ///
    /// - `AXIsProcessTrusted()` stays true
    /// - `CGPreflightPostEventAccess()` stays true. It is the API designed precisely for "can I post
    ///   events", and it still stays true
    /// - Actually calling `AXUIElementCopyAttributeValue` keeps returning kAXErrorSuccess
    ///
    /// Meanwhile a synthesized ⌘V at the same moment really does paste nothing. TCC cuts off event
    /// posting immediately, while reading AX attributes still uses the connection set up when access
    /// was granted. None of the three checks reflects reality, and the system gives no live signal.
    ///
    /// So we accept the gap: after the permission is turned off in System Settings and before the app
    /// is relaunched, the UI shows "all good" and Return copies without pasting. See regression
    /// checklist PRM-09.
    ///
    /// (At one point it looked like a solution: about 35 seconds after revoking, an AX call returned
    /// kAXErrorAPIDisabled once. Two more minutes of testing showed that was noise; it went back to
    /// success afterwards, so it can't be relied on.)
    func refresh() {
        let now = AXIsProcessTrusted()
        guard now != isTrusted else { return }
        isTrusted = now
        if now { stopWatching() }
    }

    /// Ask for the permission. The first time, let the system show its own prompt; after that, jump to
    /// the page in System Settings.
    ///
    /// Both paths take the user away from us, so start a round of polling as well. We find out the
    /// moment the switch is turned on, without waiting for the user to come back and click anything.
    func request() {
        if hasAsked {
            NSWorkspace.shared.open(Self.settingsURL)
        } else {
            hasAsked = true
            // Under Swift 6 the global constant for this key counts as mutable global state; its value is
            // fixed, so spell it out
            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        }
        startWatching()
    }

    func openSystemSettings() {
        NSWorkspace.shared.open(Self.settingsURL)
        startWatching()
    }

    /// Opens directly on the "Privacy & Security › Accessibility" page.
    /// It only gets to the page; it can't highlight our row or scroll it into view. The system has no
    /// parameter for that.
    private static let settingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!

    /// Fallback for when Bowerbird isn't in the System Settings list at all: select it in Finder so it
    /// can be dragged into the list.
    ///
    /// This happens when running straight from the DMG, or after the app has moved; TCC records the
    /// old path.
    func showInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    /// Polling limit. Polling forever once the user has gone to System Settings is wrong; they may have
    /// walked away.
    ///
    /// Five minutes, the same as PanelModel.pendingPasteWindow; the two must change together. If the
    /// polling stopped first and the user turned the switch on in minute three, the still-pending
    /// deferred paste would depend on the system notification, which isn't guaranteed to arrive, and
    /// half the time it would wait for nothing.
    private static let watchLimit: TimeInterval = 300

    private func startWatching() {
        stopWatching()
        let deadline = Date().addingTimeInterval(Self.watchLimit)
        poll = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            MainActor.assumeIsolated {
                let permission = AccessibilityPermission.shared
                permission.refresh()
                if Date() >= deadline { permission.stopWatching() }
            }
        }
    }

    private func stopWatching() {
        poll?.invalidate()
        poll = nil
    }
}
