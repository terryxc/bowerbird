import SwiftUI

/// The explanation card that opens below the search field when Return is pressed to paste but
/// there's no Accessibility permission.
///
/// Showing the system prompt at launch is the easiest approach, and the worst: the user has just
/// installed the app, hasn't pressed Return once, and is first asked "allow this to control your
/// computer?". At that moment they have no reason to agree, and the system prompt only ever
/// appears once; after a refusal the app is permanently crippled for them. So we ask here instead:
/// they've just pressed Return and what they expected didn't happen, so "why" is self-evident.
///
/// Each of the three sentences has one job: the title says what they get right away by agreeing,
/// the first line says they aren't stuck now either, and the second line says what the permission
/// is used for and what it isn't. An app with Accessibility permission can read everything in
/// other windows, and that's exactly what users fear; stating the boundary is far more useful than
/// a bare "permission required".
struct AccessibilityCard: View {
    /// The app that was just in front; once permission is granted, paste goes into it
    let targetName: String?
    /// The system prompt has already been shown once. After that it never appears again, and the
    /// only option is to send people to System Settings to find it themselves. That's the path where
    /// "Bowerbird isn't in the list at all" happens, so that fallback is only offered after this.
    let hasAsked: Bool
    let onGrant: () -> Void
    let onDismiss: () -> Void
    let onShowInFinder: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: PanelMetrics.rowIconSpacing) {
            Image(systemName: "accessibility")
                .font(.system(size: PanelMetrics.permissionIconSize))
                .foregroundStyle(AppColors.accent)
                // Aligned with the centre line of the title row, not the centre of the whole text block
                .frame(height: PanelMetrics.permissionTitleLineHeight)
            VStack(alignment: .leading, spacing: PanelMetrics.permissionLineSpacing) {
                Text(verbatim: title)
                    .font(.system(size: PanelMetrics.permissionTitleFontSize, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(height: PanelMetrics.permissionTitleLineHeight)
                // Offer the way out before making the request. The content is already in hand
                // (copying needs no permission); without saying so, users think that press was wasted.
                Text("It is copied already — you can switch back and press ⌘V yourself.")
                // Boundary and purpose in one sentence. It used to be two sentences, and the
                // subject of the second, "this permission is only used to...", was the permission,
                // not us. It read like a description of a system feature rather than our promise.
                //
                // It says "never reads keystrokes", not "never reads anything you type". The latter
                // is a nice-sounding empty claim: we read the clipboard by design, and plenty of what
                // you type gets copied.
                Text("That needs Accessibility — used only to send ⌘V, never to read your keystrokes.")
                if hasAsked {
                    FinderFallbackLink(action: onShowInFinder)
                        .padding(.top, PanelMetrics.permissionLineSpacing)
                }
            }
            .foregroundStyle(.secondary)
            // The buttons sit on the title row, which uses up the empty space on the right and
            // makes the card a whole line shorter. "What you get by agreeing" sits next to "agree",
            // without two lines of explanation in between.
            Spacer(minLength: PanelMetrics.contentInset)
            HStack(spacing: ChipMetrics.spacing * 2) {
                // "Not Now" rather than "Later": the latter sounds like deferring a to-do, but this
                // is just skipping it this time, and shouldn't promise on the user's behalf that
                // they'll come back to it.
                PanelActionButton(title: L("Not Now"), action: onDismiss)
                // Clicking doesn't grant the permission on the spot; it just enters the system flow,
                // so it isn't called "Enable Permission". The ellipsis is the long-standing macOS
                // convention: there's another step for you to take.
                PanelActionButton(title: hasAsked ? L("Open System Settings") : L("Allow…"),
                                  prominent: true, action: onGrant)
            }
            .frame(height: PanelMetrics.permissionTitleLineHeight)
        }
        .font(.system(size: PanelMetrics.footerFontSize))
        .padding(.horizontal, PanelMetrics.contentInset)
        .padding(.vertical, PanelMetrics.permissionCardPaddingV)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColors.subtleFill)
        // It pushes out from under the search field and the list moves down. Not a fade: a fade
        // looks like it was always there, while pushing out says "this is the response to the
        // key you just pressed".
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    /// The title says what happens after agreeing, and we keep our word: the moment permission is
    /// granted, this item is pasted (see PanelModel.accessibilityGranted).
    ///
    /// It used to say "paste directly into TextEdit". "Directly" reads as if one click pastes, but
    /// clicking only jumps to System Settings, and the real paste waits until permission is
    /// granted. Be clear about the timing.
    private var title: String {
        guard let targetName else { return L("Allow it and this goes into your last app") }
        return L("Allow it and this goes into %@", targetName)
    }
}

/// The fallback for "Bowerbird isn't in System Settings at all".
///
/// It happens when running straight from the DMG or after moving the app: the system remembers
/// the old path, and the entry in the list stopped being this app long ago. Selecting it in Finder
/// and dragging it into that list is the only fix.
///
/// Not underlined normally, only on hover; that's the convention for text links on macOS.
/// A whole sentence underlined all the time looks like a web page and is too noisy on a card.
private struct FinderFallbackLink: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text("Bowerbird not in the list? Show it in Finder, then drag it into the list.")
                .underline(hovering)
                .foregroundStyle(AppColors.accent)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
