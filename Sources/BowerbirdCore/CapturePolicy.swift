import Foundation

/// Whether to record this copy, and by which rules.
///
/// A snapshot rather than a few closures: the heavy capture work (decoding images, converting to PNG,
/// extracting plain text) runs on a background thread, while these switches live in the main-thread
/// settings object, which the background can't just read. The main thread takes a snapshot on every
/// tick and hands it over, so the decision can be made entirely in the background.
public struct CapturePolicy: Sendable {
    /// Kinds still being recorded
    public var kinds: Set<ClipKind>
    /// Whether to accept content arriving via Universal Clipboard
    public var acceptsRemote: Bool
    /// Content matching any of these regexes isn't recorded
    public var ignorePatterns: IgnorePatterns

    public init(kinds: Set<ClipKind>, acceptsRemote: Bool, ignorePatterns: IgnorePatterns) {
        self.kinds = kinds
        self.acceptsRemote = acceptsRemote
        self.ignorePatterns = ignorePatterns
    }

    public func allows(_ capture: ClipCapture) -> Bool {
        guard kinds.contains(capture.kind) else { return false }
        // Files are matched on their paths, everything else on the text
        let subject = capture.kind == .file ? capture.filePaths.joined(separator: "\n") : capture.text
        return !ignorePatterns.matches(subject)
    }
}
