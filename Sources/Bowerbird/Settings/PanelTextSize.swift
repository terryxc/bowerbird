import CoreGraphics

/// The size of text in the panel.
///
/// Why this setting exists: the same point size has very different physical sizes on different
/// screens. The macOS baseline density is 109 points per inch, while a 27-inch 4K display scaled to
/// 1920 has only 82, so text is a third larger than baseline; a MacBook Pro's built-in display is 122
/// at the default setting and up to 145 at "More Space". The same 13 pt title line is 4.06 mm tall on
/// the external display and only 2.70 mm on a 14-inch built-in display, a third smaller.
/// So "is the text big enough" can't be settled by design; it has to be left to the user.
///
/// Kept separate from "panel size" instead of merged into one setting: that one is how big the window
/// is, this one is how big the text is. Combined, wanting large text would force a large window, and
/// vice versa. WeChat's settings keep these two apart as well.
///
/// Only text is scaled, not spacing or icons: scaling the spacing up doesn't make text easier to read,
/// it only fits less on screen. Row height and the search row height are exceptions; they must grow,
/// or large text gets clipped.
enum PanelTextSize: String, CaseIterable, Identifiable, Codable {
    case small, standard, large, extraLarge

    var id: String { rawValue }

    var title: String {
        switch self {
        case .small: "Small"
        case .standard: "Standard"
        case .large: "Large"
        case .extraLarge: "Extra Large"
        }
    }

    /// Font sizes are multiplied by this.
    ///
    /// Adjacent steps differ by 15%: any smaller and you can't tell them apart, any larger and it feels
    /// like a jump. Extra Large is 1.3 times Standard, which brings the 2.70 mm on a 14-inch built-in
    /// display back to 3.5 mm, close to how it feels on the baseline display.
    var scale: CGFloat {
        switch self {
        case .small: 0.85
        case .standard: 1
        case .large: 1.15
        case .extraLarge: 1.3
        }
    }

    /// Computes the font size for this step, rounded to half a point. SwiftUI accepts fractions, but
    /// half a point is the finest step that still aligns to pixels on Retina; anything finer only
    /// blurs the edges.
    func scaled(_ base: CGFloat) -> CGFloat {
        (base * scale * 2).rounded() / 2
    }
}
