import Foundation

/// Content-based blocking: text or a file path matching any of the regular expressions isn't recorded.
///
/// Ignoring by app only stops the few apps thought of in advance, while API keys, JWTs and ID numbers
/// get copied out of browsers, terminals and notes, apps that can't be ignored wholesale.
/// Blocking by content is another dimension of the same feature.
///
/// Compiled once, used repeatedly. An invalid pattern doesn't disable the whole set; only that one
/// has no effect, and the settings page flags it.
/// NSRegularExpression itself is immutable and thread-safe, and the compiled set is read-only,
/// so this value can be carried onto background threads.
public struct IgnorePatterns: @unchecked Sendable {
    public let compiled: [NSRegularExpression]
    /// The ones that failed to compile, returned verbatim for the UI to mark in red
    public let invalid: [String]

    public init(_ patterns: [String]) {
        var compiled: [NSRegularExpression] = []
        var invalid: [String] = []
        for pattern in patterns {
            let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if let regex = try? NSRegularExpression(pattern: trimmed) {
                compiled.append(regex)
            } else {
                invalid.append(pattern)
            }
        }
        self.compiled = compiled
        self.invalid = invalid
    }

    public var isEmpty: Bool { compiled.isEmpty }

    /// A match anywhere in the text counts as a hit. Empty text never matches.
    /// Only this many characters from the start of the text are examined: what we want to block are
    /// things like API keys and ID numbers, which don't hide past the 4,000th character. Same reason
    /// fuzzy search only scans the first 1000 characters.
    public static let scanLimit = 4_000

    /// How long one rule may run on one text before we give up on it.
    ///
    /// The rules are written by the user, and NSRegularExpression has no timeout setting. The scan
    /// limit alone doesn't save us: `(a+)+$` backtracks exponentially, measured 0.67 s on 24
    /// characters and 2.7 s on 26, so a 40-character copy would stall the capture queue for hours
    /// and nothing copied afterwards would be recorded. `.reportProgress` makes ICU call back
    /// periodically during a match, which is the one place a running match can be stopped.
    public static let timeLimit: TimeInterval = 0.05

    /// A rule that runs out of time counts as a hit, so the copy is not recorded.
    ///
    /// These rules exist to keep secrets out of the history. When one can't give an answer, dropping
    /// a single copy is the safe mistake; recording what might be an API key is not.
    public func matches(_ text: String) -> Bool {
        guard !text.isEmpty, !compiled.isEmpty else { return false }
        let head = text.count > Self.scanLimit ? String(text.prefix(Self.scanLimit)) : text
        let range = NSRange(head.startIndex..., in: head)
        return compiled.contains { Self.hit($0, in: head, range: range) }
    }

    private static func hit(_ regex: NSRegularExpression, in text: String, range: NSRange) -> Bool {
        let deadline = Date().addingTimeInterval(timeLimit)
        var found = false
        regex.enumerateMatches(in: text, options: [.reportProgress], range: range) { match, _, stop in
            if match != nil {
                found = true
                stop.pointee = true
            } else if Date() > deadline {
                found = true
                stop.pointee = true
            }
        }
        return found
    }

    public static func isValid(_ pattern: String) -> Bool {
        (try? NSRegularExpression(pattern: pattern)) != nil
    }
}
