import AppKit
import SwiftUI

/// Marks the parts that match the search query.
///
/// The list and the preview share this one rule. It used to be only the list that highlighted and
/// not the preview: there was a match, but only the left side told you where, and you had to hunt
/// through a whole screen of text on the right yourself.
///
/// The matching rules must line up with the actual search, otherwise you get "found but not
/// highlighted": `search_text` is normalized when recorded (insensitive to case, diacritics and
/// full/half width), so the same three options are used here. Early on this only ignored case, and
/// searching `cafe` matched `Café` without a single character in the list turning bold.
@MainActor
enum SearchHighlight {
    /// The three options that correspond to HistoryStore.fold
    private static let options: NSString.CompareOptions =
        [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]

    /// Matches in the title: bold and accent colour. Returns nil when nothing matches, and the caller
    /// draws plain text as usual.
    ///
    /// Only bold, no size change, so the row height doesn't jump. The title is a single line, and the
    /// extra weight is easy to spot at a glance.
    ///
    /// **It must return nil when nothing matches.** The saving isn't in building the attributed string
    /// (the title is one line; building it takes 1 µs) but in **drawing** it: SwiftUI draws
    /// `Text(AttributedString)` far more expensively than `Text(String)`, and every arrow key press
    /// redraws the dozen or so visible rows. Measured on a 400-clip panel, one ↓ press went from
    /// 11.1 ms to 6.7 ms. The search field is empty most of the time, so this cost should never have
    /// been paid. Same rule as for the body.
    static func title(_ text: String, query: String) -> AttributedString? {
        let hits = ranges(in: text, query: query)
        guard !hits.isEmpty else { return nil }
        var out = AttributedString(text)
        for range in hits.compactMap({ Range($0, in: out) }) {
            out[range].font = .system(size: PanelMetrics.rowTitleFontSize, weight: .bold)
            out[range].foregroundColor = AppColors.accent
        }
        return out
    }

    /// Matches in the body: lay a background colour over the attributed string, modified in place.
    ///
    /// It doesn't bold like the title, for two reasons: the body is running text, and bolding each
    /// matched word breaks the rhythm of the paragraph; and bold is wider, so the text re-wraps and the
    /// whole paragraph jitters while the query is being typed, which is unpleasant. A background colour
    /// is a pure marker and doesn't move a single pixel.
    ///
    /// The background colour is a dedicated shade (AppColors.searchMatch), heavier than the selected
    /// row's: laid over just a few characters, the area is too small and the row shade is too faint to see.
    ///
    /// Matches are found on the **plain string** first: previews go up to 20,000 characters, and
    /// repeated searching on an attributed string walks grapheme clusters, which is much slower.
    /// With the search field empty, not a single attribute is touched here.
    ///
    /// Plain and rich text share this entry point. The former's attributed string is built on the
    /// spot, the latter's is parsed; by this point both are attributed strings, so there is no reason
    /// for two code paths.
    static func mark(_ text: NSMutableAttributedString, query: String) {
        // Stop here when the search field is empty. `text.string` bridges 20,000 characters from
        // NSString back to String, which is a real copy; we can't wait until inside ranges to check.
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let hits = ranges(in: text.string, query: query)
        guard !hits.isEmpty else { return }
        let wash = NSColor(AppColors.searchMatch)
        for range in hits where NSMaxRange(range) <= text.length {
            text.addAttribute(.backgroundColor, value: wash, range: range)
        }
    }

    /// Where the matches are. Searched with NSString rather than AttributedString's range(of:):
    /// previews go up to 20,000 characters, and repeated searching on an attributed string walks
    /// grapheme clusters, which is much slower.
    private static func ranges(in text: String, query: String) -> [NSRange] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        let haystack = text as NSString
        var found: [NSRange] = []
        var cursor = 0
        while cursor < haystack.length {
            let remaining = NSRange(location: cursor, length: haystack.length - cursor)
            let hit = haystack.range(of: needle, options: options, range: remaining)
            guard hit.location != NSNotFound else { break }
            found.append(hit)
            // Use max(…, 1) for the length: after normalization a zero-length match is possible, and
            // without this guard it loops forever
            cursor = hit.location + max(hit.length, 1)
        }
        return found
    }
}
