import Foundation

/// The time windows for "Clear recent".
///
/// Alfred offers two, 5 minutes and 15 minutes, which is enough: the use case is "I just copied and
/// pasted something sensitive, wipe it while I still remember". The longer the window, the closer it
/// gets to "clear everything", which already has its own entry point. A 1-hour option covers
/// remembering a bit later.
enum ClearWindow: Int, CaseIterable, Identifiable {
    case fiveMinutes = 300
    case fifteenMinutes = 900
    case oneHour = 3600

    var id: Int { rawValue }
    var interval: TimeInterval { TimeInterval(rawValue) }

    /// The menu item
    var titleKey: String {
        switch self {
        case .fiveMinutes: "Last 5 minutes"
        case .fifteenMinutes: "Last 15 minutes"
        case .oneHour: "Last hour"
        }
    }

    /// Title of the confirmation dialog
    var questionKey: String {
        switch self {
        case .fiveMinutes: "Clear everything copied in the last 5 minutes?"
        case .fifteenMinutes: "Clear everything copied in the last 15 minutes?"
        case .oneHour: "Clear everything copied in the last hour?"
        }
    }
}
