import XCTest
import AppKit
import Combine
import SwiftUI
import BowerbirdCore
@testable import Bowerbird

/// The space above the list: a fresh open and "scrolled away, then back to the first item" must land
/// in the same place.
///
/// The space used to be padding on the content. When the selection returns to the first item,
/// `scrollTo` scrolls that item to the top, and since the padding is part of the content it scrolls
/// out along with it. So after reopening the panel the list sat 6 points higher than on a fresh open
/// (measured from screenshots: section header at 67 points vs 61 points).
/// The space is now the scroll view's `contentMargins`, which scrollTo respects.
@MainActor
final class ListTopInsetTests: XCTestCase {
    private func listScrollView(in view: NSView) -> NSScrollView? {
        for sub in view.subviews {
            if let s = sub as? NSScrollView, !(s.documentView is NSTextView) { return s }
            if let f = listScrollView(in: sub) { return f }
        }
        return nil
    }

    func testReturningToTheFirstItemLandsWhereAFreshOpenDoes() throws {
        let store = try HistoryStore(databaseURL: nil,
                                     imagesDirectory: FileManager.default.temporaryDirectory
                                        .appendingPathComponent("bowerbird-top-\(UUID().uuidString)"))
        for i in 0..<100 {
            _ = try store.record(ClipCapture(assets: [.init(type: .string, data: Data("row \(i)".utf8))],
                                             kind: .text, text: "row \(i)"),
                                 sourceBundleID: nil, at: Date().addingTimeInterval(Double(-i)))
        }
        let model = PanelModel(store: store, permission: NeverAsked(), changeCount: { 1 })
        let host = NSHostingView(rootView: PanelView(model: model))
        host.frame = NSRect(x: 0, y: 0, width: 760, height: 480)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFront(nil)
        model.reset()
        pump(0.8)
        let scroll = try XCTUnwrap(listScrollView(in: host))
        let fresh = scroll.contentView.bounds.origin.y

        model.selectedIndex = 40
        pump(0.5)
        XCTAssertGreaterThan(scroll.contentView.bounds.origin.y, fresh + 100, "precondition: it really did scroll down")

        model.selectedIndex = 0
        pump(0.5)
        XCTAssertEqual(scroll.contentView.bounds.origin.y, fresh, accuracy: 0.5,
                       "returning to the first item must land where a fresh open does (was off by 6 points before the fix)")
        window.orderOut(nil)
    }

    private func pump(_ s: TimeInterval) {
        let end = Date().addingTimeInterval(s)
        while Date() < end { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
    }
}

@MainActor
private final class NeverAsked: AccessibilityState {
    var isTrusted = true
    var isTrustedChanged: AnyPublisher<Bool, Never> { Just(true).eraseToAnyPublisher() }
    func request() {}
    func refresh() {}
}
