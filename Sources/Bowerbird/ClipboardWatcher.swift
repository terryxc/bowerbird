import AppKit
import BowerbirdCore

/// Checks the pasteboard changeCount every 0.5 seconds; when it changes, reads the contents and turns
/// them into a history item in the background.
///
/// The main thread does only two light jobs: reading changeCount and pulling the bytes off the
/// pasteboard (NSPasteboard isn't thread-safe, so that step must be on the main thread). Everything else
/// happens in the background: a large screenshot has to be decoded, converted to PNG, hashed, written
/// to disk and to the database, which on the main thread would be a stall of several hundred ms.
@MainActor
final class ClipboardWatcher {
    private let pasteboard = NSPasteboard.general
    private var lastChangeCount: Int
    private var skipChangeCount: Int?
    private var timer: Timer?
    private let ignoredBundleIDs: () -> Set<String>
    /// While paused, skip without even reading
    private let isPaused: () -> Bool
    /// What to record and what to ignore. A copy is taken on the main thread on every tick, and the
    /// background work decides based on it.
    private let policy: () -> CapturePolicy
    /// Called on a background queue, so it must be @Sendable; it really does run across threads
    private let onCapture: @Sendable (ClipCapture, String?) -> Void
    private let queue = DispatchQueue(label: "app.bowerbird.capture", qos: .utility)

    init(ignoredBundleIDs: @escaping () -> Set<String>,
         isPaused: @escaping () -> Bool = { false },
         policy: @escaping () -> CapturePolicy = {
            CapturePolicy(kinds: Set([.text, .image, .file]), acceptsRemote: true,
                          ignorePatterns: IgnorePatterns([]))
         },
         onCapture: @escaping @Sendable (ClipCapture, String?) -> Void) {
        self.ignoredBundleIDs = ignoredBundleIDs
        self.isPaused = isPaused
        self.policy = policy
        self.onCapture = onCapture
        lastChangeCount = pasteboard.changeCount
    }

    func start() {
        guard timer == nil else { return }
        // Added to the main run loop, so this callback runs on the main thread; asserting that lets
        // the compiler know touching main-thread state is safe
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Drain pending captures before clearing on quit. Waiting asynchronously lets HTML parsing
    /// finish its main-thread work without deadlocking the capture queue.
    func stopAndWait() async {
        timer?.invalidate()
        timer = nil
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume() }
        }
    }

    /// Called by Paster after it writes to the pasteboard itself; that change doesn't go into history.
    func markOwnWrite() {
        skipChangeCount = pasteboard.changeCount
    }

    private func tick() {
        let count = pasteboard.changeCount
        guard count != lastChangeCount else { return }
        lastChangeCount = count
        if count == skipChangeCount {
            skipChangeCount = nil
            return
        }
        // changeCount is still updated while paused, so resuming doesn't record what was copied during
        // the pause
        guard !isPaused() else { return }
        let bundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        if let b = bundle, ignoredBundleIDs().contains(b) { return }
        let policy = self.policy()
        guard let raw = PasteboardReader.read(from: pasteboard, acceptRemote: policy.acceptsRemote) else { return }
        queue.async { [onCapture] in
            guard let capture = PasteboardReader.capture(from: raw), policy.allows(capture) else { return }
            onCapture(capture, bundle)
        }
    }
}
