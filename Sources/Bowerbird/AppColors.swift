import AppKit
import SwiftUI

extension NSColor {
    /// Switches between two values depending on the system appearance.
    /// SwiftUI's `Color.primary` flips to white in dark mode, so anything directional like
    /// "darken slightly" can't rely on it; each appearance needs its own value.
    static func adaptive(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }

    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

/// Global palette.
///
/// Neutrals (backgrounds, separators, strokes, keycap fills) follow different rules per appearance:
///
/// - **Light mode is pure grey, chroma 0.** Originally every neutral was nudged slightly toward
///   the accent purple, on the theory that "a screen of pure grey looks like no one picked the
///   colours". On real hardware that tint read as "dirty", not "picked": on a MacBook Pro's P3
///   display, next to a #FFFFFF system window, #FAF9FB was spotted at a glance as "slightly
///   purple". In light mode the brand feel is carried by the accent, selection and
///   hover, which are clearly purple anyway.
/// - **Dark mode keeps the purple tint.** On a dark background a bit of hue reads as "deep", not
///   "dirty" (Raycast's dark background is a bluish dark grey too), and nobody has complained.
///
/// When switching to pure grey, lightness was matched to the old values, so no contrast ratio
/// moved (within 0.01): ink #2E2640 → #2A2A2A (L* 17.2 → 17.1), sidebar #F2F0F5 → #F1F1F1 (95.1).
///
/// The accent has two values: #5E35B1 on light backgrounds, brightened to #A489E5 on dark ones;
/// otherwise selection and icons blur into the background in dark mode.
enum AppColors {
    /// Light-mode base. The panel and the settings content area share the same "base", one value.
    private static let lightBase = NSColor(hex: 0xFAFAFA)
    /// Light-mode ink shared by separators, strokes and keycap fills, layered on the base at their own alpha
    private static let lightInk: UInt32 = 0x2A2A2A

    // MARK: Accent

    /// Accent for text, icons and strokes. Must be brightened on dark backgrounds to stay legible.
    static let accent = Color(nsColor: .adaptive(
        light: NSColor(hex: 0x5E35B1),
        dark: NSColor(hex: 0xA489E5)
    ))

    /// Accent for solid fills with white text on top.
    ///
    /// Kept separate from the one above for a reason: once accent is brightened to #A489E5 in
    /// dark mode, white text on it only reaches just over 3:1, which fails for 13 pt text. The fill
    /// uses #7E57C2 instead: white text at 5.21:1 passes AA, and 3.33:1 against the sidebar is
    /// enough to read as a block of colour. In light mode both are the same value.
    static let accentFill = Color(nsColor: .adaptive(
        light: NSColor(hex: 0x5E35B1),
        dark: NSColor(hex: 0x7E57C2)
    ))

    /// Fill for the selected row.
    ///
    /// The strongest row background in the panel list. Hover has its own, much fainter layer
    /// (rowHover), so this one can be fairly strong without the two being confused.
    static let accentWash = Color(nsColor: .adaptive(
        light: NSColor(hex: 0x5E35B1, alpha: 0.20),
        dark: NSColor(hex: 0xA489E5, alpha: 0.32)
    ))

    /// Hover background for list rows. Same purple as selection, just much lighter.
    ///
    /// The two layers are separated by **intensity**, not hue. Measured in Raycast, both of its
    /// layers are neutral grey: normal row #CACED1, hover #C2C4C7, selected #B7BABC.
    ///
    /// Levels are chosen by lightness, which is more reliable than choosing by alpha. In light mode
    /// the base is L*=98.0, hover at 5% is 94.9 (3.1 from the base, just visible), selected at 20%
    /// is 85.6 (12.5 from the base), 9.3 between the two. Same in dark mode: base 7.3, hover at 8%
    /// is 12.5, selected at 32% is 26.9.
    ///
    /// Tried 6% with 14% in between: only 4.8 apart, still muddy on real hardware. The very first
    /// version, 12% with 14%, was less than one step apart and looked like two rows were selected.
    static let rowHover = Color(nsColor: .adaptive(
        light: NSColor(hex: 0x5E35B1, alpha: 0.05),
        dark: NSColor(hex: 0xA489E5, alpha: 0.08)
    ))

    /// Background behind the matched characters of a search hit in the body text.
    ///
    /// Can't reuse the selected-row level (accentWash): that is meant for a whole row, and spread
    /// over a few characters the small area makes it almost invisible. Worked out: the row level
    /// is only 1.37:1 against the panel base in light mode and 1.73:1 in dark, and the two modes
    /// are noticeably apart. Here light is 0.34 and dark 0.38, giving 1.76:1 and 1.96:1 against
    /// the base: roughly equal, and both one step heavier than the row fill.
    ///
    /// Any heavier would start to hurt legibility: body text on top is 10.4:1 in light and 9.2:1
    /// in dark. That margin is enough, but there's no need to push further.
    static let searchMatch = Color(nsColor: .adaptive(
        light: NSColor(hex: 0x5E35B1, alpha: 0.34),
        dark: NSColor(hex: 0xA489E5, alpha: 0.38)
    ))

    /// Hover background. Only used in places like the settings sidebar: a set of buttons where selection is shown by something else.
    static let accentWashHover = Color(nsColor: .adaptive(
        light: NSColor(hex: 0x5E35B1, alpha: 0.06),
        dark: NSColor(hex: 0xA489E5, alpha: 0.12)
    ))

    // MARK: Neutrals

