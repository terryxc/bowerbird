import AppKit

@MainActor
enum HistoryCleanupAlert {
    static func present() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L("History could not be fully cleared")
        alert.informativeText = L("Some history or files could not be removed. Check free disk space and folder permissions, then try again.")
        alert.runModal()
    }
}
