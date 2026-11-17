import SwiftUI

/// The panel section of the General page: where it appears when opened, what it looks like, how
/// the list is ordered. Keys are in ShortcutsSettingsPage.
struct PanelSettingsPage: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        SettingsCard {
            SettingsRow(title: "Panel Size", subtitle: rowCountSubtitle) {
                SettingsPopUp(selection: $settings.panelSize, options: [
                    .init(value: .small, title: L("Small")),
                    .init(value: .medium, title: L("Medium")),
                    .init(value: .large, title: L("Large")),
                ])
                .modifier(SettingsPopUpStyle())
            }
            SettingsDivider()
            // Right next to Panel Size, but a separate thing: that one sets the window size, this one
            // the text size. The same point size looks very different across screens: a 27-inch 4K
            // scaled to 1920 is 82 ppi, a MacBook Pro's built-in display is 122 to 145, so the same
            // line of text differs physically by a third.
            SettingsRow(title: "Text Size") {
                SettingsPopUp(selection: $settings.panelTextSize,
                              options: PanelTextSize.allCases.map {
                    .init(value: $0, title: L($0.title))
                })
                .modifier(SettingsPopUpStyle())
            }
            SettingsDivider()
            SettingsRow(title: "Panel Appears") {
                SettingsPopUp(selection: $settings.panelPosition, options: PanelPosition.allCases.map {
                    .init(value: $0, title: L($0.titleKey))
                })
                .modifier(SettingsPopUpStyle())
            }
            SettingsDivider()
            // Once familiar, the row of hints just takes up space. When turned off the whole bar isn't drawn,
            // and the list gains a row's height.
            SettingsRow(title: "Show shortcut hints at the bottom of the panel") {
                SettingsToggle(isOn: $settings.showsFooterHints)
            }
            SettingsDivider()
            SettingsRow(title: "Move used items to the top") {
                SettingsToggle(isOn: $settings.moveToTopWhenUsed)
            }
        }
    }

    private var rowCountSubtitle: LocalizedStringKey {
        "Shows about \(settings.panelSize.visibleRows) rows"
    }
}
