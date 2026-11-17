import AppKit
import Carbon
import KeyboardShortcuts

/// Shortcuts inside the panel.
///
/// The KeyboardShortcuts library can't be used here: it registers **global** hotkeys, and registering
/// ⌘P globally would steal the Print shortcut from every app on the system. Panel actions only apply
/// while the panel is open, so storing our own copy and matching it in the event monitor is enough.
struct PanelShortcut: Codable, Equatable {
    var keyCode: UInt16
    /// Raw value of `NSEvent.ModifierFlags`, keeping only the device-independent bits
    var modifiers: UInt

    init(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
        self.keyCode = keyCode
        self.modifiers = modifiers.intersection(.deviceIndependentFlagsMask).rawValue
    }

    /// The global hotkey in this type's terms, so it is drawn with the same keycaps as the panel's keys.
    init(_ shortcut: KeyboardShortcuts.Shortcut) {
        self.init(keyCode: UInt16(shortcut.carbonKeyCode),
                  modifiers: shortcut.modifiers.intersection(Self.relevantModifiers))
    }

    var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }

    /// "This action has no key". Stored as a key code that can't be typed, so the dictionary can tell
    /// it apart from "never changed": never changed uses the default key, removed really means none.
    ///
    /// It can't be called `none`: writing `.none` into a `[PanelAction: PanelShortcut]` resolves to
    /// `Optional.none`, which deletes the entry and falls back to the default key, so clicking the
    /// clear button would look like it did nothing.
    static let unbound = PanelShortcut(keyCode: UInt16.max, modifiers: [])
    var isUnbound: Bool { keyCode == UInt16.max }

    /// Whether this is Return with no modifiers. That one key doesn't go through the keyboard monitor but
    /// through the search field's onSubmit; see PanelController.
    var isBareReturn: Bool { (keyCode == 36 || keyCode == 76) && flags.isEmpty }

    func matches(_ event: NSEvent) -> Bool {
        event.keyCode == keyCode
            && event.modifierFlags.intersection(Self.relevantModifiers) == flags
    }

    /// Only these four modifiers are compared. Caps Lock, fn and numeric-keypad bits are ignored;
    /// otherwise shortcuts would stop working with Caps Lock on.
    static let relevantModifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

    /// Split into individual keycaps: ⌘P is ["⌘", "P"], ⇥ is ["⇥"].
    /// The hint bar at the bottom of the panel draws one key per cap, and takes them only from here.
    /// It used to hard-code ⌘P and ⌘⌫, so after a key was changed in Settings the hint was wrong.
    @MainActor var keyCaps: [String] {
        var caps: [String] = []
        if flags.contains(.control) { caps.append("⌃") }
        if flags.contains(.option) { caps.append("⌥") }
        if flags.contains(.shift) { caps.append("⇧") }
        if flags.contains(.command) { caps.append("⌘") }
        caps.append(Self.keyName(keyCode))
        return caps
    }

    /// Displayed in the form ⌘P
    @MainActor var display: String { keyCaps.joined() }

    /// Function keys that need their own name. Every other key is looked up in the current layout to
    /// see which character it types; hard-coding QWERTY would show AZERTY users hints that don't match
    /// the keys they actually press.
    @MainActor private static var namedKeys: [UInt16: String] { [
        36: "↩", 76: "⌅", 48: "⇥", 49: L("Space"), 51: "⌫", 117: "⌦", 53: "⎋",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
    ] }

    /// The character NSMenuItem needs for its right-hand column. Menu keycaps like ⌘⌫ depend on it.
    ///
    /// Function keys need their control character (Return is \r, Delete is backspace); the rest are
    /// looked up in the current keyboard layout, so AZERTY doesn't show the QWERTY key.
    @MainActor var menuKeyEquivalent: String? {
        guard !isUnbound else { return nil }
        switch keyCode {
        case 36, 76: return "\r"
        case 48: return "\t"
        case 49: return " "
        case 51: return "\u{8}"
        case 117: return "\u{7F}"
        case 53: return "\u{1B}"
        default: return KeyboardLayout.character(for: keyCode)?.lowercased()
        }
    }

    @MainActor static func keyName(_ keyCode: UInt16) -> String {
        if let named = namedKeys[keyCode] { return named }
        if let character = KeyboardLayout.character(for: keyCode) {
            return character.uppercased()
        }
        return "#\(keyCode)"
    }
}

/// Actions in the panel. Each action has one key, which can be changed or removed.
///
/// It used to be "choose what Return does, and ⌘↩ does the other one", mixing key-to-action and
/// action-to-key, so changing one thing meant reasoning about two. Now there is only one direction:
/// the action on the left, its key on the right.
/// ↑ ↓ and Esc aren't included: they are standard list interactions, and making them configurable
/// would only lead to wrong key presses.
enum PanelAction: String, CaseIterable, Identifiable, Codable {
    case paste
    /// rawValue keeps the old name so keys the user already changed aren't lost
    case copy = "copyWithoutPasting"
    case pastePlainText
    case cycleFormat
    case togglePin
    case delete

    var id: String { rawValue }

    /// Same name as in the hint bar at the bottom of the panel
    var title: String {
        switch self {
        case .paste: "Paste"
        case .copy: "Copy"
        case .pastePlainText: "Paste as Plain Text"
        case .cycleFormat: "Next Paste Format"
        case .togglePin: "Pin or Unpin"
        case .delete: "Delete Item"
        }
    }

    var defaultShortcut: PanelShortcut? {
        switch self {
        case .paste: PanelShortcut(keyCode: 36, modifiers: [])                      // ↩
        case .copy: PanelShortcut(keyCode: 36, modifiers: .command)                 // ⌘↩
        case .pastePlainText: PanelShortcut(keyCode: 36, modifiers: [.command, .shift])  // ⇧⌘↩
        // ⇥. Focus in the panel always stays in the search field and the list moves with the arrow
        // keys, so Tab is free anyway. Cycling formats fits its meaning, and it's a single key with no
        // modifier.
        case .cycleFormat: PanelShortcut(keyCode: 48, modifiers: [])                // ⇥
        case .togglePin: PanelShortcut(keyCode: 35, modifiers: .command)            // ⌘P
        case .delete: PanelShortcut(keyCode: 51, modifiers: .command)               // ⌘⌫
        }
    }
}
