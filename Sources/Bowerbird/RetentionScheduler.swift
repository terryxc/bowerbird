import Foundation
import BowerbirdCore

/// Cleans up according to the current settings at launch and every hour after that.
@MainActor
final class RetentionScheduler {
    private let store: HistoryStore
    /// Reads the current settings on the main thread before each cleanup
    private let policy: @MainActor () -> RetentionPolicy
    private let onPurged: @MainActor @Sendable (Int) -> Void
    private var timer: Timer?

    init(store: HistoryStore, policy: @escaping @MainActor () -> RetentionPolicy,
         onPurged: @escaping @MainActor @Sendable (Int) -> Void) {
        self.store = store
        self.policy = policy
        self.onPurged = onPurged
    }

    func start() {
        runOnce()
        let t = Timer(timeInterval: 3_600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.runOnce() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func runOnce() {
        let policy = self.policy()
        DispatchQueue.global(qos: .utility).async { [store, onPurged] in
            let removed = (try? store.purge(policy: policy)) ?? 0
            Task { @MainActor in onPurged(removed) }
        }
    }
}
