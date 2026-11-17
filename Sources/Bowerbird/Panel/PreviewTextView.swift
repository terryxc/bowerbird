import AppKit
import SwiftUI

/// The preview body is drawn with an NSTextView, not a SwiftUI `Text`.
///
/// The switch was driven by measurement: a SwiftUI `Text` has to lay out the **whole** string to know
/// its own height, even when only thirty lines are visible. Previews go up to 20,000 characters, so
/// "press ↓ to move from a short clip to a long one" took 39 ms. That is more than two frames, a
/// clearly felt hitch.
///
/// How it was pinned down: temporarily cutting the limit to 800 characters dropped that step from
/// 38.6 ms to 4.7 ms, while disabling text selection or removing the character count line below
/// changed nothing. All the cost was in layout.
///
/// Time to move the selection from a short clip to a long one in a 400-clip panel (the panel's own
/// floor is 2.7 ms):
///
/// | Body length | SwiftUI Text | NSTextView |
/// | --- | --- | --- |
/// | 500 chars | 3.6 ms | 3.9 ms |
/// | 3,000 chars | 8.1 ms | 4.2 ms |
/// | 10,000 chars | 20.9 ms | 6.7 ms |
/// | 20,000 chars | 39.3 ms | 10.5 ms |
///
/// It is still linear, just three to four times cheaper per character. NSTextView has to give the
/// scroll view a definite document height, so layout can't be avoided; `allowsNonContiguousLayout`
/// lets it estimate.
///
/// Two things got cheaper along the way: rich text no longer has to be converted to
/// `AttributedString` (1.7 ms for 20,000 characters, on every selection change), and text selection,
/// ⌘C, double-click to select a word and right-click Look Up are built-in NSTextView behaviour we
/// don't have to handle.
struct PreviewTextView: NSViewRepresentable {
    /// The content to draw, already styled
    let content: NSAttributedString
    /// The identity of this content. The content is only replaced when this changes. Comparing
    /// 20,000 characters is not cheap in itself, and `updateNSView` is called many times during layout.
    let contentID: String
    /// Scroll geometry is reported here; the custom thin scroller reads the same object
    let tracker: ScrollTracker

    func makeCoordinator() -> Coordinator { Coordinator(tracker: tracker) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        // Give it its own layer.
        //
        // This AppKit view sits under an NSHostingView, which is a layer-backed tree. Without
        // explicitly asking for a layer, it draws into an ancestor's layer, and after the content
        // shrinks nobody is responsible for redrawing the area it vacated, so stale text stays on
        // screen. A screenshot of this was reported: the preview held a single emoji,
        // with leftover glyphs from the previous rich-text clip to its right. (I couldn't reproduce
        // it with any of four combinations, so this fix is based on the symptom, not measured; but
        // "an AppKit view embedded in a layer-backed tree should have its own layer" is the right
        // thing to do anyway, without waiting for a repro.)
        scroll.wantsLayer = true
        scroll.drawsBackground = false
        // No system scrollers at all; the panel uses the custom thin one everywhere (see ScrollIndicator)
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.automaticallyAdjustsContentInsets = false

        // Use TextKit 1 with allowsNonContiguousLayout on.
        //
        // This is the only switch that lets NSTextView "estimate a height first and lay out only the
        // part it actually draws". TextKit 2 has no equivalent knob: NSTextView still needs a
        // definite document height, so the whole text gets laid out anyway. Measured on switching to
        // a 20,000-character clip: TextKit 1 with this switch takes 10.5 ms, TextKit 2 takes 14.4 ms.
        // So this deliberately picks the older stack.
        let textView = NSTextView(usingTextLayoutManager: false)
        textView.layoutManager?.allowsNonContiguousLayout = true
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        // Spell out how large and how small it can get. Otherwise the default maxSize is (0, 1e7):
        // the height is enough, but the width is 0. The width then relies entirely on
        // autoresizingMask pulling it from the superview, so layout only works because a few
        // defaults happen to line up. This is the standard setup for a scrollable text view in the
        // AppKit docs; write it out instead of betting on defaults.
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        // Zero insets: the preview's margins come from the outer padding; another layer here would misalign
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        scroll.documentView = textView

        context.coordinator.observe(scroll)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView else { return }
        guard context.coordinator.contentID != contentID else { return }
        context.coordinator.contentID = contentID
        textView.textStorage?.setAttributedString(content)
        // New content goes back to the top. Where the previous clip was scrolled has nothing to do with
        // this one.
        textView.scroll(NSPoint(x: 0, y: 0))
        // Redraw the whole thing once. Non-contiguous layout only lays out on demand, and after a
        // content change it won't take care of "the area the previous clip used but this one doesn't".
        textView.needsDisplay = true
        scroll.needsDisplay = true
        // Don't report directly here. This method runs inside SwiftUI's update pass, and report
        // changes the tracker's @Published, which is "modifying observable state during a view update".
        // Measured: every content change published twice synchronously inside the update pass.
        // Height and scroll-position changes are reported through notifications anyway, and that
        // path defers publishing by one turn.
    }

    /// Moves AppKit's scroll position and content height onto the ScrollTracker.
    ///
    /// The SwiftUI scroll view path measures coordinate spaces through `ScrollGeometryReporter`.
    /// Here the content is owned by NSScrollView, so we just ask it. Both paths feed the same object,
    /// so the thin scroller doesn't need a single line changed for this.
    @MainActor
    final class Coordinator: NSObject {
        private let tracker: ScrollTracker
        private weak var scroll: NSScrollView?
        var contentID: String?

        init(tracker: ScrollTracker) {
            self.tracker = tracker
        }

        func observe(_ scroll: NSScrollView) {
            self.scroll = scroll
            scroll.contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                self, selector: #selector(geometryChanged),
                name: NSView.boundsDidChangeNotification, object: scroll.contentView)
            // When the content changes or the panel changes width, the height changes and the scroller
            // length must follow
            scroll.documentView?.postsFrameChangedNotifications = true
            NotificationCenter.default.addObserver(
                self, selector: #selector(geometryChanged),
                name: NSView.frameDidChangeNotification, object: scroll.documentView)
        }

        @objc private func geometryChanged(_ notification: Notification) {
            MainActor.assumeIsolated { scheduleReport() }
        }

        /// Batch until the next runloop turn and report at most once per turn.
        ///
        /// The reason was measured: setAttributedString is called inside SwiftUI's update pass, and
        /// AppKit synchronously changes the text view's height and posts frameDidChange in the same
        /// call, so every content change made the tracker's @Published fire twice synchronously
        /// **inside the update pass**. That is "modifying observable state during a view update".
        /// After deferring by one turn it still fires twice, but zero of those land inside the update
        /// pass. Reporting once per turn is a side benefit: when height and scroll position both
        /// change in the same turn, one report is enough.
        private var reportScheduled = false

        private func scheduleReport() {
            guard !reportScheduled else { return }
            reportScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.reportScheduled = false
                self.report()
            }
        }

        private func report() {
            guard let scroll else { return }
            tracker.update(ScrollGeometrySnapshot(
                offset: scroll.contentView.bounds.origin.y,
                contentHeight: scroll.documentView?.frame.height ?? 0))
        }
    }
}
