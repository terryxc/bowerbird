import Foundation
import XCTest

/// The seven translations stay in step with English: same keys, same placeholders, and plurals that
/// actually inflect.
///
/// Reads the .lproj folders straight from Support/, the same files the build copies into the app.
final class LocalizationTests: XCTestCase {
    private static let languages = ["en", "zh-Hans", "zh-Hant", "ja", "es", "fr", "ru"]
    private static let support = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Support")

    private func strings(_ lang: String) throws -> [String: String] {
        let url = Self.support.appendingPathComponent("\(lang).lproj/Localizable.strings")
        return try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String], lang)
    }

    private func bundle(_ lang: String) throws -> Bundle {
        try XCTUnwrap(Bundle(url: Self.support.appendingPathComponent("\(lang).lproj")), lang)
    }

    /// The printf-style placeholders in a string, in order: %@, %lld, %1$@ …
    private func placeholders(_ s: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: "%(\\d+\\$)?(@|lld|ld|d)")
        return regex.matches(in: s, range: NSRange(s.startIndex..., in: s)).map { (s as NSString).substring(with: $0.range) }
    }

    /// Every string literal the UI hands to the localizer must be a key in the English table, or it
    /// shows up untranslated in every language without any test going red. Catches a key renamed on
    /// one side only, which happened several times while the settings copy was being trimmed.
    func testEveryKeyUsedInCodeExistsInTheTable() throws {
        var known = Set(try strings("en").keys)
        // Plural forms live in the stringsdict, keyed the same way
        let dictURL = Self.support.appendingPathComponent("en.lproj/Localizable.stringsdict")
        if let plurals = NSDictionary(contentsOf: dictURL) as? [String: Any] { known.formUnion(plurals.keys) }
        let sources = Self.support.deletingLastPathComponent().appendingPathComponent("Sources/Bowerbird")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        // L("key"), and the SwiftUI views that take a LocalizedStringKey literal as their first argument
        let pattern = #"(?:\bL\(|\bText\(|\bButton\(|\bLabel\(|\bToggle\(|SettingsCaption\(text:|SettingsRow\(title:|\bsubtitle:|SettingsEmptyText\(text:|SettingsActionButton\(|TextChip\(|\.help\(|\bhint\()\s*"((?:[^"\\]|\\.)+)""#
        let regex = try NSRegularExpression(pattern: pattern)
        var missing: [String] = []
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                let key = (text as NSString).substring(with: match.range(at: 1))
                // Interpolated literals are not keys; neither are symbol names or bare punctuation
                if key.contains("\\(") || key.count < 2 { continue }
                if !known.contains(key), !missing.contains(key) { missing.append(key) }
            }
        }
        XCTAssertEqual(missing, [], "keys used in code but absent from en.lproj: \(missing)")
    }

    func testEveryLanguageHasTheSameKeys() throws {
        let english = Set(try strings("en").keys)
        for lang in Self.languages.dropFirst() {
            let keys = Set(try strings(lang).keys)
            XCTAssertEqual(keys.subtracting(english), [], "\(lang) has keys English doesn't")
            XCTAssertEqual(english.subtracting(keys), [], "\(lang) is missing keys")
        }
    }

    func testPlaceholdersMatchEnglish() throws {
        let english = try strings("en")
        for lang in Self.languages.dropFirst() {
            for (key, value) in try strings(lang) {
                XCTAssertEqual(placeholders(value).sorted(), placeholders(english[key] ?? key).sorted(),
                               "\(lang): \"\(key)\"")
            }
        }
    }

    /// One of each, formatted the way L() formats: with the language's own locale
    func testPluralsInflect() throws {
        let cases: [(String, String, Int, String)] = [
            ("en", "Keep %lld days", 1, "Keep 1 Day"),
            ("en", "Keep %lld days", 30, "Keep 30 Days"),
            ("es", "%lld chars", 1, "1 carácter"),
            ("fr", "Keep %lld days", 1, "1 jour"),
            ("fr", "Keep %lld days", 30, "30 jours"),
            ("ru", "%lld lines", 2, "2 строки"),
            ("ru", "%lld lines", 5, "5 строк"),
        ]
        for (lang, key, n, expected) in cases {
            let format = try bundle(lang).localizedString(forKey: key, value: key, table: nil)
            XCTAssertEqual(String(format: format, locale: Locale(identifier: lang), n), expected, "\(lang) \(key) \(n)")
        }
        let fr = try bundle("fr").localizedString(forKey: "File: %@ and %lld more", value: nil, table: nil)
        XCTAssertEqual(String(format: fr, locale: Locale(identifier: "fr"), "a.txt", 1), "Fichier\u{a0}: a.txt et 1 autre")
        let ru = try bundle("ru").localizedString(forKey: "File: %@ and %lld more", value: nil, table: nil)
        XCTAssertEqual(String(format: ru, locale: Locale(identifier: "ru"), "a.txt", 5), "Файл: a.txt и ещё 5 файлов")
    }
}
