// MARK: - Platform gate
//
// This file's row-parsing helpers used to lean on libsqlite3 directly
// (`sqlite3_column_*`); after the v2.7 backend split they go through
// the typed `Row` API and don't actually need the SQLite3 module.
// The gate stays for symmetry with the backend files (LocalSQLiteBackend
// imports SQLite3) and to keep ScarfCore's compile target narrow.
#if canImport(SQLite3)

import Foundation
#if canImport(os)
import os
#endif

/// Read-only data service over Hermes's `state.db`. Routes every query
/// through a `HermesQueryBackend`:
///
/// * `LocalSQLiteBackend` for `ServerContext.local` — opens the live
///   `~/.hermes/state.db` via libsqlite3. Microseconds per query.
/// * `RemoteSQLiteBackend` for `.ssh` contexts — runs `sqlite3 -json`
///   over an SSH session per query (ControlMaster keeps the channel
///   warm). 50–100 ms per query, but no full-DB transfers and always-
///   fresh data, even for multi-GB DBs (issue #74).
///
/// The split happened in v2.7 to fix the "5 GB state.db means 7-minute
/// snapshots every refresh" issue. Local performance is unchanged;
/// remote bandwidth scales with query result size, not DB size.
public actor HermesDataService {
    private static let logger = Logger(subsystem: "com.scarf", category: "HermesDataService")

    private let backend: any HermesQueryBackend
    public let context: ServerContext
    private let transport: any ServerTransport

    /// Cached schema fingerprint, populated on `open()`. Keeps the
    /// SELECT-shape builders (`sessionColumns`, `messageColumns`)
    /// synchronous — without this they'd `await backend.hasV07Schema`
    /// on every call.
    private var hasV07Schema = false
    private var hasV011Schema = false

    /// Last error from `open()` / `refresh()`, user-presentable. `nil`
    /// means the last attempt succeeded. Views surface this when their
    /// own load path fails, so the user sees "Permission denied
    /// reading state.db" instead of an empty Dashboard with no
    /// explanation.
    public private(set) var lastOpenError: String?

    public init(context: ServerContext = .local) {
        self.context = context
        self.transport = context.makeTransport()
        if context.isRemote {
            self.backend = RemoteSQLiteBackend(context: context, transport: self.transport)
        } else {
            self.backend = LocalSQLiteBackend(context: context)
        }
    }

    /// Test seam — inject any `HermesQueryBackend`. Production code
    /// should use the `init(context:)` overload.
    internal init(context: ServerContext, backend: any HermesQueryBackend) {
        self.context = context
        self.transport = context.makeTransport()
        self.backend = backend
    }

    // MARK: - Lifecycle

    public func open() async -> Bool {
        let ok = await backend.open()
        // Cache schema flags — sessionColumns / messageColumns are
        // hot paths (called on every fetch* method) and going async
        // for them would force every fetch into a multi-await pattern.
        hasV07Schema = await backend.hasV07Schema
        hasV011Schema = await backend.hasV011Schema
        lastOpenError = await backend.lastOpenError
        return ok
    }

    @discardableResult
    public func refresh(forceFresh: Bool = false) async -> Bool {
        let ok = await backend.refresh(forceFresh: forceFresh)
        hasV07Schema = await backend.hasV07Schema
        hasV011Schema = await backend.hasV011Schema
        lastOpenError = await backend.lastOpenError
        return ok
    }

    public func close() async {
        await backend.close()
    }

    /// Turn a transport / backend error into the one-line string Dashboard
    /// shows. Adds hints for the common "sqlite3 not installed" and
    /// "permission denied" cases so users know what to do. Mirrors the
    /// pre-v2.7 humanise behaviour exactly so existing UI banners
    /// continue to render with the same copy.
    private nonisolated func humanize(_ error: Error) -> String {
        let desc = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        let lower = desc.lowercased()
        if lower.contains("sqlite3: command not found") || lower.contains("sqlite3: not found") {
            return "sqlite3 is not installed on \(context.displayName). Install it with `apt install sqlite3` (Ubuntu/Debian) or `yum install sqlite` (RHEL/Fedora)."
        }
        if lower.contains("permission denied") {
            return "Permission denied reading Hermes state on \(context.displayName). The SSH user may not have read access to ~/.hermes/state.db — try Run Diagnostics."
        }
        if lower.contains("no such file") || lower.contains("unable to open database file") {
            return "Hermes state not found at ~/.hermes on \(context.displayName). If Hermes is installed elsewhere, set its data directory in Manage Servers."
        }
        return desc
    }

    // MARK: - Column shapes

    private var sessionColumns: String {
        var cols = """
            id, source, user_id, model, title, parent_session_id,
            started_at, ended_at, end_reason, message_count, tool_call_count,
            input_tokens, output_tokens, cache_read_tokens, cache_write_tokens,
            estimated_cost_usd
            """
        if hasV07Schema {
            cols += ", reasoning_tokens, actual_cost_usd, cost_status, billing_provider"
        }
        if hasV011Schema {
            cols += ", api_call_count"
        }
        return cols
    }

    private var messageColumns: String {
        var cols = """
            id, session_id, role, content, tool_call_id, tool_calls,
            tool_name, timestamp, token_count, finish_reason
            """
        if hasV07Schema {
            cols += ", reasoning"
        }
        if hasV011Schema {
            cols += ", reasoning_content"
        }
        return cols
    }

    /// Same as `messageColumns` but with the `reasoning_content`
    /// column omitted. v0.11+ Hermes thinking-model output stores
    /// the full chain-of-thought transcript in `reasoning_content`,
    /// which on a single message can be 20+ KB of JSON. For a
    /// 160-message session that's >1 MB of wire payload — enough
    /// to time out a 30s SSH `sqlite3 -json` fetch on a 420ms-RTT
    /// remote (perf capture confirmed). The bubble's main body
    /// doesn't render reasoning_content directly; the inspector
    /// pane does, and the user opens that on demand. So initial
    /// fetch can skip it and a follow-up `fetchReasoningContent`
    /// can pull it lazily when the inspector opens.
    private var messageColumnsLight: String {
        var cols = """
            id, session_id, role, content, tool_call_id, tool_calls,
            tool_name, timestamp, token_count, finish_reason
            """
        if hasV07Schema {
            cols += ", reasoning"
        }
        // v0.11+ `reasoning_content` is intentionally excluded.
        // `messageFromRow` defaults it to nil; callers that need it
        // call `fetchReasoningContent(for:)` to lazy-load.
        return cols
    }

    // MARK: - Session Queries

    public func fetchSessions(limit: Int = QueryDefaults.sessionLimit) async -> [HermesSession] {
        let sql = "SELECT \(sessionColumns) FROM sessions WHERE parent_session_id IS NULL ORDER BY started_at DESC LIMIT ?"
        do {
            let rows = try await backend.query(sql, params: [.integer(Int64(limit))])
            return rows.map { sessionFromRow($0) }
        } catch {
            Self.logger.warning("fetchSessions failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    public func fetchSessionsInPeriod(since: Date) async -> [HermesSession] {
        let sql = "SELECT \(sessionColumns) FROM sessions WHERE parent_session_id IS NULL AND started_at >= ? ORDER BY started_at DESC"
        do {
            let rows = try await backend.query(sql, params: [.real(since.timeIntervalSince1970)])
            return rows.map { sessionFromRow($0) }
        } catch {
            return []
        }
    }

    public func fetchSubagentSessions(parentId: String) async -> [HermesSession] {
        let sql = "SELECT \(sessionColumns) FROM sessions WHERE parent_session_id = ? ORDER BY started_at ASC"
        do {
            let rows = try await backend.query(sql, params: [.text(parentId)])
            return rows.map { sessionFromRow($0) }
        } catch {
            return []
        }
    }

    // MARK: - Message Queries

    /// Bounded message fetch keyed by message id (monotonic per row,
    /// safer than timestamp-based pagination because streaming chunk
    /// timestamps can collide). Returns the most recent `limit`
    /// messages older than `before` (when supplied) in chronological
    /// (ASC) order ready to display. Pass `before: nil` for the
    /// initial load — the DB returns the newest `limit` rows.
    public func fetchMessages(
        sessionId: String,
        limit: Int,
        before: Int? = nil
    ) async -> [HermesMessage] {
        await ScarfMon.measureAsync(.sessionLoad, "mac.fetchMessages") {
            // Use the lite column set — excludes reasoning_content which
            // can be 20+ KB per message on thinking-model sessions and
            // was the cause of repeated 30s SSH timeouts on 100+-message
            // sessions over 420ms-RTT remote links. The inspector pane
            // calls `fetchReasoningContent(for:)` to lazy-load when the
            // user opens a message's disclosure.
            let sql: String
            let params: [SQLValue]
            if let before {
                sql = "SELECT \(messageColumnsLight) FROM messages WHERE session_id = ? AND id < ? ORDER BY id DESC LIMIT ?"
                params = [.text(sessionId), .integer(Int64(before)), .integer(Int64(limit))]
            } else {
                sql = "SELECT \(messageColumnsLight) FROM messages WHERE session_id = ? ORDER BY id DESC LIMIT ?"
                params = [.text(sessionId), .integer(Int64(limit))]
            }
            do {
                let rows = try await backend.query(sql, params: params)
                // Caller wants chronological (oldest-first) order; the SELECT
                // is DESC for the LIMIT to bite the newest rows, so reverse.
                let messages = rows.map { messageFromRow($0) }.reversed() as [HermesMessage]
                ScarfMon.event(.sessionLoad, "mac.fetchMessages.rows", count: messages.count)
                return messages
            } catch {
                return []
            }
        }
    }

    /// Lazy-load the `reasoning_content` for a single message. Called
    /// when the user expands the inspector disclosure on a thinking-model
    /// reply that has reasoning available (i.e. the message has v0.11
    /// schema). Cheap on a single message — avoids the bulk-fetch
    /// payload-size problem that motivated `messageColumnsLight`.
    public func fetchReasoningContent(for messageId: Int) async -> String? {
        guard hasV011Schema else { return nil }
        let sql = "SELECT reasoning_content FROM messages WHERE id = ?"
        do {
            let rows = try await backend.query(sql, params: [.integer(Int64(messageId))])
            return rows.first?.optionalString(at: 0)
        } catch {
            Self.logger.warning("fetchReasoningContent failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Legacy unbounded fetch retained for one release cycle so any
    /// out-of-tree consumers don't break. New code should use the
    /// bounded `fetchMessages(sessionId:limit:before:)` variant —
    /// loads on 1000+-message sessions stall the UI when they
    /// materialise the whole history at once.
    @available(*, deprecated, message: "Use fetchMessages(sessionId:limit:before:) instead.")
    public func fetchMessages(sessionId: String) async -> [HermesMessage] {
        let sql = "SELECT \(messageColumns) FROM messages WHERE session_id = ? ORDER BY timestamp ASC"
        do {
            let rows = try await backend.query(sql, params: [.text(sessionId)])
            return rows.map { messageFromRow($0) }
        } catch {
            return []
        }
    }

    public func searchMessages(query: String, limit: Int = QueryDefaults.messageSearchLimit) async -> [HermesMessage] {
        let sanitized = sanitizeFTSQuery(query)
        guard !sanitized.isEmpty else { return [] }
        var msgCols = "m.id, m.session_id, m.role, m.content, m.tool_call_id, m.tool_calls, m.tool_name, m.timestamp, m.token_count, m.finish_reason"
        if hasV07Schema { msgCols += ", m.reasoning" }
        if hasV011Schema { msgCols += ", m.reasoning_content" }
        let sql = """
            SELECT \(msgCols)
            FROM messages_fts fts
            JOIN messages m ON m.id = fts.rowid
            WHERE messages_fts MATCH ?
            ORDER BY rank
            LIMIT ?
            """
        do {
            let rows = try await backend.query(sql, params: [.text(sanitized), .integer(Int64(limit))])
            return rows.map { messageFromRow($0) }
        } catch {
            return []
        }
    }

    public func fetchToolResult(callId: String) async -> String? {
        let sql = "SELECT content FROM messages WHERE role = 'tool' AND tool_call_id = ? LIMIT 1"
        do {
            let rows = try await backend.query(sql, params: [.text(callId)])
            guard let first = rows.first else { return nil }
            return first.string(at: 0)
        } catch {
            return nil
        }
    }

    public func fetchRecentToolCalls(limit: Int = QueryDefaults.toolCallLimit) async -> [HermesMessage] {
        let sql = """
            SELECT \(messageColumns)
            FROM messages
            WHERE tool_calls IS NOT NULL AND tool_calls != '[]' AND tool_calls != ''
            ORDER BY timestamp DESC
            LIMIT ?
            """
        do {
            let rows = try await backend.query(sql, params: [.integer(Int64(limit))])
            return rows.map { messageFromRow($0) }
        } catch {
            return []
        }
    }

    public func fetchSessionPreviews(limit: Int = QueryDefaults.sessionPreviewLimit) async -> [String: String] {
        let sql = """
            SELECT m.session_id, substr(m.content, 1, \(QueryDefaults.previewContentLength))
            FROM messages m
            INNER JOIN (
                SELECT session_id, MIN(id) as min_id
                FROM messages
                WHERE role = 'user' AND content <> ''
                GROUP BY session_id
            ) first ON m.id = first.min_id
            ORDER BY m.timestamp DESC
            LIMIT ?
            """
        do {
            let rows = try await backend.query(sql, params: [.integer(Int64(limit))])
            var previews: [String: String] = [:]
            for row in rows {
                previews[row.string(at: 0)] = row.string(at: 1)
            }
            return previews
        } catch {
            return [:]
        }
    }

    // MARK: - Single-Row Queries

    public struct MessageFingerprint: Equatable, Sendable {
        let count: Int
        let maxId: Int
        let maxTimestamp: Double

        static let empty = MessageFingerprint(count: 0, maxId: 0, maxTimestamp: 0)
    }

    public func fetchMessageFingerprint(sessionId: String) async -> MessageFingerprint {
        let sql = "SELECT COUNT(*), COALESCE(MAX(id), 0), COALESCE(MAX(timestamp), 0) FROM messages WHERE session_id = ?"
        do {
            let rows = try await backend.query(sql, params: [.text(sessionId)])
            guard let row = rows.first else { return .empty }
            return MessageFingerprint(
                count: row.int(at: 0),
                maxId: row.int(at: 1),
                maxTimestamp: row.double(at: 2)
            )
        } catch {
            return .empty
        }
    }

    public func fetchMessageCount(sessionId: String) async -> Int {
        let sql = "SELECT COUNT(*) FROM messages WHERE session_id = ?"
        do {
            let rows = try await backend.query(sql, params: [.text(sessionId)])
            return rows.first?.int(at: 0) ?? 0
        } catch {
            return 0
        }
    }

    public func fetchSession(id: String) async -> HermesSession? {
        let sql = "SELECT \(sessionColumns) FROM sessions WHERE id = ? LIMIT 1"
        do {
            let rows = try await backend.query(sql, params: [.text(id)])
            return rows.first.map { sessionFromRow($0) }
        } catch {
            return nil
        }
    }

    public func fetchMostRecentlyActiveSessionId() async -> String? {
        let sql = "SELECT session_id FROM messages ORDER BY timestamp DESC LIMIT 1"
        do {
            let rows = try await backend.query(sql, params: [])
            return rows.first?.optionalString(at: 0)
        } catch {
            return nil
        }
    }

    public func fetchMostRecentlyStartedSessionId(after: Date? = nil) async -> String? {
        let sql: String
        let params: [SQLValue]
        if let after {
            sql = "SELECT id FROM sessions WHERE parent_session_id IS NULL AND started_at > ? ORDER BY started_at DESC LIMIT 1"
            params = [.real(after.timeIntervalSince1970)]
        } else {
            sql = "SELECT id FROM sessions WHERE parent_session_id IS NULL ORDER BY started_at DESC LIMIT 1"
            params = []
        }
        do {
            let rows = try await backend.query(sql, params: params)
            return rows.first?.optionalString(at: 0)
        } catch {
            return nil
        }
    }

    // MARK: - Stats

    public struct SessionStats: Sendable {
        public let totalSessions: Int
        public let totalMessages: Int
        public let totalToolCalls: Int
        public let totalInputTokens: Int
        public let totalOutputTokens: Int
        public let totalCostUSD: Double
        public let totalReasoningTokens: Int
        public let totalActualCostUSD: Double

        public init(
            totalSessions: Int,
            totalMessages: Int,
            totalToolCalls: Int,
            totalInputTokens: Int,
            totalOutputTokens: Int,
            totalCostUSD: Double,
            totalReasoningTokens: Int,
            totalActualCostUSD: Double
        ) {
            self.totalSessions = totalSessions
            self.totalMessages = totalMessages
            self.totalToolCalls = totalToolCalls
            self.totalInputTokens = totalInputTokens
            self.totalOutputTokens = totalOutputTokens
            self.totalCostUSD = totalCostUSD
            self.totalReasoningTokens = totalReasoningTokens
            self.totalActualCostUSD = totalActualCostUSD
        }

        public static let empty = SessionStats(
            totalSessions: 0, totalMessages: 0, totalToolCalls: 0,
            totalInputTokens: 0, totalOutputTokens: 0, totalCostUSD: 0,
            totalReasoningTokens: 0, totalActualCostUSD: 0
        )
    }

    public func fetchStats() async -> SessionStats {
        let sql = statsSQL()
        do {
            let rows = try await backend.query(sql, params: [])
            return rows.first.map { statsFromRow($0) } ?? .empty
        } catch {
            return .empty
        }
    }

    private func statsSQL() -> String {
        if hasV07Schema {
            return """
                SELECT COUNT(*), COALESCE(SUM(message_count),0), COALESCE(SUM(tool_call_count),0),
                       COALESCE(SUM(input_tokens),0), COALESCE(SUM(output_tokens),0),
                       COALESCE(SUM(estimated_cost_usd),0),
                       COALESCE(SUM(reasoning_tokens),0), COALESCE(SUM(actual_cost_usd),0)
                FROM sessions
                """
        }
        return """
            SELECT COUNT(*), COALESCE(SUM(message_count),0), COALESCE(SUM(tool_call_count),0),
                   COALESCE(SUM(input_tokens),0), COALESCE(SUM(output_tokens),0),
                   COALESCE(SUM(estimated_cost_usd),0)
            FROM sessions
            """
    }

    private func statsFromRow(_ row: Row) -> SessionStats {
        SessionStats(
            totalSessions: row.int(at: 0),
            totalMessages: row.int(at: 1),
            totalToolCalls: row.int(at: 2),
            totalInputTokens: row.int(at: 3),
            totalOutputTokens: row.int(at: 4),
            totalCostUSD: row.double(at: 5),
            totalReasoningTokens: hasV07Schema ? row.int(at: 6) : 0,
            totalActualCostUSD: hasV07Schema ? row.double(at: 7) : 0
        )
    }

    // MARK: - Insights Queries

    public func fetchUserMessageCount(since: Date) async -> Int {
        let sql = """
            SELECT COUNT(*) FROM messages m
            JOIN sessions s ON m.session_id = s.id
            WHERE m.role = 'user' AND s.parent_session_id IS NULL AND s.started_at >= ?
            """
        do {
            let rows = try await backend.query(sql, params: [.real(since.timeIntervalSince1970)])
            return rows.first?.int(at: 0) ?? 0
        } catch {
            return 0
        }
    }

    public func fetchToolUsage(since: Date) async -> [(name: String, count: Int)] {
        let sql = """
            SELECT m.tool_name, COUNT(*) as cnt
            FROM messages m
            JOIN sessions s ON m.session_id = s.id
            WHERE m.tool_name IS NOT NULL AND m.tool_name <> '' AND s.parent_session_id IS NULL AND s.started_at >= ?
            GROUP BY m.tool_name
            ORDER BY cnt DESC
            """
        do {
            let rows = try await backend.query(sql, params: [.real(since.timeIntervalSince1970)])
            return rows.map { (name: $0.string(at: 0), count: $0.int(at: 1)) }
        } catch {
            return []
        }
    }

    public func fetchSessionStartHours(since: Date) async -> [Int: Int] {
        let sql = """
            SELECT started_at FROM sessions WHERE parent_session_id IS NULL AND started_at >= ?
            """
        do {
            let rows = try await backend.query(sql, params: [.real(since.timeIntervalSince1970)])
            var hours: [Int: Int] = [:]
            let calendar = Calendar.current
            for row in rows {
                if let date = row.date(at: 0) {
                    let hour = calendar.component(.hour, from: date)
                    hours[hour, default: 0] += 1
                }
            }
            return hours
        } catch {
            return [:]
        }
    }

    public func fetchSessionDaysOfWeek(since: Date) async -> [Int: Int] {
        let sql = """
            SELECT started_at FROM sessions WHERE parent_session_id IS NULL AND started_at >= ?
            """
        do {
            let rows = try await backend.query(sql, params: [.real(since.timeIntervalSince1970)])
            var days: [Int: Int] = [:]
            let calendar = Calendar.current
            for row in rows {
                if let date = row.date(at: 0) {
                    let weekday = (calendar.component(.weekday, from: date) + 5) % 7 // Mon=0
                    days[weekday, default: 0] += 1
                }
            }
            return days
        } catch {
            return [:]
        }
    }

    // MARK: - Batched snapshots

    /// Bundle the four queries Dashboard fires on every load into one
    /// backend round-trip. For local backends this is just four
    /// sequential `query` calls (no perf change). For remote backends
    /// it's one SSH round-trip running one sqlite3 invocation, which
    /// turns Dashboard's "open" cost from ~280 ms (4 × 70 ms) into
    /// ~80–100 ms.
    public struct DashboardSnapshot: Sendable {
        public let stats: SessionStats
        public let recentSessions: [HermesSession]
        public let sessionPreviews: [String: String]
        public let recentToolCalls: [HermesMessage]
    }

    public func dashboardSnapshot(
        sessionLimit: Int = 5,
        previewLimit: Int = 5,
        toolCallLimit: Int = 8
    ) async -> DashboardSnapshot {
        let statements: [(sql: String, params: [SQLValue])] = [
            (statsSQL(), []),
            (
                "SELECT \(sessionColumns) FROM sessions WHERE parent_session_id IS NULL ORDER BY started_at DESC LIMIT ?",
                [.integer(Int64(sessionLimit))]
            ),
            (
                """
                SELECT m.session_id, substr(m.content, 1, \(QueryDefaults.previewContentLength))
                FROM messages m
                INNER JOIN (
                    SELECT session_id, MIN(id) as min_id
                    FROM messages
                    WHERE role = 'user' AND content <> ''
                    GROUP BY session_id
                ) first ON m.id = first.min_id
                ORDER BY m.timestamp DESC
                LIMIT ?
                """,
                [.integer(Int64(previewLimit))]
            ),
            (
                """
                SELECT \(messageColumns)
                FROM messages
                WHERE tool_calls IS NOT NULL AND tool_calls != '[]' AND tool_calls != ''
                ORDER BY timestamp DESC
                LIMIT ?
                """,
                [.integer(Int64(toolCallLimit))]
            )
        ]
        do {
            let resultSets = try await backend.queryBatch(statements)
            let stats = resultSets.first?.first.map { statsFromRow($0) } ?? .empty
            let sessions = (resultSets.count > 1 ? resultSets[1] : []).map { sessionFromRow($0) }
            var previews: [String: String] = [:]
            for row in (resultSets.count > 2 ? resultSets[2] : []) {
                previews[row.string(at: 0)] = row.string(at: 1)
            }
            let toolCalls = (resultSets.count > 3 ? resultSets[3] : []).map { messageFromRow($0) }
            return DashboardSnapshot(
                stats: stats,
                recentSessions: sessions,
                sessionPreviews: previews,
                recentToolCalls: toolCalls
            )
        } catch {
            Self.logger.warning("dashboardSnapshot failed: \(error.localizedDescription, privacy: .public)")
            return DashboardSnapshot(
                stats: .empty,
                recentSessions: [],
                sessionPreviews: [:],
                recentToolCalls: []
            )
        }
    }

    /// Bundle for the chat sidebar / Sessions tab loaders. Folds
    /// `fetchSessions(limit:)` + `fetchSessionPreviews(limit:)` into
    /// one `queryBatch()` round-trip — same shape as
    /// `dashboardSnapshot`. Pre-fix `ChatViewModel.loadRecentSessions`
    /// + `SessionsViewModel.load` each fired the two `await
    /// dataService.fetch*` calls in serial, paying the SSH RTT
    /// twice (~840 ms minimum on a 420 ms-RTT remote, observed in
    /// ScarfMon `mac.loadRecentSessions` traces). Halves the
    /// round-trips for every sidebar load. Each tick still pays
    /// for `dashboard.loadRegistry` separately because that's a
    /// projects.json read (not SQL) and goes through a different
    /// transport call.
    public struct SessionListSnapshot: Sendable {
        public let sessions: [HermesSession]
        public let previews: [String: String]
    }

    public func sessionListSnapshot(limit: Int = QueryDefaults.sessionLimit) async -> SessionListSnapshot {
        let previewLimit = limit
        let statements: [(sql: String, params: [SQLValue])] = [
            (
                "SELECT \(sessionColumns) FROM sessions WHERE parent_session_id IS NULL ORDER BY started_at DESC LIMIT ?",
                [.integer(Int64(limit))]
            ),
            (
                """
                SELECT m.session_id, substr(m.content, 1, \(QueryDefaults.previewContentLength))
                FROM messages m
                INNER JOIN (
                    SELECT session_id, MIN(id) as min_id
                    FROM messages
                    WHERE role = 'user' AND content <> ''
                    GROUP BY session_id
                ) first ON m.id = first.min_id
                ORDER BY m.timestamp DESC
                LIMIT ?
                """,
                [.integer(Int64(previewLimit))]
            )
        ]
        do {
            let resultSets = try await backend.queryBatch(statements)
            let sessions = (resultSets.first ?? []).map { sessionFromRow($0) }
            var previews: [String: String] = [:]
            for row in (resultSets.count > 1 ? resultSets[1] : []) {
                previews[row.string(at: 0)] = row.string(at: 1)
            }
            return SessionListSnapshot(sessions: sessions, previews: previews)
        } catch {
            Self.logger.warning("sessionListSnapshot failed: \(error.localizedDescription, privacy: .public)")
            return SessionListSnapshot(sessions: [], previews: [:])
        }
    }

    /// Bundle the queries Insights fires on every load into one
    /// backend round-trip — same rationale as `dashboardSnapshot`.
    public struct InsightsSnapshot: Sendable {
        public let userMessageCount: Int
        public let toolUsage: [(name: String, count: Int)]
        public let startHours: [Int: Int]
        public let daysOfWeek: [Int: Int]
    }

    public func insightsSnapshot(since: Date) async -> InsightsSnapshot {
        let sinceTs = since.timeIntervalSince1970
        let statements: [(sql: String, params: [SQLValue])] = [
            (
                """
                SELECT COUNT(*) FROM messages m
                JOIN sessions s ON m.session_id = s.id
                WHERE m.role = 'user' AND s.parent_session_id IS NULL AND s.started_at >= ?
                """,
                [.real(sinceTs)]
            ),
            (
                """
                SELECT m.tool_name, COUNT(*) as cnt
                FROM messages m
                JOIN sessions s ON m.session_id = s.id
                WHERE m.tool_name IS NOT NULL AND m.tool_name <> '' AND s.parent_session_id IS NULL AND s.started_at >= ?
                GROUP BY m.tool_name
                ORDER BY cnt DESC
                """,
                [.real(sinceTs)]
            ),
            (
                "SELECT started_at FROM sessions WHERE parent_session_id IS NULL AND started_at >= ?",
                [.real(sinceTs)]
            )
        ]
        do {
            let resultSets = try await backend.queryBatch(statements)
            let userCount = resultSets.first?.first?.int(at: 0) ?? 0
            let toolUsage = (resultSets.count > 1 ? resultSets[1] : []).map {
                (name: $0.string(at: 0), count: $0.int(at: 1))
            }
            // The third statement returns timestamps; client-side
            // calendar bucketing into hours + days-of-week.
            let calendar = Calendar.current
            var hours: [Int: Int] = [:]
            var days: [Int: Int] = [:]
            for row in (resultSets.count > 2 ? resultSets[2] : []) {
                guard let date = row.date(at: 0) else { continue }
                let hour = calendar.component(.hour, from: date)
                hours[hour, default: 0] += 1
                let weekday = (calendar.component(.weekday, from: date) + 5) % 7
                days[weekday, default: 0] += 1
            }
            return InsightsSnapshot(
                userMessageCount: userCount,
                toolUsage: toolUsage,
                startHours: hours,
                daysOfWeek: days
            )
        } catch {
            return InsightsSnapshot(userMessageCount: 0, toolUsage: [], startHours: [:], daysOfWeek: [:])
        }
    }

    // MARK: - Modification date

    public func stateDBModificationDate() -> Date? {
        // For remote contexts we stat the remote paths. For local it's the
        // same FileManager lookup as before, just via the transport.
        let walDate = transport.stat(context.paths.stateDB + "-wal")?.mtime
        let dbDate = transport.stat(context.paths.stateDB)?.mtime
        if let w = walDate, let d = dbDate {
            return max(w, d)
        }
        return walDate ?? dbDate
    }

    // MARK: - Row Parsing

    private func sessionFromRow(_ row: Row) -> HermesSession {
        // v0.11 column lives at index 20 (after the 16 base + 4 v0.7
        // columns). Reading defensively — old DBs that lack the column
        // never reach this code path because hasV011Schema gates the
        // SELECT shape.
        let apiCallCount: Int = hasV011Schema ? row.int(at: 20) : 0
        return HermesSession(
            id: row.string(at: 0),
            source: row.string(at: 1),
            userId: row.optionalString(at: 2),
            model: row.optionalString(at: 3),
            title: row.optionalString(at: 4),
            parentSessionId: row.optionalString(at: 5),
            startedAt: row.date(at: 6),
            endedAt: row.date(at: 7),
            endReason: row.optionalString(at: 8),
            messageCount: row.int(at: 9),
            toolCallCount: row.int(at: 10),
            inputTokens: row.int(at: 11),
            outputTokens: row.int(at: 12),
            cacheReadTokens: row.int(at: 13),
            cacheWriteTokens: row.int(at: 14),
            estimatedCostUSD: row.optionalDouble(at: 15),
            reasoningTokens: hasV07Schema ? row.int(at: 16) : 0,
            actualCostUSD: hasV07Schema ? row.optionalDouble(at: 17) : nil,
            costStatus: hasV07Schema ? row.optionalString(at: 18) : nil,
            billingProvider: hasV07Schema ? row.optionalString(at: 19) : nil,
            apiCallCount: apiCallCount
        )
    }

    private func messageFromRow(_ row: Row) -> HermesMessage {
        let toolCallsJSON = row.optionalString(at: 5)
        let toolCalls = parseToolCalls(toolCallsJSON)
        // reasoning lives at index 10 (v0.7+); reasoning_content at 11
        // when v0.11 schema is present. Both columns can carry text
        // simultaneously — UI prefers `reasoningContent`.
        let reasoningContent: String? = hasV011Schema ? row.optionalString(at: 11) : nil
        return HermesMessage(
            id: row.int(at: 0),
            sessionId: row.string(at: 1),
            role: row.string(at: 2),
            content: row.string(at: 3),
            toolCallId: row.optionalString(at: 4),
            toolCalls: toolCalls,
            toolName: row.optionalString(at: 6),
            timestamp: row.date(at: 7),
            tokenCount: row.optionalInt(at: 8),
            finishReason: row.optionalString(at: 9),
            reasoning: hasV07Schema ? row.optionalString(at: 10) : nil,
            reasoningContent: reasoningContent
        )
    }

    private func parseToolCalls(_ json: String?) -> [HermesToolCall] {
        guard let json, !json.isEmpty,
              let data = json.data(using: .utf8) else { return [] }
        do {
            return try JSONDecoder().decode([HermesToolCall].self, from: data)
        } catch {
            Self.logger.error("Failed to decode tool calls: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    /// Wraps each whitespace-delimited token in double quotes to prevent FTS5 parse errors
    /// on terms containing dots, hyphens, or FTS5 operators (e.g., "v0.7.0", "config.yaml").
    private func sanitizeFTSQuery(_ raw: String) -> String {
        raw.split(separator: " ")
            .map { token in
                let t = String(token)
                let stripped = t.replacingOccurrences(of: "\"", with: "")
                return stripped.isEmpty ? nil : "\"\(stripped)\""
            }
            .compactMap { $0 }
            .joined(separator: " ")
    }
}

#endif // canImport(SQLite3)