    /// Separator. The whole app has only this one value: card strokes, hairlines and vertical rules all use it.
    static let separator = Color(nsColor: .adaptive(
        light: NSColor(hex: lightInk, alpha: 0.13),
        dark: NSColor(hex: 0xD6CEE8, alpha: 0.14)
    ))

    /// Fill for things like keycaps and tags that need a background but aren't standalone objects
    static let subtleFill = Color(nsColor: .adaptive(
        light: NSColor(hex: lightInk, alpha: 0.08),
        dark: NSColor(hex: 0xD6CEE8, alpha: 0.11)
    ))

    /// Panel background. Solid, opaque.
    ///
    /// Dark mode follows a measurement of Raycast: its panel is #15191E, a bluish dark grey, not
    /// pure black; we shift the same amount toward purple, #17151D.
    ///
    /// Light mode is #FAFAFA (L* 98.3), the same value as the settings content area.
    ///
    /// Lightness: it was once pushed down to #EFEEF2 (L* 94.3), on the grounds that a large near-white
    /// block was too glaring on an external display. But a regular macOS 26 window background
    /// measures #FFFFFF, so the panel became the only L* 94 light surface on screen, 6 L* darker
    /// than every window around it. On the MacBook Pro's own display it just looked like a grey
    /// block; reported as "tiring to look at". Text contrast wasn't the cause (body
    /// text is 13.4:1 and 14.5:1 on the two backgrounds); the whole panel sank relative to its
    /// surroundings. Staying only 2 L* off white works for both cases.
    ///
    /// For why the hue is pure grey, see the top of the file.
    /// All wash levels are alpha-blended, so after changing the base their L* distance from it
    /// barely moves; no retuning needed.
    static let panelBackground = Color(nsColor: .adaptive(
        light: lightBase,
        dark: NSColor(hex: 0x17151D)
    ))

    /// The hairline around the panel's outer edge, to close off the boundary
    static let panelBorder = Color(nsColor: .adaptive(
        light: NSColor(hex: lightInk, alpha: 0.12),
        dark: NSColor(hex: 0xD6CEE8, alpha: 0.16)
    ))

    /// Settings window sidebar. Must sit lower than the content area, "deeper" rather than "brighter" in both modes.
    static let sidebarBackground = Color(nsColor: .adaptive(
        light: NSColor(hex: 0xF1F1F1),
        dark: NSColor(hex: 0x1B1922)
    ))

    /// Settings window content area. Same light value as the panel base. Slightly deeper than the
    /// cards so the cards can float: if the content area used textBackgroundColor directly, in
    /// light mode it would match the white cards, which would then rely on a single border line
    /// with no layering.
    static let contentBackground = Color(nsColor: .adaptive(
        light: lightBase,
        dark: NSColor(hex: 0x1F1D26)
    ))

    /// Card background. Three levels from deep to floating: sidebar → content area → card.
    static let cardBackground = Color(nsColor: .adaptive(
        light: NSColor(hex: 0xFFFFFF),
        dark: NSColor(hex: 0x2A2733)
    ))

    // MARK: Status colours

    /// Permission granted. A cooler green, at the same colour temperature as the purple accent,
    /// which suits this palette better than the system green.
    static let ok = Color(nsColor: .adaptive(
        light: NSColor(hex: 0x2A8F55),
        dark: NSColor(hex: 0x4FBF7F)
    ))

    /// Fill for destructive actions, with a white symbol on top. Fill only, never text.
    ///
    /// When the delete button sits on a row with a background, in dark mode that background is a
    /// mid-tone like #716D8B. Red **text** on it, light or dark, can't reach the AA floor of 3.0
    /// for icons: system red is 1.45:1, and even the brightest light red tried only gets 2.56:1.
    /// When text contrast can't be relied on, flip it: fill a solid block and draw the symbol in
    /// white. White against the fill doesn't depend on what's underneath, so that is a number we
    /// can guarantee. White on light #B42B3A is 6.27:1, on dark #D2394A 4.75:1, both pass AA for
    /// small text. Accent buttons also fill with accentFill on hover: one rule for both.
    static let dangerFill = Color(nsColor: .adaptive(
        light: NSColor(hex: 0xB42B3A),
        dark: NSColor(hex: 0xD2394A)
    ))

    /// Control stroke. One step darker than the separator.
    ///
    /// A separator says "there's a seam here"; a stroke says "this is something you can press".
    /// The two often sit on the same background and must be distinguishable. The action buttons in
    /// the panel's right column and the cells of the format bar have the same height and corner
    /// radius and differ only by stroke; at the separator level (1.27:1 against the base) you have
    /// to lean in to see it. This level is 1.53:1 (light) and 1.52:1 (dark) against the base.
    static let controlBorder = Color(nsColor: .adaptive(
        light: NSColor(hex: lightInk, alpha: 0.22),
        dark: NSColor(hex: 0xD6CEE8, alpha: 0.26)
    ))
}

/// Corner radius scale. Only these five steps; no more ad hoc values like 3.5 or 5.
enum Radius {
    /// Keycaps, small badges
    static let chip: CGFloat = 4
    /// Images, thumbnails
    static let media: CGFloat = 6
    /// List rows, sidebar items
    static let row: CGFloat = 8
    /// Grouped cards
    static let card: CGFloat = 10
    /// Windows and panels
    static let window: CGFloat = 12
}

/// Hairline width: always exactly one physical pixel.
///
/// A hard-coded 0.5 is only right on Retina; on a 1x display it lands on half a pixel, the
/// system interpolates, and the line goes blurry.
enum Hairline {
    static var width: CGFloat {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        return 1 / max(scale, 1)
    }
}
