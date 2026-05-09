import Foundation
#if canImport(os)
import os
#endif

/// Async, transport-aware client for `hermes curator …`. Wraps the v0.12
/// verbs (`status / run / pause / resume / pin / unpin / restore`) plus
/// the v0.13 archive surface (`archive / prune / list-archived` and a
/// synchronous-blocking `run`).
///
/// **Concurrency.** Pure-I/O `actor` — no UI state. View models hold a
/// service reference and `await` methods. Each public method dispatches
/// the underlying CLI invocation through `Task.detached(priority:
/// .utility)` so two concurrent reads from the VM don't queue end-to-end
/// on a single thread. Mirrors `KanbanService` shape exactly.
///
/// **Capability gating happens at the call site, not in the service.**
/// `runNow(synchronous:timeout:)` takes a flag from the VM (the VM reads
/// `HermesCapabilities.hasCuratorArchive` to decide). The service stays
/// version-agnostic — only the timeout differs in practice.
public actor CuratorService {
    #if canImport(os)
    private static let logger = Logger(subsystem: "com.scarf", category: "CuratorService")
    #endif

    private let context: ServerContext

    public init(context: ServerContext) {
        self.context = context
    }

    // MARK: - Reads

    /// Run `hermes curator status` and parse stdout via
    /// `HermesCuratorStatusParser`. Combines the text output with the
    /// on-disk `.curator_state` JSON for richer last-run metadata.
    /// Never throws — a transport failure resolves to `.empty` so the
    /// view always has something to render.
    public func status() async -> HermesCuratorStatus {
        let context = self.context
        return await Task.detached(priority: .utility) { () -> HermesCuratorStatus in
            let textResult = Self.runHermesSync(context: context, args: ["curator", "status"], timeout: 30)
            let stateData = context.readData(context.paths.curatorStateFile)
            return HermesCuratorStatusParser.parse(text: textResult.output, stateFileJSON: stateData)
        }.value
    }

    /// `hermes curator list-archived [--json]`. Prefers JSON; falls back
    /// to a defensive text parser. Empty / "no archived skills" sentinel
    /// folds to `[]`.
    public func listArchived() async throws -> [HermesCuratorArchivedSkill] {
        // TODO(WS-4-Q2): confirm `--json` is supported on v0.13
        // `list-archived`. If not, drop the flag and rely on the text
        // parser path. Until then we pass `--json` and parse the output
        // tolerantly.
        let args = ["curator", "list-archived", "--json"]
        let (code, stdout, stderr) = await runHermes(args: args, timeout: 30)

        // If --json isn't recognized, the CLI typically emits
        // "unrecognized arguments: --json" or similar to stderr and
        // exits non-zero. Retry without the flag and parse text.
        if code != 0 {
            let lower = (stderr + stdout).lowercased()
            if lower.contains("unrecognized") || lower.contains("unknown") || lower.contains("no such option") {
                let (c2, out2, err2) = await runHermes(args: ["curator", "list-archived"], timeout: 30)
                try ensureSuccess(code: c2, stdout: out2, stderr: err2, verb: "list-archived")
                return Self.parseListArchivedText(out2)
            }
            try ensureSuccess(code: code, stdout: stdout, stderr: stderr, verb: "list-archived")
        }

        let trimmed = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.lowercased().contains("no archived skills") {
            return []
        }
        // Try JSON first — may also be a text dump if Hermes ignored `--json`.
        if let data = trimmed.data(using: .utf8),
           let arr = try? JSONDecoder().decode([HermesCuratorArchivedSkill].self, from: data) {
            return arr
        }
        // Some builds wrap in `{"archived": [...]}` envelope.
        struct Wrapper: Decodable { let archived: [HermesCuratorArchivedSkill] }
        if let data = trimmed.data(using: .utf8),
           let wrapped = try? JSONDecoder().decode(Wrapper.self, from: data) {
            return wrapped.archived
        }
        // Text fallback — defensive parse.
        return Self.parseListArchivedText(stdout)
    }

    // MARK: - Writes (legacy v0.12 verbs; service form)

    public func runNow(synchronous: Bool, timeout: TimeInterval) async throws {
        // TODO(WS-4-Q4): default 600s for v0.13 sync runs. No Cancel
        // button in v2.8 (transport.cancel parity not guaranteed across
        // LocalTransport / SSHTransport).
        let resolvedTimeout = synchronous ? timeout : 30
        let (code, stdout, stderr) = await runHermes(args: ["curator", "run"], timeout: resolvedTimeout)
        try ensureSuccess(code: code, stdout: stdout, stderr: stderr, verb: "run")
    }

    public func pause() async throws {
        let (code, stdout, stderr) = await runHermes(args: ["curator", "pause"], timeout: 15)
        try ensureSuccess(code: code, stdout: stdout, stderr: stderr, verb: "pause")
    }

    public func resume() async throws {
        let (code, stdout, stderr) = await runHermes(args: ["curator", "resume"], timeout: 15)
        try ensureSuccess(code: code, stdout: stdout, stderr: stderr, verb: "resume")
    }

    public func pin(_ name: String) async throws {
        let (code, stdout, stderr) = await runHermes(args: ["curator", "pin", name], timeout: 15)
        try ensureSuccess(code: code, stdout: stdout, stderr: stderr, verb: "pin")
    }

    public func unpin(_ name: String) async throws {
        let (code, stdout, stderr) = await runHermes(args: ["curator", "unpin", name], timeout: 15)
        try ensureSuccess(code: code, stdout: stdout, stderr: stderr, verb: "unpin")
    }

    public func restore(_ name: String) async throws {
        let (code, stdout, stderr) = await runHermes(args: ["curator", "restore", name], timeout: 30)
        try ensureSuccess(code: code, stdout: stdout, stderr: stderr, verb: "restore")
    }

    // MARK: - Writes (new in v0.13)

    /// `hermes curator archive <name>` — non-destructive; moves the
    /// skill from the active set to the archived set. No `--json` is
    /// expected; the verb's success channel is the exit code.
    public func archive(_ name: String) async throws {
        let (code, stdout, stderr) = await runHermes(args: ["curator", "archive", name], timeout: 30)
        try ensureSuccess(code: code, stdout: stdout, stderr: stderr, verb: "archive")
    }

    /// `hermes curator prune [--dry-run]`. Destructive when `dryRun`
    /// is `false` — removes everything currently archived from disk.
    /// Returns a `CuratorPruneSummary` describing what was (or would be)
    /// removed. On `dryRun=false`, the wire shape may not include the
    /// `would_remove` list — the caller should not depend on it; the
    /// archived list is empty after a successful destructive prune.
    @discardableResult
    public func prune(dryRun: Bool) async throws -> CuratorPruneSummary {
        // TODO(WS-4-Q1): confirm v0.13 ships `--dry-run`. If not, fall
        // back to enumerating via `list-archived` and treat any prune
        // call as destructive. The retry-without-flag path below covers
        // the "unrecognized argument" case automatically.
        var args = ["curator", "prune"]
        if dryRun { args.append("--dry-run") }
        // `--json` requested for the dry-run path so we can parse the
        // would-remove list. Destructive mode runs without --json since
        // we only need the exit code.
        if dryRun { args.append("--json") }

        let (code, stdout, stderr) = await runHermes(args: args, timeout: 60)

        // Detect "unrecognized --dry-run" / "unknown --json" gracefully.
        if code != 0 {
            let lower = (stderr + stdout).lowercased()
            let unrecognized = lower.contains("unrecognized") || lower.contains("unknown") || lower.contains("no such option")
            if dryRun && unrecognized {
                // Q1 fallback: enumerate via list-archived. Caller still
                // uses this summary for confirm-sheet display.
                let archived = try await listArchived()
                let total = archived.compactMap { $0.sizeBytes }.reduce(0, +)
                return CuratorPruneSummary(wouldRemove: archived, totalBytes: total)
            }
            try ensureSuccess(code: code, stdout: stdout, stderr: stderr, verb: "prune")
        }

        if dryRun {
            return Self.parsePruneDryRun(stdout)
        }
        return CuratorPruneSummary(wouldRemove: [], totalBytes: 0)
    }

    // MARK: - Pure parsers (nonisolated; safe to call from VMs without awaits)

    /// Parse a `list-archived --json` payload. Tolerates the bare-array
    /// shape, the `{"archived": [...]}` envelope, and "no archived
    /// skills" / empty-string sentinels. Returns `[]` for any of the
    /// empty cases. Throws `CuratorError.decoding` only when the input
    /// is non-empty and clearly not JSON.
    public nonisolated static func parseListArchived(stdout: String) throws -> [HermesCuratorArchivedSkill] {
        let trimmed = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.lowercased().contains("no archived skills") {
            return []
        }
        guard let data = trimmed.data(using: .utf8) else {
            throw CuratorError.decoding(verb: "list-archived", message: "non-UTF8 stdout")
        }
        if let arr = try? JSONDecoder().decode([HermesCuratorArchivedSkill].self, from: data) {
            return arr
        }
        struct Wrapper: Decodable { let archived: [HermesCuratorArchivedSkill] }
        if let wrapped = try? JSONDecoder().decode(Wrapper.self, from: data) {
            return wrapped.archived
        }
        // Last resort: text fallback.
        let parsed = parseListArchivedText(stdout)
        if !parsed.isEmpty {
            return parsed
        }
        throw CuratorError.decoding(verb: "list-archived", message: "stdout was neither JSON nor a recognised text list")
    }

    /// Defensive text parser for `list-archived` output when `--json`
    /// isn't supported. Format inferred from `curator status`: one row
    /// per non-blank line, leading whitespace, name in column 1, then
    /// optional `archived=YYYY-MM-DD`, `size=NNNN`, `reason=...` k/v
    /// pairs. Blank lines, header lines, and the empty-state sentinel
    /// are skipped.
    public nonisolated static func parseListArchivedText(_ text: String) -> [HermesCuratorArchivedSkill] {
        var rows: [HermesCuratorArchivedSkill] = []
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            let lower = line.lowercased()
            // Skip header / sentinel lines.
            if lower.hasPrefix("name") && lower.contains("archived") { continue }
            if lower.contains("no archived skills") { continue }
            if line.unicodeScalars.allSatisfy({ $0.value == 0x2500 || $0.properties.isWhitespace }) {
                continue
            }
            // Skip lines that look like JSON / non-row chrome — `{`,
            // `}`, `[`, `]` at the start or quotes / colons mean we're
            // parsing a malformed JSON dump, not a row table.
            if let first = line.first, "{[}]\":,".contains(first) {
                continue
            }
            // Find the first whitespace-separated token as the name; if
            // the name carries an `=` it's a header chip we should skip.
            let parts = line.split(whereSeparator: { $0 == "\t" || $0 == " " }).map(String.init)
            guard let name = parts.first, !name.contains("=") else { continue }
            // Reject names that look like punctuation / JSON fragments.
            if name.contains("\"") || name.contains(":") || name.contains("{") || name.contains("}") || name.contains("[") || name.contains("]") {
                continue
            }
            // Pull k=v pairs from the remainder.
            var archivedAt: String?
            var sizeBytes: Int?
            var reason: String?
            var category: String?
            var path: String?
            for token in parts.dropFirst() {
                guard let eq = token.firstIndex(of: "=") else { continue }
                let key = String(token[..<eq])
                let value = String(token[token.index(after: eq)...])
                switch key {
                case "archived", "archived_at":
                    archivedAt = value
                case "size", "size_bytes":
                    sizeBytes = Int(value)
                case "reason":
                    reason = value
                case "category":
                    category = value
                case "path":
                    path = value
                default:
                    continue
                }
            }
            rows.append(
                HermesCuratorArchivedSkill(
                    name: name,
                    category: category,
                    archivedAt: archivedAt,
                    reason: reason,
                    sizeBytes: sizeBytes,
                    path: path
                )
            )
        }
        return rows
    }

    /// Parse a `prune --dry-run --json` payload. Tolerates an empty
    /// payload (returns a zero summary) and the `{would_remove: [],
    /// total_bytes: N}` shape.
    public nonisolated static func parsePruneDryRun(_ stdout: String) -> CuratorPruneSummary {
        let trimmed = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return CuratorPruneSummary(wouldRemove: [], totalBytes: 0)
        }
        if let data = trimmed.data(using: .utf8),
           let summary = try? JSONDecoder().decode(CuratorPruneSummary.self, from: data) {
            return summary
        }
        // Tolerate a bare-array fallback (some Hermes builds may print
        // just the would-remove list when --json is missing the wrapper).
        if let data = trimmed.data(using: .utf8),
           let arr = try? JSONDecoder().decode([HermesCuratorArchivedSkill].self, from: data) {
            let total = arr.compactMap { $0.sizeBytes }.reduce(0, +)
            return CuratorPruneSummary(wouldRemove: arr, totalBytes: total)
        }
        // Last-resort text parse for "would remove N skills (X bytes)".
        return CuratorPruneSummary(wouldRemove: [], totalBytes: 0)
    }

    // MARK: - CLI invocation

    private nonisolated func runHermes(
        args: [String],
        timeout: TimeInterval
    ) async -> (exitCode: Int32, stdout: String, stderr: String) {
        let context = self.context
        return await Task.detached(priority: .utility) { () -> (Int32, String, String) in
            let result = Self.runHermesSync(context: context, args: args, timeout: timeout)
            return (result.exitCode, result.output, result.stderr)
        }.value
    }

    /// Synchronous, transport-level invocation. `output` is stdout; the
    /// caller usually only reads `output` for parser input but sometimes
    /// needs `stderr` (e.g. to detect "unrecognized argument" patterns).
    private nonisolated static func runHermesSync(
        context: ServerContext,
        args: [String],
        timeout: TimeInterval
    ) -> (exitCode: Int32, output: String, stderr: String) {
        let transport = context.makeTransport()
        do {
            let result = try transport.runProcess(
                executable: context.paths.hermesBinary,
                args: args,
                stdin: nil,
                timeout: timeout
            )
            return (result.exitCode, result.stdoutString, result.stderrString)
        } catch let error as TransportError {
            let message = error.diagnosticStderr.isEmpty
                ? (error.errorDescription ?? "transport error")
                : error.diagnosticStderr
            return (-1, "", message)
        } catch {
            return (-1, "", error.localizedDescription)
        }
    }

    private nonisolated func ensureSuccess(
        code: Int32,
        stdout: String,
        stderr: String,
        verb: String
    ) throws {
        guard code != 0 else { return }
        if code == -1 && stderr.lowercased().contains("hermes binary not found") {
            throw CuratorError.cliMissing
        }
        let combined = stderr.isEmpty ? stdout : stderr
        #if canImport(os)
        Self.logger.warning("curator \(verb) exit=\(code, privacy: .public) stderr=\(combined, privacy: .public)")
        #endif
        throw CuratorError.nonZeroExit(verb: verb, code: code, stderr: combined)
    }
}
