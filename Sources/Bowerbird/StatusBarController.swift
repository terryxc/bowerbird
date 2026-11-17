import AppKit

@MainActor
final class StatusBarController {
    private let item: NSStatusItem
    private let onOpenPanel: () -> Void
    private let onOpenSettings: () -> Void

    init(onOpenPanel: @escaping () -> Void, onOpenSettings: @escaping () -> Void) {
        self.onOpenPanel = onOpenPanel
        self.onOpenSettings = onOpenSettings
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.menu = buildMenu()
        refreshIcon()
        NotificationCenter.default.addObserver(
            forName: .bowerbirdLanguageChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Keep the current permission-warning state when rebuilding
                self.item.menu = self.buildMenu(accessibilityMissing: self.accessibilityMissing)
            }
        }
    }

    private var accessibilityMissing = false

    /// Draws the menu bar icon according to current settings.
    ///
    /// When paused it drops to 40% opacity. Maccy's pause can only be toggled by ⌥-clicking its icon,
    /// with no visual feedback afterwards, so you can't tell whether it's recording. Showing the
    /// state at a glance is where we should do better.
    func refreshIcon() {
        let settings = AppSettings.shared
        let image = settings.menuBarIcon.image()
        item.button?.image = image
        item.button?.alphaValue = settings.paused ? 0.4 : 1
        item.button?.toolTip = settings.paused ? L("Paused") : "Bowerbird"
    }

    func setAccessibilityMissing(_ missing: Bool) {
        accessibilityMissing = missing
        item.menu = buildMenu(accessibilityMissing: missing)
    }

    private func buildMenu(accessibilityMissing: Bool = false) -> NSMenu {
        let menu = NSMenu()
        // All three items get explicit icons. macOS 26 automatically gives "Settings…" and "Quit"
        // symbols but not custom items, so "Open Panel" alone had an empty gap, which looked odd.
        let open = NSMenuItem(title: L("Open Panel"), action: #selector(openPanel), keyEquivalent: "")
        open.target = self
        open.image = NSImage(systemSymbolName: "list.clipboard", accessibilityDescription: nil)
        menu.addItem(open)
        // Pause goes at the top. Something used this often shouldn't be buried three clicks deep in
        // the settings window.
        //
        // A menu item's text says "what happens when you click", not "what state it's in", so while
        // paused it reads "Resume Recording". Adding a checkmark would make three things say three
        // different things: the check says "on", the icon says "click to play", the text says
        // "pause". The state is conveyed by the icon and the dimmed menu bar icon; that's enough.
        let paused = AppSettings.shared.paused
        let pause = NSMenuItem(title: paused ? L("Resume Recording") : L("Pause Recording"),
                               action: #selector(togglePause), keyEquivalent: "")
        pause.target = self
        pause.image = NSImage(systemSymbolName: paused ? "play.fill" : "pause.fill",
                              accessibilityDescription: nil)
        menu.addItem(pause)
        menu.addItem(.separator())

        let settings = NSMenuItem(title: L("Settings…"), action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        settings.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        menu.addItem(settings)
        if accessibilityMissing {
            let warn = NSMenuItem(title: L("Accessibility Permission Needed…"), action: #selector(openAccessibility), keyEquivalent: "")
            warn.target = self
            warn.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil)
            menu.addItem(warn)
        }
        menu.addItem(.separator())
        let quit = NSMenuItem(title: L("Quit Bowerbird"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.image = NSImage(systemSymbolName: "power", accessibilityDescription: nil)
        menu.addItem(quit)
        return menu
    }

    @objc private func openAccessibility() { AccessibilityPermission.shared.request() }
    @objc private func openPanel() { onOpenPanel() }
    @objc private func openSettings() { onOpenSettings() }

    @objc private func togglePause() {
        AppSettings.shared.paused.toggle()
        refresh()
    }

    /// Refreshes the icon and the menu together. The pause item's title and the icon's dimming say
    /// the same thing; refreshing only one would leave them out of sync.
    func refresh() {
        item.menu = buildMenu(accessibilityMissing: accessibilityMissing)
        refreshIcon()
    }
}
