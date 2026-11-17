import KeyboardShortcuts
import SwiftUI

/// Shortcuts: how to open the panel and how to use the selected item.
///
struct ShortcutsSettingsPage: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        // One card: the global key first, then the panel's own keys. The arrow keys and Esc are not
        // listed because they cannot be changed; what is listed can.
        SettingsCard {
            SettingsRow(title: "Open Panel Shortcut") {
                ShortcutRecorder(target: .togglePanel)
            }
            ForEach(Array(PanelAction.allCases.enumerated()), id: \.element) { _, action in
                SettingsDivider()
                SettingsRow(title: LocalizedStringKey(action.title)) {
                    ShortcutRecorder(target: .panel(action))
                }
            }
        }
        HStack {
            Button("Restore Defaults") {
                settings.resetPanelShortcuts()
                KeyboardShortcuts.reset(.togglePanel)
            }
            .modifier(SettingsButtonStyle())
            Spacer()
        }
    }
}
