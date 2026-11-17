import AppKit
import SwiftUI

final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    let panel: NSPanel
    let model: PanelModel
    private var keyMonitor: Any?

    init(model: PanelModel) {
        self.model = model
        let size = AppSettings.shared.panelSize.dimensions
        panel = KeyablePanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered, defer: false)
        super.init()
        panel.isFloatingPanel = true
        // Raycast's level. The panel used to sit at .screenSaver (1000) so that Chrome's autofill
        // dropdown, a separate window at layer 999 that stays open while Chrome is active, couldn't
        // cover it. That height had a price: the system's Accessibility prompt ended up underneath
        // the panel, and screenshot tools skip windows at layer 103 and up (Snipaste, checked in its
        // disassembly), so they never snapped to the panel's edges. Since show() now makes Bowerbird
        // the active app, Chrome closes the dropdown itself the moment it loses focus (measured),
        // and the panel only needs to clear ordinary windows.
        panel.level = .modalPanel
        // Turn off the default window appearance animation; summoning should be instant
        panel.animationBehavior = .none
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // The panel is not dragged: it appears where the position setting says and goes away. With
        // this switch on, blank areas of the preview would become handles, and that's where you
        // select text.
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.auxiliary, .stationary, .moveToActiveSpace, .fullScreenAuxiliary]
        panel.delegate = self

        // A solid background, no vibrancy. Vibrancy's brightness follows the desktop, so contrast
        // can't be computed reliably; rounded corners would need a mask to clip the blur the window
        // server composites, and dark mode has had problems with it before. A background with a
        // definite colour, one value each for light and dark, is far less trouble.
        let backdrop = PanelBackdropView(frame: NSRect(origin: .zero, size: size))
        backdrop.autoresizingMask = [.width, .height]

        let host = NSHostingView(rootView: LocalizedRoot { PanelView(model: model) })
        host.frame = backdrop.bounds
        host.autoresizingMask = [.width, .height]
        // The hosting view needs rounded corners too. SwiftUI's backing draws square corners.
        host.wantsLayer = true
        host.layer?.cornerRadius = PanelMetrics.cornerRadius
        host.layer?.masksToBounds = true
        backdrop.addSubview(host)
        panel.contentView = backdrop

        // The raise that comes with activation lands after show() returns; push the other windows
        // back again at that moment, see sendOtherWindowsBack
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.panel.isVisible else { return }
                self.sendOtherWindowsBack()
            }
        }
    }

    func toggle() {
        panel.isVisible ? hide() : show()
    }

    func show() {
        // Remember which app was frontmost when the panel was summoned: hide() hands focus back to it,
        // and pasting waits for it to be frontmost again before sending ⌘V. Read it before activating,
        // while it is still the frontmost app.
        model.pasteTarget = NSWorkspace.shared.frontmostApplication
        model.reset()
        applySize()
        position()
        // Become the active app, the way Alfred and Raycast do. The panel used to come forward without
        // activating (orderFrontRegardless), leaving the app you came from active; that is what forced
        // the window level up to 1000, see init. Activating costs a visible deactivation of the window
        // behind (its title bar and selection go grey while the panel is open) and nothing measurable
        // on paste: hide() asks the previous app to activate before ⌘V is posted, and the window
        // server handles the two in order, so the paste waited 0.3 ms on average over 40 runs, the
        // same as before.
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        sendOtherWindowsBack()
        installKeyMonitor()
        // Recompute the shadow from the content's actual shape. After the size preset changes or the
        // bottom bar is shown or hidden, the old shadow still has the previous outline
        DispatchQueue.main.async { [weak self] in self?.panel.invalidateShadow() }
    }

    func hide() {
        removeKeyMonitor()
        // Whether focus is still ours has to be read before the panel goes away. When the user
        // clicked into another app, that app is already frontmost by the time the panel resigns key
        // and lands here; activating the previous app then would snatch focus from the one they just
        // chose. Only a hide we initiated (Esc, paste, dismiss) hands focus back.
        let focusIsOurs = NSWorkspace.shared.frontmostApplication == .current
        panel.orderOut(nil)
        if focusIsOurs, let target = model.pasteTarget, target != .current, !target.isTerminated {
            target.activate()
        }
        sendOtherWindowsBack()
    }

    /// Keeps the settings window out of the way when the panel is summoned while it is open.
    ///
    /// Activating an app raises every one of its windows above the other apps' windows, so the
    /// settings window jumped in front of the window the user was working in, and it stayed there
    /// after the panel closed: activating that app again does not push our windows back down
    /// (measured). Ordering our other windows to the back restores what the user saw. It
    /// runs again when the app reports it became active, because the raise lands asynchronously,
    /// after show() has returned, and once more on hide for good measure.
    private func sendOtherWindowsBack() {
        for window in NSApp.windows where window !== panel && window.isVisible && window.level == .normal {
            window.orderBack(nil)
        }
    }

    /// After the size preset changes in Settings, the next summon uses the new size.
    private func applySize() {
        let size = AppSettings.shared.panelSize.dimensions
        guard panel.frame.size != size else { return }
        panel.setContentSize(size)
    }

    /// Where it appears is decided by Settings, and the result is always clamped back into the visible
    /// area; following the cursor can easily push the panel off screen.
    private func position() {
        let settings = AppSettings.shared
        panel.setFrameOrigin(settings.panelPosition.origin(for: panel.frame.size))
    }

    func windowDidResignKey(_ notification: Notification) {
        // Don't hide while a modal dialog is up on the panel (e.g. the clear confirmation), otherwise
        // the dialog disappears along with it
        guard NSApp.modalWindow == nil else { return }
        hide()
    }

    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel.isKeyWindow else { return event }
            return self.handle(event) ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        keyMonitor = nil
    }

    /// While an input method is composing (the pinyin candidate window is open), every key belongs to
    /// the input method. Otherwise we'd take the arrow keys to move the selection and scramble the
    /// candidates the user is paging through.
    ///
    /// Only works for input methods that compose with marked text. WeChat Input Method doesn't use
    /// marked text while composing, so this always reports "not composing". That's why Return isn't
    /// intercepted here; see the note in handle.
    private var isComposing: Bool {
        guard let editor = panel.firstResponder as? NSTextView else { return false }
        return editor.hasMarkedText()
    }

    /// Whether the caret is in the search field.
    ///
    /// While it is, the window's first responder is the field's editor, an editable NSTextView. The
    /// other things that can hold focus are the preview's read-only text (after clicking in it to
    /// select) and the kind menu's pop-up button (after clicking it), neither of which is an
    /// editable text view.
    private var searchFieldHasFocus: Bool {
        guard let editor = panel.firstResponder as? NSTextView else { return false }
        return editor.isEditable
    }

    /// The search field's view.
    ///
    /// We can't get at SwiftUI's TextField, but while it has focus the window's first responder is its
    /// field editor, and the field editor's delegate is that view. Focus is on the search field when
    /// the panel opens anyway, so we note it on every key press and know exactly where to return
    /// focus later.
    private weak var searchField: NSView?

    private func rememberSearchField() {
        guard let editor = panel.firstResponder as? NSTextView, editor.isEditable,
              let owner = editor.delegate as? NSView else { return }
        searchField = owner
    }

    /// Returns true if handled, in which case the event isn't passed on to the search field.
    /// Internal rather than private so tests can feed it events: the key monitor only runs while
    /// the panel is the key window, which a test process can't make it.
    @discardableResult
    func handle(_ e: NSEvent) -> Bool {
        if isComposing { return false }
        let settings = AppSettings.shared

        rememberSearchField()

        // After clicking text in the preview (to select or copy it) or the kind menu, keyboard focus
        // sits on that control. Typing from there must still search: the search field is the only
        // place in the panel that takes input, and Alfred and Raycast follow the same rule: wherever
        // focus is, typing means searching.
        //
        // Give first responder back to the search field and then **let this key press through**
        // (return false) so the field receives the character itself. Just changing model.query isn't
        // enough: SwiftUI's TextField has its own editing buffer that doesn't know about writes to the
        // binding at that point, so the next character overwrites what was just written. Measured:
        // typing abc left only bc.
        let plain = e.modifierFlags.intersection(PanelShortcut.relevantModifiers).isEmpty
        if !searchFieldHasFocus, plain, let field = searchField,
           let typed = e.characters, !typed.isEmpty,
           // Arrows, Home, End and Page keys arrive as private-use characters (0xF700...), which
           // are not "control characters"; treated as typing, the first ↓ after clicking the
           // preview only moved focus and never reached the navigation below.
           typed.unicodeScalars.allSatisfy({
               !CharacterSet.controlCharacters.contains($0) && !(0xF700...0xF8FF).contains($0.value)
           }) {
            panel.makeFirstResponder(field)
            return false
        }
        // Return with focus elsewhere: the field's onSubmit will not fire, so do what it would do.
        // Seen after picking a kind from the menu: the pop-up button kept focus, Return went to it,
        // and nothing was pasted. Returning focus to the field keeps the caret visible.
        if !searchFieldHasFocus, plain, e.keyCode == 36 || e.keyCode == 76 {
            if let field = searchField { panel.makeFirstResponder(field) }
            if let action = PanelAction.allCases.first(where: { settings.shortcut(for: $0)?.isBareReturn == true }) {
                model.perform(action)
            }
            return true
        }

        // Customizable actions are matched first. They may be set to something like Return with a
        // modifier, so they have to come before the fixed keys below or they'd never get a turn.
        // Return without modifiers isn't intercepted here; it goes to the search field's onSubmit
        // (while an input method is composing, Return belongs to the input method).
        for action in PanelAction.allCases {
            guard let shortcut = settings.shortcut(for: action), !shortcut.isBareReturn,
                  shortcut.matches(e) else { continue }
            // If the format bar isn't showing, don't intercept; ⇥ has to go back to the system
            if action == .cycleFormat, !model.showsFormatBar { return false }
            model.perform(action)
            return true
        }

        // ⇧ plus the same key goes backwards. PanelShortcut requires modifiers to match exactly, so the
        // reverse direction won't match and has to be compared by hand.
        if let cycle = settings.shortcut(for: .cycleFormat), model.showsFormatBar,
           e.keyCode == cycle.keyCode,
           e.modifierFlags.intersection(PanelShortcut.relevantModifiers) == cycle.flags.union(.shift) {
            model.cycleFormat(-1)
            return true
        }

        // Fixed, not customizable: these are the common semantics of list interaction, and changing
        // them would only make them harder to hit.
        //
        // Return without modifiers isn't intercepted here. It goes to the search field, where onSubmit
        // triggers the action bound to Return: while an input method is composing, Return is consumed
        // by the input method to commit text and never reaches onSubmit. Intercepting it here would
        // depend on isComposing, and WeChat Input Method doesn't use marked text while composing, so
        // that can't tell.
        let mods = e.modifierFlags.intersection(PanelShortcut.relevantModifiers)
        let bare = mods.isEmpty
        switch e.keyCode {
        // esc. While the permission card is showing, it acts as the card's "Not Now": the content is
        // already copied and the panel has done its job, so hide everything. With a search typed, the
        // first Esc only clears it (as in Raycast): the next search starts from a clean field without
        // leaving the panel. A second Esc closes.
        case 53:
            if model.showsPermissionCard { model.dismissPermissionCard() }
            else if !model.query.isEmpty { model.query = "" }
            else { hide() }
            return true
        case 125 where bare: model.moveSelection(1); return true        // ↓
        case 126 where bare: model.moveSelection(-1); return true       // ↑
        // Home / End and, for keyboards without them, ⌘↑ / ⌘↓
        case 115 where bare, 126 where mods == .command: model.moveSelectionToEnd(.first); return true
        case 119 where bare, 125 where mods == .command: model.moveSelectionToEnd(.last); return true
        case 116 where bare: model.moveSelection(pages: -1); return true  // Page Up
        case 121 where bare: model.moveSelection(pages: 1); return true   // Page Down
        default: break
        }

        // ⌘1…⌘9 paste that row directly. Fixed, not customizable: number-row shortcuts mean this in
        // any list.
        if e.modifierFlags.intersection(PanelShortcut.relevantModifiers) == .command,
           let n = DigitKey.number(keyCode: e.keyCode, characters: e.charactersIgnoringModifiers) {
            model.activate(at: n - 1, copyOnly: false)
            return true
        }

        // ⌥1…⌥6 jump straight to the Nth cell of the format bar
        if model.showsFormatBar,
           e.modifierFlags.intersection(PanelShortcut.relevantModifiers) == .option,
           let n = DigitKey.number(keyCode: e.keyCode, characters: e.charactersIgnoringModifiers) {
            model.selectFormat(at: n)
            return true
        }
        return false
    }
}

/// The panel's background: a solid colour, rounded corners and a hairline border. Follows the
/// system appearance.
final class PanelBackdropView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = PanelMetrics.cornerRadius
        layer?.masksToBounds = true
        layer?.borderWidth = Hairline.width
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    /// AppKit calls this again when the appearance changes, so the colours follow
    override func updateLayer() {
        layer?.backgroundColor = NSColor(AppColors.panelBackground).cgColor
        layer?.borderColor = NSColor(AppColors.panelBorder).cgColor
    }
}
