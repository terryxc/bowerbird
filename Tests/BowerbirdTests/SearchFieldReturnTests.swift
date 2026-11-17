import AppKit
import Combine
import SwiftUI
import XCTest
@testable import Bowerbird
@testable import BowerbirdCore

/// Return in the search field is how an item gets pasted. It goes through the text field's onSubmit,
/// not the key monitor, so anything placed next to the field in the search row can get in its way.
/// This drives the real view in a window with a real key event.
@MainActor
final class SearchFieldReturnTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        await MainActor.run {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("bowerbird-return-\(UUID().uuidString)", isDirectory: true)
        }
    }

    override func tearDown() async throws {
        await MainActor.run { try? FileManager.default.removeItem(at: root) }
    }

    func testReturnInTheSearchFieldActivatesTheSelectedItem() throws {
        let store = try HistoryStore(databaseURL: nil,
                                     imagesDirectory: root.appendingPathComponent("images", isDirectory: true))
        try store.record(ClipCapture(assets: [.init(type: .string, data: Data("一条".utf8))], kind: .text, text: "一条"),
                         sourceBundleID: nil)
        let model = PanelModel(store: store, permission: Granted(), changeCount: { 1 })
        var activations = 0
        model.onActivate = { _, _, _ in activations += 1 }
        model.onDismiss = {}

        let host = NSHostingView(rootView: PanelView(model: model))
        host.frame = NSRect(x: 0, y: 0, width: 760, height: 480)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        model.reset()
        pump(0.8)
        XCTAssertEqual(model.items.count, 1, "precondition: the item is listed")

        // No manual focusing: the view must put the caret in the field itself when the panel opens,
        // the way it does in the app (onAppear and the focus token)
        XCTAssertTrue(window.firstResponder is NSTextView, "the search field has focus on open; got \(String(describing: window.firstResponder))")

        let ret = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil,
            characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        NSApp.sendEvent(ret)   // the real route: key equivalents are tried before the first responder
        pump(0.3)

        XCTAssertEqual(activations, 1, "Return must activate the selected item")

        window.orderOut(nil)
    }

    /// The kind menu is a pop-up button and keeps focus after a pick. Return must still paste: the
    /// controller's key handler performs it and hands the caret back to the field. The real panel
    /// and controller are used; the handler is called directly because the key monitor only runs
    /// while the panel is the key window, which a test process cannot make it.
    func testReturnStillPastesAfterTheKindMenuTookFocus() throws {
        let store = try HistoryStore(databaseURL: nil,
                                     imagesDirectory: root.appendingPathComponent("images", isDirectory: true))
        try store.record(ClipCapture(assets: [.init(type: .string, data: Data("一条".utf8))], kind: .text, text: "一条"),
                         sourceBundleID: nil)
        let model = PanelModel(store: store, permission: Granted(), changeCount: { 1 })
        var activations = 0
        model.onActivate = { _, _, _ in activations += 1 }
        model.onDismiss = {}
        let controller = PanelController(model: model)
        controller.show()
        pump(0.8)
        XCTAssertEqual(model.items.count, 1, "precondition: the item is listed")
        let panel = controller.panel
        let content = try XCTUnwrap(panel.contentView)

        // Focus starts in the field, and one key press lets the controller note where the field is
        let field = try XCTUnwrap(textField(in: content))
        panel.makeFirstResponder(field)
        XCTAssertTrue(panel.firstResponder is NSTextView, "precondition: the field editor has focus")
        controller.handle(try key(0x7B, "\u{F702}", in: panel))   // ←, harmless in an empty field

        // The user clicks the kind menu: its pop-up button becomes first responder
        let popup = try XCTUnwrap(popUpButton(in: content), "the kind menu is a pop-up button")
        XCTAssertTrue(panel.makeFirstResponder(popup))
        XCTAssertFalse(panel.firstResponder is NSTextView, "precondition: focus left the field")

        XCTAssertTrue(controller.handle(try key(36, "\r", in: panel)), "Return is taken by the handler")
        pump(0.1)

        XCTAssertEqual(activations, 1, "Return must still activate the selected item")
        XCTAssertTrue(panel.firstResponder is NSTextView, "and the caret is back in the field")
        controller.hide()
    }

    private func key(_ code: UInt16, _ chars: String, in window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil,
            characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code))
    }

    private func popUpButton(in view: NSView) -> NSPopUpButton? {
        for sub in view.subviews {
            if let button = sub as? NSPopUpButton { return button }
            if let found = popUpButton(in: sub) { return found }
        }
        return nil
    }

    private func textField(in view: NSView) -> NSTextField? {
        for sub in view.subviews {
            if let field = sub as? NSTextField, field.isEditable { return field }
            if let found = textField(in: sub) { return found }
        }
        return nil
    }

    private func pump(_ s: TimeInterval) {
        let end = Date().addingTimeInterval(s)
        while Date() < end { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
    }
}

@MainActor
private final class Granted: AccessibilityState {
    var isTrusted = true
    var isTrustedChanged: AnyPublisher<Bool, Never> { Just(true).eraseToAnyPublisher() }
    func request() {}
    func refresh() {}
}
