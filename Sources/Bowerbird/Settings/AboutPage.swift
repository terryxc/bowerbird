import AppKit
import BowerbirdCore
import SwiftUI

struct AboutPage: View {
    let store: HistoryStore

    /// Repository URL. If the repository moves, update this together with the README.
    private static let repositoryURL = URL(string: "https://github.com/terryxc/bowerbird")!

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    /// Replaces the home directory with ~ so the user name doesn't appear in the UI or screenshots
    private var abbreviatedPath: String {
        (store.dataDirectory.path as NSString).abbreviatingWithTildeInPath
    }

    var body: some View {
        SettingsCard {
            SettingsRow(title: "Version") {
                Text(version)
                    .font(.system(size: SettingsMetrics.rowTitleFontSize))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            SettingsDivider()
            SettingsRow(title: "Data Folder", subtitle: "\(abbreviatedPath)") {
                SettingsActionButton("Show in Finder", width: SettingsMetrics.pairedButtonWidth) { NSWorkspace.shared.open(store.dataDirectory) }
            }
            SettingsDivider()
            SettingsRow(title: "Source Code", subtitleText: "github.com/terryxc/bowerbird") {
                SettingsActionButton("Open on GitHub", width: SettingsMetrics.pairedButtonWidth) { NSWorkspace.shared.open(Self.repositoryURL) }
            }
        }
    }
}
