import XCTest
@testable import BowerbirdCore

final class FuzzyMatcherTests: XCTestCase {
    func testExactSubstringCostsNothing() {
        XCTAssertEqual(FuzzyMatcher.errors(matching: "receive", in: "please receive this", maxErrors: 2), 0)
    }

    /// A wrong, extra or missing letter each count as one error
    func testSingleEdits() {
        XCTAssertEqual(FuzzyMatcher.errors(matching: "hello", in: "yellow", maxErrors: 1), 1, "substitution")
        XCTAssertEqual(FuzzyMatcher.errors(matching: "repot", in: "the report", maxErrors: 1), 1, "one letter missing")
        XCTAssertEqual(FuzzyMatcher.errors(matching: "reportt", in: "report", maxErrors: 1), 1, "one letter extra")
    }

    /// Two swapped letters count as two errors: no match with one allowed, a match only with two
    func testTranspositionCostsTwo() {
        XCTAssertNil(FuzzyMatcher.errors(matching: "recieve", in: "receive", maxErrors: 1))
        XCTAssertEqual(FuzzyMatcher.errors(matching: "recieve", in: "receive", maxErrors: 2), 2)
    }

    func testTooDifferentIsNil() {
        XCTAssertNil(FuzzyMatcher.errors(matching: "kitten", in: "sitting on the mat", maxErrors: 1))
        XCTAssertNil(FuzzyMatcher.errors(matching: "abcd", in: "", maxErrors: 2))
    }

    /// No fuzzy matching for short words, Chinese, or very long queries
    func testAllowance() {
        XCTAssertNil(FuzzyMatcher.allowedErrors(for: "git"), "allowing one error on three letters would mix in get and gif")
        XCTAssertEqual(FuzzyMatcher.allowedErrors(for: "cask"), 1)
        XCTAssertEqual(FuzzyMatcher.allowedErrors(for: "receive"), 2)
        XCTAssertNil(FuzzyMatcher.allowedErrors(for: "会议改到周四"), "Chinese has no such thing as a mistyped letter")
        XCTAssertNil(FuzzyMatcher.allowedErrors(for: String(repeating: "a", count: 65)))
    }

    /// Fuzzy matches appear only when nothing matches exactly, and are marked as such
    func testStoreFallsBackToFuzzyOnlyWhenNothingMatchesExactly() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bowerbird-fuzzy-\(UUID().uuidString)", isDirectory: true)
        let store = try HistoryStore(databaseURL: nil, imagesDirectory: dir)
        defer { try? FileManager.default.removeItem(at: dir) }
        func record(_ t: String, at: Date) throws -> ClipItem {
            try store.record(ClipCapture(assets: [.init(type: .string, data: Data(t.utf8))], kind: .text, text: t),
                             sourceBundleID: nil, at: at)
        }
        let t0 = Date(timeIntervalSince1970: 1_000)
        let typo = try record("we recieve the invoice", at: t0.addingTimeInterval(3))   // the typo
        let exact = try record("receive the goods", at: t0.addingTimeInterval(1))       // exact, but older
        _ = try record("nothing to do with it", at: t0.addingTimeInterval(2))

        // One exact hit exists: the typo'd item is not shown, however close it is
        let page = try store.searchPage("receive")
        XCTAssertEqual(page.items.map(\.id), [exact.id], "the exact match alone")
        XCTAssertEqual(page.fuzzyIDs, [])
        XCTAssertEqual(try store.searchPage("receive", limit: 1, offset: 1).items, [],
                       "paging past the exact matches does not continue into fuzzy ones")

        // No exact hit at all ("receve" occurs nowhere): fuzzy fills in, and pages on its own.
        // Both items are one letter off, so they keep their time order, newest first.
        let fuzzyPage = try store.searchPage("receve")
        XCTAssertEqual(fuzzyPage.items.map(\.id), [typo.id, exact.id])
        XCTAssertEqual(fuzzyPage.fuzzyIDs, Set([typo.id!, exact.id!]))
        let second = try store.searchPage("receve", limit: 1, offset: 1)
        XCTAssertEqual(second.items.map(\.id), [exact.id])
        XCTAssertEqual(second.fuzzyIDs, [exact.id!])
    }
}

final class IgnorePatternsTests: XCTestCase {
    func testMatchesAnywhere() {
        let rules = IgnorePatterns(["sk-[A-Za-z0-9]{8,}", "^\\d{18}$"])
        XCTAssertTrue(rules.matches("token: sk-abcdefgh12345678 end"))
        XCTAssertTrue(rules.matches("110101199001011234"))
        XCTAssertFalse(rules.matches("plain sentence"))
        XCTAssertFalse(rules.matches(""))
    }

    /// One bad pattern doesn't affect the rest, and it can be reported which one it was
    func testInvalidPatternIsReportedNotFatal() {
        let rules = IgnorePatterns(["[unclosed", "secret", "  "])
        XCTAssertEqual(rules.invalid, ["[unclosed"])
        XCTAssertEqual(rules.compiled.count, 1)
        XCTAssertTrue(rules.matches("my secret"))
        XCTAssertFalse(IgnorePatterns.isValid("(("))
    }

    /// A rule with catastrophic backtracking must not stall capture.
    ///
    /// Without a time limit `(a+)+$` on 40 characters runs for hours (measured 2.7 s at 26 and
    /// quadrupling every two characters), and the capture queue is serial, so every later copy would
    /// be lost too. A rule that gives up counts as a hit: dropping one copy beats recording a secret.
    func testARunawayRuleGivesUpQuicklyAndCountsAsAHit() {
        let rules = IgnorePatterns(["(a+)+$"])
        let text = String(repeating: "a", count: 40) + "!"
        let start = Date()
        XCTAssertTrue(rules.matches(text))
        XCTAssertLessThan(Date().timeIntervalSince(start), 1, "the rule should be cut off near its 50 ms budget")
    }
}
