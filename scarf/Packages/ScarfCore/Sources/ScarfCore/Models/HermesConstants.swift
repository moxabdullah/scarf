import Foundation
#if canImport(SQLite3)
import SQLite3
#endif

// MARK: - SQLite Constants

#if canImport(SQLite3)
/// SQLITE_TRANSIENT tells SQLite to make its own copy of bound string data.
/// The C macro is defined as ((sqlite3_destructor_type)-1) which can't be imported directly into Swift.
///
/// Gated behind `canImport(SQLite3)` so this file compiles on Linux (where
/// SPM has no built-in `SQLite3` system module). Apple platforms — the only
/// runtime targets that actually execute this code — compile it unchanged.
public nonisolated let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
#endif

// MARK: - Query Defaults

public enum QueryDefaults: Sendable {
    public nonisolated static let sessionLimit = 100
    public nonisolated static let messageSearchLimit = 50
    public nonisolated static let toolCallLimit = 50
    public nonisolated static let sessionPreviewLimit = 10
    public nonisolated static let previewContentLength = 100
    public nonisolated static let logLineLimit = 200
    public nonisolated static let defaultSilenceThreshold = 200
}

/// Page sizes for `HermesDataService.fetchMessages(sessionId:limit:before:)`.
/// Centralized so iOS, Mac, and the polling code paths can pick a
/// consistent budget — and so we have one knob to retune if perf
/// concerns shift.
public enum HistoryPageSize: Sendable {
    /// Initial chat-history load. **Sized to fit the SSH wire payload
    /// inside a 30-second `RemoteSQLiteBackend.queryTimeout`.** A
    /// 157-message session at 200-row page size produced enough
    /// JSON (with `reasoning_content` for thinking models) to time
    /// out at exactly 30 s on a 420 ms-RTT remote, returning empty.
    /// 50 rows comfortably fits that envelope. The "Load earlier"
    /// affordance pages back through older messages on demand.
    public nonisolated static let initial = 50
    /// Reconnection reconcile against the DB. 200 rows is plenty —
    /// disconnects don't generate hundreds of unseen messages.
    public nonisolated static let reconcile = 200
    /// Mac sessions detail view. Larger to reduce paging UX in the
    /// desktop browser-style read; the desktop has the screen real
    /// estate and memory headroom for it.
    public nonisolated static let macSessionDetail = 500
    /// Terminal-mode polling refresh. Same 500-row budget as Mac
    /// detail; covers sessions long enough that the user is actively
    /// scrolling but bounded to keep each poll tick cheap.
    public nonisolated static let polling = 500
}

// MARK: - File Size Formatting

public enum FileSizeUnit: Sendable {
    public nonisolated static let kilobyte = 1_024.0
    public nonisolated static let megabyte = 1_048_576.0
}
