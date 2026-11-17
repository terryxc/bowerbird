import XCTest
import AppKit
import Combine
import SwiftUI
@testable import Bowerbird

/// The boundary between the preview body's NSTextView and SwiftUI.
@MainActor
final class PreviewTextViewTests: XCTestCase {
    private struct Host: View {
        let content: NSAttributedString
        let id: String
        let tracker: ScrollTracker
        var body: some View {
            PreviewTextView(content: content, contentID: id, tracker: tracker)
                .frame(width: 420, height: 320)
        }
    }

    /// Swapping content must not change the tracker's @Published during SwiftUI's update pass.
    ///
    /// setAttributedString is called in updateNSView, and AppKit synchronously changes the height and
    /// posts frameDidChange in the same call; reporting right there is "modifying observable state
    /// during a view update". Before the fix, each content swap measured two synchronous publishes;
    /// after it, zero (the total is still two, just deferred by one turn).
    func testSwappingContentPublishesNothingDuringTheUpdatePass() {
        let tracker = ScrollTracker()
        var duringUpdate = 0, total = 0
        var inUpdate = false
        var bag = Set<AnyCancellable>()
        tracker.objectWillChange.sink { _ in total += 1; if inUpdate { duringUpdate += 1 } }.store(in: &bag)

        let long = NSAttributedString(string: String(repeating: "一段够长的正文。\n", count: 600),
                                      attributes: [.font: NSFont.systemFont(ofSize: 13)])
        let short = NSAttributedString(string: "✅", attributes: [.font: NSFont.systemFont(ofSize: 13)])
        let host = NSHostingView(rootView: Host(content: short, id: "short", tracker: tracker))
        host.frame = NSRect(x: 0, y: 0, width: 420, height: 320)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFront(nil)
        pump(0.4)
        total = 0; duringUpdate = 0

        for (content, id) in [(long, "long"), (short, "short2"), (long, "long2")] {
            inUpdate = true
            host.rootView = Host(content: content, id: id, tracker: tracker)
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            inUpdate = false
            pump(0.3)
        }
        XCTAssertEqual(duringUpdate, 0, "the tracker must not be touched during the update pass")
        XCTAssertGreaterThan(total, 0, "but it must still report after deferring, or the scroller won't know how tall the content is")
        window.orderOut(nil)
    }

    private func pump(_ s: TimeInterval) {
        let end = Date().addingTimeInterval(s)
        while Date() < end { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
    }
}
