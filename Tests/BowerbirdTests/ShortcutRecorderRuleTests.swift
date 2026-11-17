import AppKit
import KeyboardShortcuts
import XCTest
@testable import Bowerbird

/// Which keys count as typing keys, the ones that need ⌘, ⌥ or ⌃ to become a shortcut
@MainActor
final class ShortcutRecorderRuleTests: XCTestCase {
    private func key(_ characters: String, code: UInt16) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                         context: nil, characters: characters, charactersIgnoringModifiers: characters,
                         isARepeat: false, keyCode: code)!
    }

    func testLettersDigitsAndSpaceType() {
        XCTAssertTrue(ShortcutRecorder.typesCharacter(key("a", code: 0)))
        XCTAssertTrue(ShortcutRecorder.typesCharacter(key("1", code: 18)))
        XCTAssertTrue(ShortcutRecorder.typesCharacter(key(" ", code: 49)))
        XCTAssertTrue(ShortcutRecorder.typesCharacter(key("/", code: 44)))
    }

    func testReturnTabDeleteArrowsAndFunctionKeysDoNot() {
        XCTAssertFalse(ShortcutRecorder.typesCharacter(key("\r", code: 36)))
        XCTAssertFalse(ShortcutRecorder.typesCharacter(key("\t", code: 48)))
        XCTAssertFalse(ShortcutRecorder.typesCharacter(key("\u{7F}", code: 51)))
        XCTAssertFalse(ShortcutRecorder.typesCharacter(key(String(UnicodeScalar(NSUpArrowFunctionKey)!), code: 126)))
        XCTAssertFalse(ShortcutRecorder.typesCharacter(key(String(UnicodeScalar(NSF5FunctionKey)!), code: 96)))
    }

    /// The global hotkey is drawn with our own keycaps. The library's description of Space reads its
    /// resource bundle, which the packaged app doesn't carry, and crashed Settings on other Macs.
    @MainActor func testGlobalHotkeyWithSpaceIsDrawnWithOurKeycaps() {
        let shortcut = PanelShortcut(KeyboardShortcuts.Shortcut(.space, modifiers: [.option]))
        XCTAssertEqual(shortcut.keyCode, 49)
        XCTAssertEqual(shortcut.keyCaps, ["⌥", L("Space")])
    }
}
