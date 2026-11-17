import AppKit

/// Main menu, in two tiers.
///
/// We're an LSUIElement (`.accessory`): normally no Dock icon and no menu bar. But two things still
/// depend on the main menu:
///
/// 1. Shortcuts for standard editing commands like ⌘C, ⌘V, ⌘A and ⌘Z **are dispatched through the
///    main menu**. Without this menu, testing showed ⌘A doing nothing in the search
///    field, ⌘V not pasting, and ⌘C not copying text selected in the preview. So the "Edit" menu is
///    always there, just invisible.
/// 2. While the settings window is open, the menu bar shows the **previous app's** menus (observed:
///    the window was ours, the menu bar said Chrome). ⌘W didn't close the window and ⌘Q did
///    nothing, with no feedback either way. Alfred and Raycast switch to `.regular` while the
///    window is open, so the menu bar and Dock icon appear together, and switch back when it
///    closes. Switching the policy also switches this menu: the `.regular` tier adds the
///    application menu and the "Window" menu.
///
/// The tiers are separate, rather than always installing the full set, because the application menu
/// has ⌘Q. The panel is the key window, so with the full menu always installed, ⌘Q in the panel
/// would quit the whole app. Quitting currently belongs only to the menu bar icon's drop-down,
/// and that shouldn't change because of the settings window.
///
/// All actions target nil, i.e. the current first-responder chain: editing commands land on the
/// focused text, "Close" and "Minimize" land on the key window, and "Settings…" and "About"
/// travel all the way up to AppDelegate.
@MainActor
enum MainMenu {
    enum Mode { case accessory, regular }

    private(set) static var mode: Mode = .accessory
    private static var languageObserver: NSObjectProtocol?

    /// Called once at launch: installs the `.accessory` tier and reinstalls the current tier
    /// whenever the language changes, since menu titles are localised and NSMenu doesn't update its text by itself.
    static func start() {
        install(.accessory)
        languageObserver = NotificationCenter.default.addObserver(
            forName: .bowerbirdLanguageChanged, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { install(mode) }
        }
    }

    static func install(_ mode: Mode) {
        self.mode = mode
        let main = NSMenu()
        if mode == .regular { main.addItem(submenu(application())) }
        main.addItem(submenu(edit()))
        if mode == .regular { main.addItem(submenu(window())) }
        NSApp.mainMenu = main
    }

    /// The system replaces the application menu's title with the app name; whatever is written here isn't shown
    private static func application() -> NSMenu {
        let menu = NSMenu(title: "Bowerbird")
        add(to: menu, L("About Bowerbird"), #selector(AppDelegate.showAbout(_:)), "")
        menu.addItem(.separator())
        add(to: menu, L("Settings…"), #selector(AppDelegate.showSettings(_:)), ",")
        menu.addItem(.separator())
        add(to: menu, L("Hide Bowerbird"), #selector(NSApplication.hide(_:)), "h")
        menu.addItem(.separator())
        add(to: menu, L("Quit Bowerbird"), #selector(NSApplication.terminate(_:)), "q")
        return menu
    }

    private static func edit() -> NSMenu {
        let menu = NSMenu(title: L("Edit"))
        // `undo:` and `redo:` with the colon: that's what NSWindow answers in the responder chain.
        // `#selector(UndoManager.undo)` spells `undo` with no colon, which nothing responds to, so the
        // items stayed disabled and ⌘Z did nothing in the search field or in settings.
        add(to: menu, L("Undo"), Selector(("undo:")), "z")
        add(to: menu, L("Redo"), Selector(("redo:")), "Z")
        menu.addItem(.separator())
        add(to: menu, L("Cut"), #selector(NSText.cut(_:)), "x")
        add(to: menu, L("Copy"), #selector(NSText.copy(_:)), "c")
        add(to: menu, L("Paste"), #selector(NSText.paste(_:)), "v")
        add(to: menu, L("Select All"), #selector(NSText.selectAll(_:)), "a")
        return menu
    }

    private static func window() -> NSMenu {
        let menu = NSMenu(title: L("Window"))
        add(to: menu, L("Close"), #selector(NSWindow.performClose(_:)), "w")
        add(to: menu, L("Minimize"), #selector(NSWindow.performMiniaturize(_:)), "m")
        return menu
    }

    private static func submenu(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem()
        item.title = menu.title
        item.submenu = menu
        return item
    }

    private static func add(to menu: NSMenu, _ title: String, _ action: Selector, _ key: String) {
        // An uppercase letter means the ⇧ variant (Redo is ⇧⌘Z), which AppKit recognises by itself
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key.lowercased())
        if key != key.lowercased() { item.keyEquivalentModifierMask = [.command, .shift] }
        menu.addItem(item)
    }
}
