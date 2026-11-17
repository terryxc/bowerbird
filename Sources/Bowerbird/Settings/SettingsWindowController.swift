import AppKit
import BowerbirdCore
import SwiftUI

@MainActor
final class SettingsWindowController {
    private let window: NSWindow

    init(store: HistoryStore) {
        let host = NSHostingController(rootView: LocalizedRoot { SettingsView(store: store) })
        window = NSWindow(contentViewController: host)
        window.title = L("Bowerbird Settings")
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: SettingsMetrics.windowWidth, height: SettingsMetrics.windowHeight))
        window.center()
        observeClose()
        NotificationCenter.default.addObserver(
            forName: .bowerbirdLanguageChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                // This callback is registered on the main queue, so asserting isolation makes it
                // safe to touch main-thread state
                self?.window.title = L("Bowerbird Settings")
            }
        }
    }

    /// Opens the Settings window and turns the app into a "normal" app along the way.
    ///
    /// Normally we're `.accessory`: no Dock icon and no menu bar. With the Settings window open,
    /// the menu bar showed the previous app's menus. Observed: the window was ours, the menu bar
    /// said Chrome, ⌘W didn't close it and ⌘Q did nothing. So while the window is open we switch to
    /// `.regular` (an icon appears in the Dock and the menu bar is ours; see MainMenu), and switch
    /// back when it closes. Alfred and Raycast both do this.
    func show(page: SettingsPage? = nil) {
        MainMenu.install(.regular)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        if let page {
            NotificationCenter.default.post(name: .bowerbirdSettingsPageRequested, object: page)
        }
    }

    private var closeObserver: NSObjectProtocol?

    private func observeClose() {
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                // A shortcut field left recording must not outlive the window
                RecordingSession.shared.active = nil
                MainMenu.install(.accessory)
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }
}

extension Notification.Name {
    /// Which page the Settings window should turn to. object is a SettingsPage.
    static let bowerbirdSettingsPageRequested = Notification.Name("bowerbirdSettingsPageRequested")
}
