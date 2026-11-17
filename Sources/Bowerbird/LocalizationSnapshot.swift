import Foundation

/// A thread-safe snapshot for fetching user-visible strings.
///
/// Core also needs strings on background threads (computing titles for file items at insert
/// time), while the language choice and its bundle live in the settings object on the main
/// thread. This keeps an immutable snapshot: the main thread refreshes it at launch and on every
/// language change, and background threads only read it.
enum LocalizationSnapshot {
    private struct Snapshot {
        let bundle: Bundle
        let locale: Locale
    }

    private static let lock = NSLock()
    /// Guarded by the lock above, so the unsafe here is deliberate
    nonisolated(unsafe) private static var current = Snapshot(bundle: .main, locale: .current)

    /// Called on the main thread after the language changes
    static func update(bundle: Bundle, locale: Locale) {
        let snapshot = Snapshot(bundle: bundle, locale: locale)
        lock.lock()
        current = snapshot
        lock.unlock()
    }

    static func string(_ key: String, _ arguments: [CVarArg]) -> String {
        lock.lock()
        let snapshot = current
        lock.unlock()
        let format = snapshot.bundle.localizedString(forKey: key, value: key, table: nil as String?)
        guard !arguments.isEmpty else { return format }
        return String(format: format, locale: snapshot.locale, arguments: arguments)
    }
}
