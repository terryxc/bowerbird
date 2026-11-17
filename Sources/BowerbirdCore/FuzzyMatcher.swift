import Foundation

/// Typo-tolerant matching: a query with one or two wrong letters still finds its match.
///
/// Exact substring hits always rank first; this only fills in the near misses.
/// The algorithm is Wu–Manber bit-parallel approximate matching (the one agrep uses): find a substring
/// of the text within edit distance k of the query. Queries are at most 64 characters, so they fit in
/// one UInt64; each text character costs only a few bit operations, and scanning a few thousand items
/// takes milliseconds.
///
/// Enabled only for ASCII queries: Chinese has no such thing as "one wrong letter", and allowing one
/// error in a query of two or three Chinese characters would match the entire store.
public enum FuzzyMatcher {
    /// How many errors this query allows; nil means no typo tolerance.
    ///
    /// Four to six characters allow one, seven or more allow two: "recieve" needs two to match
    /// "receive", while allowing one error in three-letter words would lump git, get and gif together.
    public static func allowedErrors(for query: String) -> Int? {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let scalars = q.unicodeScalars
        guard scalars.count >= 4, scalars.count <= 64 else { return nil }
        guard scalars.allSatisfy({ $0.value >= 0x20 && $0.value <= 0x7E }) else { return nil }
        return scalars.count >= 7 ? 2 : 1
    }

    /// Whether the text has a substring within edit distance maxErrors of pattern.
    /// Returns the smallest number of errors needed if so, nil otherwise. At most two errors are allowed.
    ///
    /// The inner loop deliberately avoids arrays: each character costs only a few bit operations,
    /// and any allocation would make it ten times slower.
    public static func errors(matching pattern: String, in text: String, maxErrors: Int) -> Int? {
        let p = Array(pattern.unicodeScalars)
        guard !p.isEmpty, p.count <= 64, (0...2).contains(maxErrors) else { return nil }
        // Queries are ASCII only, so a 128-entry table is enough; non-ASCII characters in the text never match
        var table = [UInt64](repeating: 0, count: 128)
        for (i, s) in p.enumerated() {
            guard s.value < 128 else { return nil }
            table[Int(s.value)] |= 1 << UInt64(i)
        }
        let matchBit: UInt64 = 1 << UInt64(p.count - 1)

        // Bit i of r1 / r2: the first i+1 characters of pattern match some suffix of the text read so far
        // with at most 1 / 2 errors. The low d bits are always 1 (the first d characters count as deleted).
        var r0: UInt64 = 0, r1: UInt64 = 1, r2: UInt64 = 3
        var best: Int?
        for scalar in text.unicodeScalars {
            let mask = scalar.value < 128 ? table[Int(scalar.value)] : 0
            let n0 = ((r0 << 1) | 1) & mask
            var n1: UInt64 = 0, n2: UInt64 = 0
            if maxErrors >= 1 {
                n1 = (((r1 << 1) | 1) & mask)     // match one character
                    | r0                          // extra character in the text: skip it
                    | ((r0 << 1) | 1)             // substitution
                    | ((n0 << 1) | 1)             // character missing from pattern
            }
            if maxErrors >= 2 {
                n2 = (((r2 << 1) | 1) & mask) | r1 | ((r1 << 1) | 1) | ((n1 << 1) | 1)
            }
            r0 = n0; r1 = n1; r2 = n2
            if r0 & matchBit != 0 { return 0 }
            if r1 & matchBit != 0 { best = 1 } else if r2 & matchBit != 0, best == nil { best = 2 }
        }
        return best
    }
}
