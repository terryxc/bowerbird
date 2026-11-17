import SwiftUI

/// General: how this app runs on this Mac, then the panel. The most frequently used "Pause
/// Recording" goes in the first row. The panel settings used to be a page of their own; one page
/// fewer in the sidebar, and they are all appearance anyway.
struct GeneralSettingsPage: View {
    @ObservedObject private var settings = AppSettings.shared
    /// There is a single source of permission state and this page follows it. Previously this page,
    /// the panel and the menu bar each kept their own copy, and none knew when another changed.
    @ObservedObject private var permission = AccessibilityPermission.shared

    var body: some View {
        // The permission appears only while it is missing. Granted, it is not a setting and has
        // nothing to show; missing, it is the one thing on this page that needs doing, so it comes
        // first, with the button and the fallback for "Bowerbird isn't in the list".
        if !permission.isTrusted {
            SettingsCard {
                SettingsRow(title: "Accessibility Permission",
                            subtitle: "Not granted. Enter only copies to the clipboard.",
                            leading: { StatusDot(on: false) }) {
                    Button(permission.hasAsked ? "Open System Settings" : "Allow…") {
                        permission.request()
                    }
                    .modifier(SettingsButtonStyle(prominent: true))
                }
                // The system prompt appears only once; after that the only option is sending people
                // to find it in System Settings themselves. That path is where "Bowerbird isn't in
                // the list" happens (running straight from the DMG, or after moving the app, when the
                // system remembers the old path). So this fallback is only offered after that point.
                if permission.hasAsked {
                    SettingsDivider()
                    SettingsRow(title: "Bowerbird not in the list?",
                                subtitle: "Show it in Finder, then drag it into the list.") {
                        SettingsActionButton("Show in Finder") { permission.showInFinder() }
                    }
                }
            }
            // Say what the permission is and isn't used for right where it is requested. It is the
            // most sensitive permission in the app, and people have a right to know its limits.
            SettingsCaption(text: "Bowerbird uses it only to send ⌘V, never to read your keystrokes.")
        }
        SettingsCard {
            // Modelled on a media player: the left side shows the state (a lit dot plus "Recording"),
            // the right side the next action (⏸ Pause / ▶ Resume). A switch would say "is the pause
            // option on", which is one step removed; a player's button says "what happens when you
            // press it", the same language as the menu bar item.
            SettingsRow(title: settings.paused ? "Paused" : "Recording",
                        leading: { StatusDot(on: !settings.paused) }) {
                Button {
                    settings.paused.toggle()
                } label: {
                    Label(settings.paused ? "Resume" : "Pause",
                          systemImage: settings.paused ? "play.fill" : "pause.fill")
                        .contentTransition(.symbolEffect(.replace))
                }
                .modifier(SettingsButtonStyle())
            }
        }
        // One card for how the app runs on this Mac: at login, in which look, with which icon and
        // language. A toggle and three pop-ups used to sit in two cards for no reason but their shape.
        SettingsCard {
            SettingsRow(title: "Launch at Login") {
                SettingsToggle(isOn: $settings.launchAtLogin)
            }
            SettingsDivider()
            SettingsRow(title: "Appearance") {
                SettingsPopUp(selection: $settings.appearance, options: [
                    .init(value: .system, title: L("Follow System")),
                    .init(value: .light, title: L("Light")),
                    .init(value: .dark, title: L("Dark")),
                ])
                .modifier(SettingsPopUpStyle())
            }
            SettingsDivider()
            // Language names are always written in their own language, not translated into the UI
            // language: when the UI is showing a language you can't read, this list is how you find
            // your way back to your native one.
            SettingsRow(title: "Language") {
                SettingsPopUp(selection: $settings.language, options:
                    [.init(value: .system, title: L("Follow System"))]
                    + AppLanguage.allCases.filter { $0 != .system }.enumerated().map { index, language in
                        .init(value: language, title: language.endonym, separatorBefore: index == 0)
                    })
                .modifier(SettingsPopUpStyle())
            }
            SettingsDivider()
            // Icons only, no names: the menu bar shows only the icon too, and a name would be an extra
            // layer of translation
            SettingsRow(title: "Menu Bar Icon") {
                SettingsPopUp(selection: $settings.menuBarIcon, options: MenuBarIcon.allCases.map {
                    .init(value: $0, title: "", image: $0.image(), toolTip: L($0.title))
                })
                .modifier(SettingsPopUpStyle())
            }
        }
        SettingsCaption(text: "Panel")
        PanelSettingsPage()
    }
}
