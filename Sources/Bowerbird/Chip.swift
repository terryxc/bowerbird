import AppKit
import SwiftUI

/// Sizes for a row of small options. Shared by the panel's format bar and the multi-select and
/// icon pickers in Settings.
///
/// There used to be two sets: 20 high with 9 padding in the panel, 22 high with 8 padding in Settings,
/// the same control differing by 2 pt between two windows for no reason. Now there is just this one.
/// 20 matches the trailing row action buttons in the panel and the small buttons in Settings, so they
/// line up when placed in one row.
enum ChipMetrics {
    static let height: CGFloat = 20
    static let paddingH: CGFloat = 9
    static let fontSize: CGFloat = 11
    /// Between chips
    static let spacing: CGFloat = 4
}

/// One chip in a row of small options.
///
/// The selected state is "a wash plus normal text", the same approach as selected rows in the list.
/// At first the selected text used the accent colour, which computes to only 1.71:1 in dark mode,
/// three times worse than the **unselected** 5.07:1: light purple text on a light purple background,
/// the more emphasis the less visible. With the primary text colour it is 4.93:1.
///
/// `outlined` is the only style switch. The panel's format bar is a set of mutually exclusive modes,
/// so unselected chips have no border and the bar reads as one segmented control; options on Settings
/// cards are independent, so unselected chips still need to look pressable and get an outline.
struct Chip<Label: View>: View {
    let selected: Bool
    var outlined = false
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            label()
                .foregroundStyle(selected ? Color.primary : Color.secondary)
                .padding(.horizontal, ChipMetrics.paddingH)
                .frame(height: ChipMetrics.height)
                .background(
                    RoundedRectangle(cornerRadius: Radius.chip)
                        .fill(fill)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.chip)
                        .strokeBorder(outlined && !selected ? AppColors.controlBorder : Color.clear,
                                      lineWidth: Hairline.width)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    private var fill: Color {
        if selected { return AppColors.accentWash }
        return hovering ? AppColors.subtleFill : .clear
    }
}

/// Text chip. The selected one is one weight bolder at the same size.
///
/// Semibold is wider than regular, so a chip grew when selected and pushed the ones after it along.
/// Each chip now reserves the semibold width with a hidden copy and draws its real weight on top,
/// the way macOS segmented controls keep still.
struct TextChip: View {
    private let text: Text
    let selected: Bool
    var outlined = false
    let action: () -> Void

    init(_ title: LocalizedStringKey, selected: Bool, outlined: Bool = false,
         action: @escaping () -> Void) {
        text = Text(title)
        self.selected = selected
        self.outlined = outlined
        self.action = action
    }

    /// An already-localized title
    init(verbatim title: String, selected: Bool, outlined: Bool = false,
         action: @escaping () -> Void) {
        text = Text(verbatim: title)
        self.selected = selected
        self.outlined = outlined
        self.action = action
    }

    var body: some View {
        Chip(selected: selected, outlined: outlined, action: action) {
            ZStack {
                text.font(.system(size: ChipMetrics.fontSize, weight: .semibold))
                    .hidden()
                    .accessibilityHidden(true)
                text.font(.system(size: ChipMetrics.fontSize,
                                  weight: selected ? .semibold : .regular))
            }
        }
    }
}
