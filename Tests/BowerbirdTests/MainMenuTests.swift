import AppKit
import XCTest
@testable import Bowerbird

/// The two modes of the main menu.
///
/// `.accessory`: only "Edit". Without it ⌘C / ⌘V / ⌘A are dead in the panel,
/// and there must not be an extra global ⌘Q; quitting belongs to the menu bar icon's dropdown.
/// `.regular`: installed only while the settings window is open, adding the app menu and the "Window"
/// menu so that ⌘W / ⌘Q have something to handle them.
@MainActor
final class MainMenuTests: XCTestCase {
    private var original: NSMenu?

    // XCTest's synchronous setUp and tearDown are nonisolated on Xcode 16, so the async variants hop
    // onto the main actor explicitly; this compiles on both toolchains
    override func setUp() async throws {
        await MainActor.run {
            // Nobody has created an NSApplication in the test process, so NSApp is nil; touching shared
            // creates it
            _ = NSApplication.shared
            original = NSApp.mainMenu
        }
    }

    override func tearDown() async throws {
        await MainActor.run {
            MainMenu.install(.accessory)
            NSApp.mainMenu = original
        }
    }

    private var allItems: [NSMenuItem] {
        (NSApp.mainMenu?.items ?? []).flatMap { $0.submenu?.items ?? [] }
    }

    private func item(_ key: String, _ mods: NSEvent.ModifierFlags = [.command]) -> NSMenuItem? {
        allItems.first { $0.keyEquivalent == key && $0.keyEquivalentModifierMask == mods }
    }

    /// None of the four keys may be missing, and each must be plain ⌘ plus that letter; same in both
    /// modes
    func testTheFourEditKeysAreBoundInBothModes() {
        for mode in [MainMenu.Mode.accessory, .regular] {
            MainMenu.install(mode)
            for key in ["c", "v", "x", "a"] {
                XCTAssertNotNil(item(key), "\(mode): ⌘\(key.uppercased()) is not bound")
            }
            XCTAssertEqual(item("z", [.command, .shift])?.action, Selector(("redo:")), "\(mode): Redo should be on ⇧⌘Z")
        }
    }

    /// Every Edit item names a selector that something in a text field's responder chain answers.
    ///
    /// Undo and Redo once used `#selector(UndoManager.undo)`, which is `undo` without a colon. Nothing
    /// in the chain implements that, so both items were permanently disabled and ⌘Z did nothing.
    func testEveryEditActionHasARealResponder() {
        MainMenu.install(.accessory)
        let textView = NSTextView()
        let window = NSWindow()
        for item in allItems where !item.isSeparatorItem {
            let action = try! XCTUnwrap(item.action)
            XCTAssertTrue(textView.responds(to: action) || window.responds(to: action),
                          "nothing answers \(NSStringFromSelector(action)) for \"\(item.title)\"")
        }
    }

    /// Actions are sent to nil: edit commands land on the focused text, Close lands on the key window,
    /// and Settings travels all the way up to AppDelegate
    func testActionsGoDownTheResponderChain() {
        MainMenu.install(.regular)
        for item in allItems where !item.isSeparatorItem {
            XCTAssertNil(item.target, "\"\(item.title)\" shouldn't hard-wire its target")
            XCTAssertNotNil(item.action)
        }
    }

    /// Normally there's only "Edit", with no global ⌘Q
    func testAccessoryModeIsEditOnly() {
        MainMenu.install(.accessory)
        XCTAssertEqual(NSApp.mainMenu?.items.count, 1)
        XCTAssertNil(item("q"), "there shouldn't be an extra global ⌘Q")
        XCTAssertNil(item("w"))
    }

    /// While the settings window is open: the app menu (About, Settings… ⌘,, Hide ⌘H, Quit ⌘Q) and
    /// "Window" (Close ⌘W, Minimize ⌘M)
    func testRegularModeHasTheStandardMenus() {
        MainMenu.install(.regular)
        XCTAssertEqual(NSApp.mainMenu?.items.count, 3)
        XCTAssertEqual(item("q")?.action, #selector(NSApplication.terminate(_:)))
        XCTAssertEqual(item(",")?.action, #selector(AppDelegate.showSettings(_:)))
        XCTAssertEqual(item("h")?.action, #selector(NSApplication.hide(_:)))
        XCTAssertEqual(item("w")?.action, #selector(NSWindow.performClose(_:)))
        XCTAssertEqual(item("m")?.action, #selector(NSWindow.performMiniaturize(_:)))
        XCTAssertEqual(allItems.first { $0.action == #selector(AppDelegate.showAbout(_:)) }?.keyEquivalent, "")
    }

    /// After the settings window closes and we switch back, ⌘Q must go away with it
    func testSwitchingBackDropsQuit() {
        MainMenu.install(.regular)
        XCTAssertNotNil(item("q"))
        MainMenu.install(.accessory)
        XCTAssertNil(item("q"))
        XCTAssertEqual(MainMenu.mode, .accessory)
    }
}
