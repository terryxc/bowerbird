import Carbon
import CoreGraphics

/// Queries about the current keyboard layout.
///
/// Simulating ⌘V can't hard-code key code 9. A CGEvent's virtualKey is a **physical key** number, and
/// 9 is the key where V sits on QWERTY. On Dvorak the same physical key types a different letter, so
/// what we send isn't ⌘V but ⌘ plus some other letter, and pasting silently fails.
/// The right approach is a reverse lookup: "which physical key produces the character v in the
/// current layout".
enum KeyboardLayout {
    /// The localized name of the current input source
    static var localizedName: String {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyLocalizedName) else {
            return ""
        }
        return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
    }

    /// Layouts such as "Dvorak - QWERTY ⌘" and "bépo - Azerty ⌘" switch the whole layout back to
    /// QWERTY while ⌘ is held. Their names all end with ⌘. In that case use the QWERTY key code
    /// directly; a reverse lookup would return the mapping from before ⌘ is held, which is wrong.
    static var commandSwitchesToQWERTY: Bool {
        localizedName.hasSuffix("⌘")
    }

    /// The physical key code of V on QWERTY
    static let qwertyV: CGKeyCode = 9

    /// Reverse-looks up the physical key code that produces the character in the current layout,
    /// falling back to the QWERTY position if not found.
    static func keyCode(for character: Character) -> CGKeyCode {
        if commandSwitchesToQWERTY, character == "v" { return qwertyV }
        return lookup(character) ?? qwertyV
    }

    /// Which character this physical key types in the current layout. Used for shortcut hints.
    static func character(for keyCode: UInt16) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return nil
        }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        let keyboardType = UInt32(LMGetKbdType())
        return data.withUnsafeBytes { buffer -> String? in
            guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else {
                return nil
            }
            var deadKeyState: UInt32 = 0
            var characters = [UniChar](repeating: 0, count: 4)
            var length = 0
            let status = UCKeyTranslate(
                layout, keyCode, UInt16(kUCKeyActionDown), 0, keyboardType,
                UInt32(kUCKeyTranslateNoDeadKeysBit), &deadKeyState,
                characters.count, &length, &characters
            )
            guard status == noErr, length > 0 else { return nil }
            return String(utf16CodeUnits: characters, count: length)
        }
    }

    private static func lookup(_ character: Character) -> CGKeyCode? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return nil
        }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        let keyboardType = UInt32(LMGetKbdType())

        return data.withUnsafeBytes { buffer -> CGKeyCode? in
            guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else {
                return nil
            }
            // 128 physical keys are enough to cover every letter key
            for code in 0..<CGKeyCode(128) {
                var deadKeyState: UInt32 = 0
                var characters = [UniChar](repeating: 0, count: 4)
                var length = 0
                let status = UCKeyTranslate(
                    layout,
                    UInt16(code),
                    UInt16(kUCKeyActionDown),
                    0,                                  // no modifiers
                    keyboardType,
                    UInt32(kUCKeyTranslateNoDeadKeysBit),
                    &deadKeyState,
                    characters.count,
                    &length,
                    &characters
                )
                guard status == noErr, length > 0,
                      let scalar = UnicodeScalar(characters[0]) else { continue }
                if Character(scalar) == character { return code }
            }
            return nil
        }
    }
}

/// Physical positions of the digit keys.
///
/// The panel uses ⌘1 through ⌘9 to paste row N directly, and it used to decide this by converting
/// `charactersIgnoringModifiers` to an integer. That's fine on QWERTY, but on layouts like French
/// AZERTY the digit keys type symbols such as `&é"'(` without Shift, so the conversion fails and the
/// whole set of shortcuts stops working.
///
/// macOS's own menu shortcuts go by physical key position on such layouts, and we follow the same
/// rule: look at the character first (most intuitive when the layout produces digits anyway), then
/// fall back to the physical position.
enum DigitKey {
    /// Key codes of the ANSI number row. Note that the key codes for 5 and 6, and for 7 and 8, are not
    /// in sequential order.
    private static let physical: [UInt16: Int] = [
        18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9,
    ]
    /// Numeric keypad
    private static let numpad: [UInt16: Int] = [
        83: 1, 84: 2, 85: 3, 86: 4, 87: 5, 88: 6, 89: 7, 91: 8, 92: 9,
    ]

    /// Which digit from 1 to 9 this key press corresponds to, or nil if it isn't a digit key
    static func number(keyCode: UInt16, characters: String?) -> Int? {
        if let characters, let n = Int(characters), (1...9).contains(n) {
            return n
        }
        return physical[keyCode] ?? numpad[keyCode]
    }
}
