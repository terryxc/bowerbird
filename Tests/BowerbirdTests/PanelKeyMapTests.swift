import AppKit
import Combine
import SwiftUI
import XCTest
@testable import Bowerbird
@testable import BowerbirdCore

/// The fixed keys of the panel, fed to the real controller's key handler as real key events. The
/// two bugs found by hand (the selection after a search, Return with the kind menu focused) both
/// lived in this layer, which had no tests; the model-level tests could not see them.
@MainActor
final class PanelKeyMapTests: XCTestCase {
    private var root: URL!
    private var store: HistoryStore!
    private var model: PanelModel!
    private var controller: PanelController!
    private var activated: [Int64?] = []

    override func setUp() async throws {
        try await MainActor.run {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("bowerbird-keys-\(UUID().uuidString)", isDirectory: true)
            store = try HistoryStore(databaseURL: nil,
                                     imagesDirectory: root.appendingPathComponent("images", isDirectory: true))
            for i in 1...30 {
                try store.record(ClipCapture(assets: [.init(type: .string, data: Data("row \(i)".utf8))],
                                             kind: .text, text: "row \(i)"), sourceBundleID: nil)
            }
            model = PanelModel(store: store, permission: Granted(), changeCount: { 1 })
            activated = []
            model.onActivate = { [weak self] item, _, _ in self?.activated.append(item.id) }
            model.onDismiss = {}
            controller = PanelController(model: model)
        }
    }

    /// Opens the panel and waits for the list. Done from the (synchronous, main-actor) test body:
    /// pumping the run loop from an async setUp does not drain the main dispatch queue, so the
    /// load never landed and the first key press found an empty list.
    private func openPanel() {
        controller.show()
        pump(until: { model.items.count == 30 })
        XCTAssertEqual(model.items.count, 30, "precondition: the list is loaded")
    }

    override func tearDown() async throws {
        await MainActor.run {
            controller.hide()
            try? FileManager.default.removeItem(at: root)
        }
    }

    func testArrowsMoveTheSelectionOneRow() throws {
        openPanel()
        try press(125); try press(125); try press(125)
        XCTAssertEqual(model.selectedIndex, 3)
        try press(126)
        XCTAssertEqual(model.selectedIndex, 2)
    }

    /// After clicking the kind menu or the preview, focus is not in the search field. Real arrow
    /// keys carry a private-use character (↓ is U+F701); taken for typing, the first press only
    /// handed focus back and the selection stayed put.
    func testArrowsNavigateWhenFocusIsOutsideTheSearchField() throws {
        openPanel()
        // One key with focus in the field, so the controller knows which view the field is
        _ = controller.handle(try key(0, "a", mods: []))
        let content = try XCTUnwrap(controller.panel.contentView)
        let popup = try XCTUnwrap(popUpButton(in: content), "the kind menu is a pop-up button")
        XCTAssertTrue(controller.panel.makeFirstResponder(popup))

        try press(125, "\u{F701}", mods: [.function, .numericPad])
        XCTAssertEqual(model.selectedIndex, 1)
        try press(119, "\u{F72B}", mods: .function)   // End
        XCTAssertEqual(model.selectedIndex, 29)
    }

    private func popUpButton(in view: NSView) -> NSPopUpButton? {
        for sub in view.subviews {
            if let button = sub as? NSPopUpButton { return button }
            if let found = popUpButton(in: sub) { return found }
        }
        return nil
    }

    func testHomeAndEndJumpToTheEnds() throws {
        openPanel()
        try press(119)                       // End
        XCTAssertEqual(model.selectedIndex, 29)
        try press(115)                       // Home
        XCTAssertEqual(model.selectedIndex, 0)
        try press(125, mods: .command)       // ⌘↓
        XCTAssertEqual(model.selectedIndex, 29)
        try press(126, mods: .command)       // ⌘↑
        XCTAssertEqual(model.selectedIndex, 0)
    }

    func testPageKeysMoveByAScreen() throws {
        openPanel()
        let page = AppSettings.shared.panelSize.visibleRows
        try press(121)                       // Page Down
        XCTAssertEqual(model.selectedIndex, min(page, 29))
        try press(116)                       // Page Up
        XCTAssertEqual(model.selectedIndex, 0)
    }

    func testCommandDigitPastesThatRow() throws {
        openPanel()
        try press(18, "1", mods: .command)   // ⌘1
        try press(20, "3", mods: .command)   // ⌘3
        XCTAssertEqual(activated, [model.items[0].id, model.items[2].id])
    }

    /// First Esc clears the search and keeps the panel; the second closes it
    func testEscapeClearsTheSearchBeforeClosing() throws {
        openPanel()
        model.query = "row"
        try press(53)
        XCTAssertEqual(model.query, "")
        XCTAssertTrue(controller.panel.isVisible, "a search was cleared, the panel stays")
        try press(53)
        XCTAssertFalse(controller.panel.isVisible, "nothing left to clear, so Esc closes")
    }

    /// Keys the panel does not take must pass through to the search field, or typing would break
    func testOrdinaryTypingIsNotIntercepted() throws {
        openPanel()
        XCTAssertFalse(controller.handle(try key(0, "a", mods: [])), "a letter goes to the field")
        XCTAssertFalse(controller.handle(try key(49, " ", mods: [])), "so does a space")
    }

    // MARK: Helpers

    private func press(_ code: UInt16, _ chars: String = "", mods: NSEvent.ModifierFlags = []) throws {
        XCTAssertTrue(controller.handle(try key(code, chars, mods: mods)), "key \(code) is one the panel takes")
        pump(0.05)
    }

    private func key(_ code: UInt16, _ chars: String, mods: NSEvent.ModifierFlags) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: controller.panel.windowNumber, context: nil,
            characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code))
    }

    private func pump(_ s: TimeInterval) {
        let end = Date().addingTimeInterval(s)
        while Date() < end { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
    }

    private func pump(until done: () -> Bool) {
        let deadline = Date().addingTimeInterval(2)
        while !done(), Date() < deadline { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
    }
}

@MainActor
private final class Granted: AccessibilityState {
    var isTrusted = true
    var isTrustedChanged: AnyPublisher<Bool, Never> { Just(true).eraseToAnyPublisher() }
    func request() {}
    func refresh() {}
}
