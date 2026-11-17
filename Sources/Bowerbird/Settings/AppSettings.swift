import AppKit
import Foundation
import BowerbirdCore
import ServiceManagement

/// Settings are only read and written on the main thread: the UI changes them, and capture works
/// from a snapshot (see CapturePolicy).
///
/// Each setting's value is cached in `Stored`, which only knows about changes made by this process.
/// A preference changed from outside with `defaults write` takes effect only after relaunching the
/// app. Verified: `UserDefaults.didChangeNotification` doesn't fire for writes from
/// other processes, so the "reload from disk" hooked onto it never actually worked. Instead, every
/// settings change made here flushed the entire cache for nothing and sent an extra notification.
/// Settings are changed from this app's UI anyway, and that path has always been correct.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    /// Stored reads and writes here directly
    let defaults = UserDefaults.standard

    // Each setting's key name and default value are written on its own declaration.
    // Persisting and notifying the UI are done by Stored. Changes made by another process are not
    // picked up; see the note at the top.

    @Stored("textDays") var textDays = 30
    @Stored("imageDays") var imageDays = 7
    /// File items are just addresses of a few dozen bytes, so by default they're kept as long as text
    @Stored("fileDays") var fileDays = 30
    /// Items pasted from the history move back to the top of the list. On by default in Alfred;
    /// Clipy has it too.
    @Stored("moveToTopWhenUsed") var moveToTopWhenUsed = true
    /// Whether to accept text and images handed off from iPhone or iPad. Files are never accepted:
    /// what arrives is only a temporary address that expires within minutes, so a stored copy
    /// couldn't be pasted.
    @Stored("captureFromOtherDevices") var captureFromOtherDevices = true
    @Stored("ignoredBundleIDs") var ignoredBundleIDs = [
        "com.1password.1password", "com.bitwarden.desktop", "com.apple.keychainaccess",
    ]
    @Stored("panelSize") var panelSize = PanelSize.medium
    /// How big the text in the panel is. That's separate from how big the window is; see PanelTextSize.
    @Stored("panelTextSize") var panelTextSize = PanelTextSize.standard
    /// Pause recording. Pressing it before copying something sensitive beats deleting it from the
    /// history afterwards.
    @Stored("paused") var paused = false

    /// Per-content-type capture switches. This is a separate dimension from "ignore certain apps":
    /// one goes by what the content is, the other by where it comes from.
    @Stored("captureText") var captureText = true
    @Stored("captureImages") var captureImages = true
    @Stored("captureFiles") var captureFiles = true
    /// Run images through on-device text recognition. When off, new images aren't recognised and
    /// text already recognised no longer takes part in search.
    @Stored("recognizeText") var recognizeText = true

    @Stored("menuBarIcon") var menuBarIcon = MenuBarIcon.clipboard
    /// Clear the history on quit. On a shared or work computer, quitting the app leaves no trace.
    @Stored("clearOnQuit") var clearOnQuit = false
    /// Where the panel appears
    @Stored("panelPosition") var panelPosition = PanelPosition.center
    /// The row of shortcut hints along the bottom of the panel. Can be turned off once you know them.
    @Stored("showsFooterHints") var showsFooterHints = true
    /// Regexes that block content. A separate dimension from "ignore apps": one goes by source,
    /// the other by content.
    @Stored("ignoredPatterns") var ignoredPatterns = [String]()
    @Stored("appearance") private var storedAppearance = AppAppearance.system
    @Stored("language") private var storedLanguage = AppLanguage.system

    /// The few settings that need something else done after changing are wrapped in computed
    /// properties; storage still goes through Stored.
    var appearance: AppAppearance {
        get { storedAppearance }
        set {
            storedAppearance = newValue
            newValue.apply()
        }
    }

    var language: AppLanguage {
        get { storedLanguage }
        set {
            guard newValue != storedLanguage else { return }
            storedLanguage = newValue
            localizationBundle = Localization.bundle(for: newValue)
            // Core reads this snapshot when it fetches strings in the background
            LocalizationSnapshot.update(bundle: localizationBundle, locale: newValue.locale)
            // Also write a copy for the system. The switch takes effect immediately through
            // localizationBundle; this copy is for the next cold launch, and so date and number
            // formats follow along.
            if let code = newValue.localeIdentifier {
                defaults.set([code], forKey: "AppleLanguages")
            } else {
                defaults.removeObject(forKey: "AppleLanguages")
            }
            NotificationCenter.default.post(name: .bowerbirdLanguageChanged, object: nil)
        }
    }

    /// The .lproj bundle for the current language, used for strings on the AppKit side
    private(set) var localizationBundle: Bundle = .main
    /// The compiled regexes. Capture checks them on every copy, so they can't be recompiled each time
    private(set) var ignorePatterns = IgnorePatterns([])

    /// "Launch at login" isn't stored here: the truth lives in the system's login items, and the
    /// user may change it in System Settings. Asking on every read keeps the switch from sitting in
    /// a position that went stale long ago.
    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            objectWillChange.send()
            do {
                if newValue { try SMAppService.mainApp.register() }
                else { try SMAppService.mainApp.unregister() }
            } catch {
                // On failure, let the switch spring back. This used to only log, and the UI kept
                // showing "on"
                NSLog("launch at login failed: \(error)")
            }
        }
    }

    /// A setting was just changed. Anything that needs to follow it is handled here.
    func didChange(key: String) {
        if key == "ignoredPatterns" {
            ignorePatterns = IgnorePatterns(ignoredPatterns)
        }
    }

    /// Shortcuts for the three rebindable actions in the panel. Actions never saved use their own
    /// defaults.
    @Published var panelShortcuts: [PanelAction: PanelShortcut] {
        didSet {
            let encodable = Dictionary(uniqueKeysWithValues:
                panelShortcuts.map { ($0.key.rawValue, $0.value) })
            if let data = try? JSONEncoder().encode(encodable) {
                defaults.set(data, forKey: "panelShortcuts")
            }
        }
    }

    /// nil means the action has no key and can only be used with the mouse
    func shortcut(for action: PanelAction) -> PanelShortcut? {
        guard let stored = panelShortcuts[action] else { return action.defaultShortcut }
        return stored.isUnbound ? nil : stored
    }

    /// Restore the factory shortcuts
    func resetPanelShortcuts() {
        panelShortcuts = [:]
    }

    private init() {
        if let data = UserDefaults.standard.data(forKey: "panelShortcuts"),
           let stored = try? JSONDecoder().decode([String: PanelShortcut].self, from: data) {
            panelShortcuts = Dictionary(uniqueKeysWithValues: stored.compactMap { key, value in
                PanelAction(rawValue: key).map { ($0, value) }
            })
        } else {
            panelShortcuts = [:]
        }
        migrate()
        localizationBundle = Localization.bundle(for: storedLanguage)
        ignorePatterns = IgnorePatterns(ignoredPatterns)
    }

    /// One-time cleanup of old keys.
    ///
    /// Step by step: a machine already at step 1 only runs step 2 and doesn't redo step 1.
    private func migrate() {
        let key = "settingsSchema"
        var schema = defaults.integer(forKey: key)

        if schema < 1 {
            // Old versions stored images and files together in mediaDays; on upgrade it carries
            // over to images
            if defaults.object(forKey: "imageDays") == nil, defaults.object(forKey: "mediaDays") != nil {
                defaults.set(defaults.integer(forKey: "mediaDays"), forKey: "imageDays")
            }
            // Keys left over from removed features. Without cleanup they'd sit in the user's plist
            // forever, read at every launch and then thrown away.
            for dead in ["mediaDays", "watchScreenshots", "returnAction", "quickPasteModifier"] {
                defaults.removeObject(forKey: dead)
            }
            // The "below the menu bar icon" panel position is gone too; erase values that no
            // longer decode
            if let saved = defaults.string(forKey: "panelPosition"), PanelPosition(rawValue: saved) == nil {
                defaults.removeObject(forKey: "panelPosition")
            }
            schema = 1
        }

        if schema < 2 {
            // The bird menu bar icon was removed and is no longer an option. Machines that stored
            // bird fall back to the default on their own since it doesn't decode, but the key would
            // sit in the plist forever, so clear it while we're here.
            if let saved = defaults.string(forKey: "menuBarIcon"), MenuBarIcon(rawValue: saved) == nil {
                defaults.removeObject(forKey: "menuBarIcon")
            }
            schema = 2
        }

        defaults.set(schema, forKey: key)
    }


    var retentionPolicy: RetentionPolicy {
        RetentionPolicy(textDays: textDays, imageDays: imageDays, fileDays: fileDays)
    }
}
