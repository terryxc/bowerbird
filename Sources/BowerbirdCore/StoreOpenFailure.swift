import Foundation
import GRDB

/// Why the database couldn't be opened.
///
/// Reason for existing: only "the file really is broken" justifies renaming the old database and
/// rebuilding an empty one. Before this, AppDelegate rebuilt on any error, and the SQLITE_BUSY thrown
/// when another instance holds the lock looks exactly like "corrupt" in the catch, so as soon as a
/// second instance launched, the user's whole history was replaced by an empty database. The
/// classification keeps that destructive path for the errors that really warrant it.
public enum StoreOpenFailure: Equatable, Sendable {
    /// The file isn't an SQLite database, or page checks fail. Rebuilding is the only way out.
    case corrupt
    /// Someone else holds the lock. Most likely another Bowerbird instance; the database itself is fine.
    case busy
    /// Anything else: directory not writable, disk full, permissions changed... Touching the user's
    /// database solves none of these.
    case other

    public static func classify(_ error: Error) -> StoreOpenFailure {
        guard let error = error as? DatabaseError else { return .other }
        switch error.resultCode {
        case .SQLITE_CORRUPT, .SQLITE_NOTADB: return .corrupt
        case .SQLITE_BUSY, .SQLITE_LOCKED: return .busy
        default: return .other
        }
    }

    /// The only case in which the user's existing database may be touched.
    public var justifiesRebuild: Bool { self == .corrupt }
}
