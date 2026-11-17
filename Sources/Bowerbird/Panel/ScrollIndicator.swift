import SwiftUI

/// A snapshot of the scroll content's geometry
struct ScrollGeometrySnapshot: Equatable {
    var offset: CGFloat = 0
    var contentHeight: CGFloat = 0

    static let zero = ScrollGeometrySnapshot()
}

/// Relay for scroll geometry.
///
/// The original plan was to report the content height with a preference, but **preferences set
/// inside SwiftUI's `.background()` and `.overlay()` don't propagate upward**. Measured: the
/// container height came through fine and the content height was always 0.
/// So instead an object is shared explicitly, held by both the reader and the writer.
@MainActor
final class ScrollTracker: ObservableObject {
    @Published private(set) var snapshot = ScrollGeometrySnapshot.zero
    /// When it last changed; decides when the scroll indicator fades out
    @Published private(set) var lastChange = Date.distantPast

    /// Both sides report here: the list measures in SwiftUI coordinate space
    /// (ScrollGeometryReporter), and the preview asks NSScrollView directly
    /// (PreviewTextView.Coordinator).
    func update(_ new: ScrollGeometrySnapshot) {
        guard new != snapshot else { return }
        snapshot = new
        lastChange = Date()
    }
}

/// Sits behind the scroll content to measure its size. The enclosing scroll view must declare a
/// coordinate space with the same name.
/// Only the list still uses it: since the preview body moved to NSTextView, that side asks AppKit
/// for its geometry directly.
struct ScrollGeometryReporter: View {
    let space: String
    let tracker: ScrollTracker
    /// The margin the scroll view keeps above and below (`contentMargins`). It isn't part of the
    /// content, so it can't be measured here and has to be added back. Otherwise, when the content
    /// is only ten or so points taller than the container, the indicator thinks it isn't needed.
    var verticalMargin: CGFloat = 0

    var body: some View {
        GeometryReader { geometry in
            let snapshot = ScrollGeometrySnapshot(
                offset: -geometry.frame(in: .named(space)).minY + verticalMargin,
                contentHeight: geometry.size.height + verticalMargin * 2
            )
            Color.clear
                .onAppear { tracker.update(snapshot) }
                .onChange(of: snapshot) { _, new in tracker.update(new) }
        }
    }
}

/// A custom-drawn thin scroll indicator.
///
/// Why not the system one: with "Show scroll bars" set to "Automatically", a machine with a mouse
/// attached uses the legacy style, a permanent full-height track that looks jarring on a
/// translucent floating panel. Forcing `NSScrollView.scrollerStyle = .overlay` was tried, and
/// SwiftUI switched it back in a later layout pass.
///
/// So we draw one ourselves, going for Raycast's look: a thin rounded bar hugging the right edge,
/// fading in while scrolling and out about a second after it stops, taking no layout width.
/// `onScrollGeometryChange` requires macOS 15 and our minimum is 14, so we measure with a
/// coordinate space ourselves.
struct ScrollIndicator: ViewModifier {
    /// The SwiftUI path needs a coordinate space name for ScrollGeometryReporter;
    /// the AppKit path already knows where it's scrolled to, so it passes nil.
    let space: String?
    @ObservedObject var tracker: ScrollTracker

    @State private var containerHeight: CGFloat = 0
    @State private var visible = false
    @State private var hideWork: DispatchWorkItem?

    private var contentHeight: CGFloat { tracker.snapshot.contentHeight }
    /// The indicator is only needed when the content is taller than the container
    private var needed: Bool { contentHeight > containerHeight + 1 }
    /// The thumb's share of the track, with a lower bound so it doesn't shrink to a hairline when
    /// the content is very long
    private var thumbFraction: CGFloat {
        max(0.08, min(1, containerHeight / max(contentHeight, 1)))
    }
    private var progress: CGFloat {
        let scrollable = max(contentHeight - containerHeight, 1)
        return min(max(tracker.snapshot.offset / scrollable, 0), 1)
    }

    func body(content: Content) -> some View {
        content
            .modifier(OptionalCoordinateSpace(name: space))
            .background(
                GeometryReader { geometry in
                    Color.clear
                        .onAppear { containerHeight = geometry.size.height }
                        .onChange(of: geometry.size.height) { _, new in containerHeight = new }
                }
            )
            .overlay(alignment: .trailing) { indicator }
            .onChange(of: tracker.lastChange) { _, _ in flash() }
    }

    @ViewBuilder
    private var indicator: some View {
        if needed {
            GeometryReader { geometry in
                let track = geometry.size.height - PanelMetrics.scrollIndicatorInset * 2
                let thumb = max(PanelMetrics.scrollIndicatorMinLength, track * thumbFraction)
                Capsule()
                    .fill(Color.primary.opacity(0.26))
                    .frame(width: PanelMetrics.scrollIndicatorWidth, height: thumb)
                    .offset(y: PanelMetrics.scrollIndicatorInset + (track - thumb) * progress)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.trailing, PanelMetrics.scrollIndicatorInset)
            }
            .opacity(visible ? 1 : 0)
            .animation(.easeOut(duration: visible ? 0.1 : 0.35), value: visible)
            .allowsHitTesting(false)
        }
    }

    private func flash() {
        visible = true
        hideWork?.cancel()
        let work = DispatchWorkItem { visible = false }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: work)
    }
}

/// `coordinateSpace(name:)` has no "don't declare one" option, so wrap it.
private struct OptionalCoordinateSpace: ViewModifier {
    let name: String?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let name { content.coordinateSpace(name: name) } else { content }
    }
}

extension View {
    /// Adds a custom-drawn thin scroll indicator to a SwiftUI scroll view.
    /// The scroll content needs a `ScrollGeometryReporter` with the same space and tracker as its
    /// background.
    func thinScrollIndicator(space: String, tracker: ScrollTracker) -> some View {
        modifier(ScrollIndicator(space: space, tracker: tracker))
    }

    /// The variant whose geometry is already reported from the AppKit side (see PreviewTextView);
    /// no coordinate space needed.
    func thinScrollIndicator(tracker: ScrollTracker) -> some View {
        modifier(ScrollIndicator(space: nil, tracker: tracker))
    }
}
