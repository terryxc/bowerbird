import AppKit

/// UI appearance: follow the system, always light, or always dark.
///
/// Implemented by assigning `NSApp.appearance`, which affects only this app and leaves the system
/// setting alone. Assigning nil follows the system. Changes take effect immediately, no relaunch needed.
enum AppAppearance: String, CaseIterable, Identifiable, Codable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    @MainActor
    func apply() {
        NSApp.appearance = nsAppearance
    }
}
