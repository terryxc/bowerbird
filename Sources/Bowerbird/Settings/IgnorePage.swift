import AppKit
import BowerbirdCore
import SwiftUI

/// The Ignore page: two cards, by source (app) and by content (regex).
///
/// Ignoring by app only stops the few apps you thought of in advance; passwords, API keys and ID
/// numbers get copied from browsers, terminals and notes, and those apps can't be ignored wholesale.
/// Ignoring by content covers that gap.
struct IgnorePage: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var draft = ""

    var body: some View {
        SettingsCaption(text: "Copies made in these apps are not recorded. Items flagged by password managers are always skipped.")
        SettingsCard {
            // One row with the button, then the apps as chips that wrap. They used to be one tall row
            // each with the bundle id underneath; seven apps pushed the patterns card off the page.
            // The bundle id is in the chip's tooltip.
            SettingsRow(title: "Ignored Apps") {
                SettingsActionButton("Choose…", action: addApp)
            }
            if !settings.ignoredBundleIDs.isEmpty {
                SettingsDivider()
                FlowLayout(spacing: 8) {
                    ForEach(settings.ignoredBundleIDs, id: \.self) { id in
                        IgnoredAppChip(bundleID: id) { remove(id) }
                    }
                }
                .padding(.horizontal, SettingsMetrics.cardHorizontalPadding)
                .padding(.vertical, 12)
            }
        }

        SettingsCaption(text: "Text or file paths matching any of these patterns are not recorded. Regular expressions, case-sensitive; start with (?i) to ignore case.")
        SettingsCard {
            if settings.ignoredPatterns.isEmpty {
                SettingsEmptyText(text: "No patterns yet")
            } else {
                ForEach(settings.ignoredPatterns, id: \.self) { pattern in
                    PatternRow(pattern: pattern) { removePattern(pattern) }
                    SettingsDivider()
                }
            }
            if settings.ignoredPatterns.isEmpty { SettingsDivider() }
            // The text field lives in the card; press Return or click the button to add. An invalid
            // regex isn't blocked from being added; its row gets flagged, so the user doesn't think
            // they are already protected.
            HStack(spacing: 10) {
                // Draw the placeholder ourselves. A plain-style TextField draws its placeholder in the
                // body text colour when unfocused (confirmed on a real screenshot), which makes it look
                // exactly like the real patterns above.
                ZStack(alignment: .leading) {
                    if draft.isEmpty {
                        Text("Add a pattern…")
                            .foregroundStyle(.tertiary)
                            .allowsHitTesting(false)
                    }
                    TextField("", text: $draft)
                        .textFieldStyle(.plain)
                        .onSubmit(addPattern)
                }
                .font(.system(size: SettingsMetrics.rowTitleFontSize, design: .monospaced))
                SettingsActionButton("Add", action: addPattern)
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, SettingsMetrics.cardHorizontalPadding)
            .padding(.vertical, 8)
            .frame(minHeight: SettingsMetrics.rowMinHeight)
        }
    }

    private func remove(_ id: String) {
        settings.ignoredBundleIDs.removeAll { $0 == id }
    }

    private func removePattern(_ pattern: String) {
        settings.ignoredPatterns.removeAll { $0 == pattern }
    }

    private func addPattern() {
        let pattern = draft.trimmingCharacters(in: .whitespaces)
        guard !pattern.isEmpty else { return }
        if !settings.ignoredPatterns.contains(pattern) {
            settings.ignoredPatterns.append(pattern)
        }
        draft = ""
    }

    private func addApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url,
              let id = Bundle(url: url)?.bundleIdentifier else { return }
        if !settings.ignoredBundleIDs.contains(id) {
            settings.ignoredBundleIDs.append(id)
        }
    }
}

/// One ignored app as a chip: icon, name, and an × to take it off the list. The tooltip carries the
/// bundle id. An app not installed on this Mac shows a dashed icon and its bundle id as the name.
private struct IgnoredAppChip: View {
    let bundleID: String
    let onRemove: () -> Void
    @State private var hovering = false

    private var installedName: String? {
        AppIconCache.shared.installedName(for: bundleID)
    }

    var body: some View {
        HStack(spacing: 6) {
            Group {
                if let icon = AppIconCache.shared.icon(for: bundleID) {
                    Image(nsImage: icon).resizable()
                } else {
                    Image(systemName: "app.dashed")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: 16, height: 16)
            Text(installedName ?? bundleID)
                .font(.system(size: SettingsMetrics.rowTitleFontSize))
                .foregroundStyle(installedName == nil ? .secondary : .primary)
                .lineLimit(1)
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(hovering ? Color.primary : Color.secondary)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Remove")
            .onHover { hovering = $0 }
        }
        .padding(.leading, 6)
        .padding(.trailing, 4)
        .padding(.vertical, 4)
        .background(AppColors.subtleFill, in: RoundedRectangle(cornerRadius: Radius.row))
        .help(installedName == nil ? L("Not installed") : bundleID)
    }
}

/// A single regex. One that doesn't compile is flagged but not deleted: the user most likely just missed a
/// parenthesis.
private struct PatternRow: View {
    let pattern: String
    let onRemove: () -> Void

    private var valid: Bool { IgnorePatterns.isValid(pattern) }

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: pattern)
                    .font(.system(size: SettingsMetrics.rowTitleFontSize, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !valid {
                    Label("Not a valid pattern, so it is not applied", systemImage: "exclamationmark.triangle")
                        .font(.system(size: SettingsMetrics.rowSubtitleFontSize))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            RowActionButton(symbol: "xmark.circle.fill", help: "Remove", action: onRemove)
        }
        .padding(.horizontal, SettingsMetrics.cardHorizontalPadding)
        .padding(.vertical, 6)
        .frame(minHeight: valid ? 34 : SettingsMetrics.rowWithSubtitleMinHeight)
    }
}
