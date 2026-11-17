import AppKit

@MainActor
final class AppIconCache {
    static let shared = AppIconCache()
    /// The value is NSImage? rather than NSImage: misses have to be remembered too.
    /// Otherwise a source that can never be found, like `com.apple.loginwindow`, would ask Launch
    /// Services again on every redraw, and the cache might as well not exist for it.
    private var cache: [String: NSImage?] = [:]

    private var names: [String: String] = [:]
    private var fileIcons: [String: NSImage?] = [:]

    /// The app's display name for a bundle ID; nil if it isn't installed on this machine
    func installedName(for bundleID: String) -> String? {
        if let hit = names[bundleID] { return hit.isEmpty ? nil : hit }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            names[bundleID] = ""
            return nil
        }
        let resolved = FileManager.default.displayName(atPath: url.path)
            .replacingOccurrences(of: ".app", with: "")
        names[bundleID] = resolved
        return resolved
    }

    /// Display name for the UI, falling back to the bundle ID when not found
    func name(for bundleID: String) -> String {
        installedName(for: bundleID) ?? bundleID
    }

    /// The source app's icon. Returns nil when not found and lets the caller decide what to draw.
    /// Don't put a generic placeholder here: stretched through `Image(nsImage:)` it renders very
    /// faintly and looks like a blank patch.
    ///
    /// Misses are common: copies made while the screen is locked come from
    /// `com.apple.loginwindow`, and apps not installed in /Applications aren't in the Launch
    /// Services index either.
    func icon(for bundleID: String?) -> NSImage? {
        guard let bundleID else { return nil }
        if let hit = cache[bundleID] { return hit }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            // It has to be written as NSImage?.none explicitly. `cache[bundleID] = nil` removes the
            // entry from the dictionary, which records nothing, and the next call asks again.
            cache[bundleID] = NSImage?.none
            return nil
        }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        cache[bundleID] = image
        return image
    }

    /// The icon of the file itself. For file items this is far more fitting than the source app's
    /// icon: you can tell at a glance whether it's a PDF or an image.
    /// Remembered per path. The list asks for every row on each redraw, and each lookup is a file
    /// system query plus a workspace call; holding an arrow key down across the list makes that
    /// dozens of times.
    /// The icon goes stale if the file is deleted or changes type; the cache is rebuilt the next
    /// time the panel opens, which is an acceptable cost.
    func icon(forFileAt path: String) -> NSImage? {
        if let hit = fileIcons[path] { return hit }
        guard FileManager.default.fileExists(atPath: path) else {
            // Remember missing files too, or every row redraw would stat that nonexistent path again.
            // Again, this can't be written as `= nil`, which would remove the entry.
            fileIcons[path] = NSImage?.none
            return nil
        }
        let icon = NSWorkspace.shared.icon(forFile: path)
        fileIcons[path] = icon
        return icon
    }

    /// Cleared every time the panel opens so icons don't stay stale
    func forgetFileIcons() {
        fileIcons.removeAll()
    }
}
