import Foundation
import SwiftUI

/// Interface language: English, Simplified Chinese, Traditional Chinese, Japanese, Spanish, French, Russian.
///
/// Switching takes effect immediately, no relaunch needed. See `Localization` for how: SwiftUI uses
/// the locale in the environment plus a forced rebuild; AppKit points explicitly at the matching `.lproj`.
enum AppLanguage: String, CaseIterable, Identifiable, Codable {
    case system
    case english = "en"
    case simplifiedChinese = "zh-Hans"
    case traditionalChinese = "zh-Hant"
    case japanese = "ja"
    case spanish = "es"
    case french = "fr"
    case russian = "ru"

    var id: String { rawValue }

    /// The language code; nil when following the system
    var localeIdentifier: String? {
        self == .system ? nil : rawValue
    }

    /// Display name in the picker. Each language name is always written in that language and never
    /// translated into the interface language: when the UI is in a language you can't read, this list
    /// is how you find your own language again.
    var endonym: String {
        switch self {
        case .system: ""            // uses the separate "follow system" translation
        case .english: "English"
        case .simplifiedChinese: "简体中文"
        case .traditionalChinese: "繁體中文"
        case .japanese: "日本語"
        case .spanish: "Español"
        case .french: "Français"
        case .russian: "Русский"
        }
    }

    var locale: Locale {
        Locale(identifier: localeIdentifier ?? Locale.current.identifier)
    }

    /// All seven of these are left-to-right
    var layoutDirection: LayoutDirection { .leftToRight }
}

/// Single entry point for looking up strings.
///
/// The system's per-app language setting (writing `AppleLanguages` to UserDefaults) only takes effect
/// on the next launch. To avoid a relaunch, the language is resolved to a specific `.lproj` bundle here.
enum Localization {
    static func bundle(for language: AppLanguage) -> Bundle {
        guard let code = language.localeIdentifier else { return .main }
        // Try the full code first (zh-Hans), then fall back to the language code (zh)
        for candidate in [code, String(code.prefix(2))] {
            if let path = Bundle.main.path(forResource: candidate, ofType: "lproj"),
               let bundle = Bundle(path: path) {
                return bundle
            }
        }
        return .main
    }
}

/// Localized string lookup for AppKit.
///
/// SwiftUI's `Text` reads the locale from the environment; AppKit has no such mechanism, so menu
/// items, window titles and system alerts all have to come through here with an explicit bundle.
@MainActor
func L(_ key: String, _ arguments: CVarArg...) -> String {
    let settings = AppSettings.shared
    let format = settings.localizationBundle
        .localizedString(forKey: key, value: key, table: nil as String?)
    guard !arguments.isEmpty else { return format }
    // A locale is required. Plural rules in Localizable.stringsdict (%#@var@) are only applied
    // with a locale; without one the output falls back to the raw form and you get "1 words".
    // And the rules must be those of the selected language, not Locale.current, which is the system language.
    return String(format: format, locale: settings.language.locale, arguments: arguments)
}

extension Notification.Name {
    static let bowerbirdLanguageChanged = Notification.Name("bowerbirdLanguageChanged")
}

/// Applies the current language to a SwiftUI root view.
///
/// `.id(language)` is the key: changing only the environment locale doesn't guarantee an existing
/// view tree re-fetches its strings; changing the id rebuilds the whole tree so the switch shows at once.
/// The panel and Settings window are small, so the rebuild cost is negligible.
struct LocalizedRoot<Content: View>: View {
    @ObservedObject private var settings = AppSettings.shared
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .environment(\.locale, settings.language.locale)
            .environment(\.layoutDirection, settings.language.layoutDirection)
            .id(settings.language)
    }
}
