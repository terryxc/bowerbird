import AppKit

/// Where the panel appears.
///
/// There's no "below the menu bar icon" option. It only makes sense when summoned by clicking the
/// status item, but the panel is normally summoned with ⇧⌘V: aligning to the icon would fling the
/// panel to the top-right corner of the menu bar's screen every time, as far as possible from where
/// you're typing, and with multiple displays it would always go to the one with the menu bar.
///
/// There used to be a third choice, "where I left it", with the panel draggable by its footer. It
/// went with the dragging: a panel that is summoned, used for a second and dismissed
/// has no position worth remembering, and the two choices here cover it.
// Order is the order in the pop-up: the default first.
enum PanelPosition: String, CaseIterable, Identifiable, Codable {
    case center
    case cursor

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .center: "Screen Center"
        case .cursor: "At the Pointer"
        }
    }

    /// Computes where the panel's bottom-left corner goes. size is the panel size.
    ///
    /// The result is always clamped back into the screen's visible area; otherwise following the
    /// pointer easily pushes the panel off screen.
    func origin(for size: CGSize) -> CGPoint {
        origin(for: size, mouse: NSEvent.mouseLocation,
               screens: NSScreen.screens.map { Display(frame: $0.frame, visible: $0.visibleFrame) },
               fallback: NSScreen.main.map { Display(frame: $0.frame, visible: $0.visibleFrame) })
    }

    /// The screen geometry is passed in so the choice of screen can be tested without real displays.
    /// Both modes use the display the pointer is on.
    struct Display {
        let frame: CGRect
        let visible: CGRect
    }

    func origin(for size: CGSize, mouse: CGPoint, screens: [Display], fallback: Display?) -> CGPoint {
        // At the top or right edge the pointer's coordinate equals the frame's max, which `contains`
        // counts as outside, so no screen matched and the panel jumped to the main display. Take the
        // nearest screen instead.
        let screen = screens.first { $0.frame.contains(mouse) }
            ?? screens.min { Self.distance(from: mouse, to: $0.frame) < Self.distance(from: mouse, to: $1.frame) }
            ?? fallback
        guard let visible = screen?.visible else { return .zero }

        var origin: CGPoint
        switch self {
        case .cursor:
            // The pointer lands slightly left of the panel's top edge, spreading down from it like a menu
            origin = CGPoint(x: mouse.x - size.width * 0.2, y: mouse.y - size.height)
        case .center:
            origin = CGPoint(x: visible.midX - size.width / 2,
                             y: visible.midY - size.height / 2)
        }
        origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
        origin.y = min(max(origin.y, visible.minY), visible.maxY - size.height)
        return origin
    }

    private static func distance(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return hypot(dx, dy)
    }
}
