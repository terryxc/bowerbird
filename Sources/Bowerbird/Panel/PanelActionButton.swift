import SwiftUI

/// Action buttons in the panel: "Copy Text" and "Show in Finder" in the right column's action row,
/// and "Resume" on the pause bar.
///
/// Same height and corner radius as the format bar chips; a border is what says "this is an action"
/// rather than "this is a mode". The border uses controlBorder rather than the divider colour: the two
/// sit close together, and the divider shade is so faint you'd have to lean in to see the difference,
/// so however correct the rule, nobody could read it.
struct PanelActionButton: View {
    let title: String
    var enabled: Bool = true
    /// Primary button: accent fill with white text. Only one per place, otherwise there is no hierarchy.
    var prominent: Bool = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(verbatim: title)
                .font(.system(size: ChipMetrics.fontSize, weight: prominent ? .medium : .regular))
                .foregroundStyle(prominent ? Color.white : Color.primary)
                .padding(.horizontal, ChipMetrics.paddingH)
                .frame(height: ChipMetrics.height)
                .background(
                    RoundedRectangle(cornerRadius: Radius.chip)
                        .fill(fill)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.chip)
                        .strokeBorder(prominent ? Color.clear : AppColors.controlBorder,
                                      lineWidth: Hairline.width)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
        .onHover { hovering = $0 }
    }

    private var fill: Color {
        // The primary button already has a fill, so hover dims it slightly as feedback; secondary buttons
        // are empty until hovered, when the fill appears
        if prominent { return AppColors.accentFill.opacity(hovering && enabled ? 0.85 : 1) }
        return hovering && enabled ? AppColors.subtleFill : .clear
    }
}
