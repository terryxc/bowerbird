import AppKit
import XCTest
@testable import Bowerbird

/// Highlighting must agree with what the search actually finds.
///
/// The search index is normalized on insert: it ignores case, diacritics, and full-width vs.
/// half-width. If highlighting only ignored case, searching cafe would match Café while the list bolds
/// nothing, and the user would think the match was wrong.
@MainActor
final class SearchHighlightTests: XCTestCase {
    /// The pieces of the original text that got marked
    private func marked(_ text: String, _ query: String) -> [String] {
        let ns = NSMutableAttributedString(string: text)
        SearchHighlight.mark(ns, query: query)
        var out: [String] = []
        ns.enumerateAttribute(.backgroundColor, in: NSRange(location: 0, length: ns.length)) { value, range, _ in
            if value != nil { out.append((ns.string as NSString).substring(with: range)) }
        }
        return out
    }

    func testMarksEveryOccurrence() {
        XCTAssertEqual(marked("北京、上海、北京", "北京"), ["北京", "北京"])
    }

    func testIgnoresCaseLikeTheSearchDoes() {
        XCTAssertEqual(marked("Hello HELLO hello", "hello"), ["Hello", "HELLO", "hello"])
    }

    func testIgnoresDiacriticsLikeTheSearchDoes() {
        XCTAssertEqual(marked("Café", "cafe"), ["Café"])
    }

    func testIgnoresWidthLikeTheSearchDoes() {
        XCTAssertEqual(marked("ＦＵＬＬＷＩＤＴＨ", "fullwidth"), ["ＦＵＬＬＷＩＤＴＨ"])
    }

    func testEmptyQueryMarksNothing() {
        XCTAssertTrue(marked("随便一段字", "").isEmpty)
        XCTAssertTrue(marked("随便一段字", "   ").isEmpty)
    }

    func testNoMatchMarksNothing() {
        XCTAssertTrue(marked("abc", "xyz").isEmpty)
    }

    /// Back-to-back matches must neither be missed nor get stuck.
    ///
    /// This only asserts that all four a's are marked, not that they form two runs: enumerateAttribute
    /// merges adjacent ranges with the same background value into one run. That is how enumeration
    /// behaves, not a missed mark.
    func testAdjacentMatchesAreAllMarked() {
        XCTAssertEqual(marked("aaaa", "aa").joined(), "aaaa")
        XCTAssertEqual(marked("ab ab", "ab"), ["ab", "ab"])
    }

    func testTitleMarksTheSameRangesAsTheBody() throws {
        // The title uses SwiftUI's attribute scope; NSAttributedString keys can't be used to query it
        let title = try XCTUnwrap(SearchHighlight.title("Café 北京", query: "cafe"))
        let colored = title.runs.filter { $0.foregroundColor != nil }
            .map { String(title[$0.range].characters) }
        XCTAssertEqual(colored, ["Café"], "The title and the body use the same matching rules")
    }

    /// The title path must also return no attributed string when nothing matches.
    ///
    /// This is a performance gate for the list, for a different reason than the body's: a title is a
    /// single line, so building the attributed string is cheap. What's expensive is **drawing** it.
    /// SwiftUI renders Text(AttributedString) much more slowly than Text(String), and while ↓ is held
    /// the dozen or so visible rows are redrawn on every step. Measured on a panel with 400 items: one
    /// ↓ press took 11.1 ms vs. 6.7 ms.
    func testTitleGivesNoAttributedStringWhenNothingMatches() {
        XCTAssertNil(SearchHighlight.title("一条普通的标题", query: ""))
        XCTAssertNil(SearchHighlight.title("一条普通的标题", query: "   "))
        XCTAssertNil(SearchHighlight.title("一条普通的标题", query: "xyz"))
        XCTAssertNotNil(SearchHighlight.title("一条普通的标题", query: "普通"))
    }

    /// With no match, not a single attribute should change.
    ///
    /// The preview is up to 20,000 characters and is redone on every selection change and every
    /// keystroke, and an empty search field is the normal case.
    func testNothingToMarkTouchesNothing() {
        for query in ["xyz", "", "   "] {
            let ns = NSMutableAttributedString(string: "一段没有命中的文字")
            let before = NSAttributedString(attributedString: ns)
            SearchHighlight.mark(ns, query: query)
            XCTAssertEqual(ns, before, "query=\(query)")
        }
    }

    /// The rich text path only adds a background colour; the original styling must not be touched
    func testRichTextKeepsItsOwnStylingWhenMarked() {
        let source = NSMutableAttributedString(string: "带格式的一段",
                                               attributes: [.foregroundColor: NSColor.red])
        SearchHighlight.mark(source, query: "格式")
        let hit = source.attributes(at: 1, effectiveRange: nil)
        XCTAssertEqual(hit[.foregroundColor] as? NSColor, .red, "The matched run must keep its text colour")
        XCTAssertNotNil(hit[.backgroundColor], "The matched run must get a background colour")
        XCTAssertNil(source.attributes(at: 5, effectiveRange: nil)[.backgroundColor],
                     "The unmatched run must not have a background colour")
    }

    /// Must not be visibly slow up to the 20,000-character preview limit; the search field redraws on
    /// every keystroke
    func testStaysFastOnALongPreview() {
        let text = String(repeating: "很长的一段文字，中间夹一个 needle。", count: 1200)
        let started = Date()
        let hits = marked(text, "needle")
        XCTAssertEqual(hits.count, 1200)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5)
    }
}
