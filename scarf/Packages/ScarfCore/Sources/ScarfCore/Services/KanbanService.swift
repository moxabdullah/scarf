import Foundation
#if canImport(os)
import os
#endif

/// Async, transport-aware client for `hermes kanban …`. Wraps every CLI
/// verb the v0.12 board exposes in a typed Swift surface.
///
/// **Concurrency.** This is a pure-I/O `actor` — no UI state. View models
/// (`@MainActor` `@Observable`) hold a service reference and `await`
/// methods. Each public method serializes through the actor, but the
/// underlying CLI invocation runs on a `Task.detached(priority: .utility)`
/// so two concurrent reads from different VMs don't queue end-to-end on
/// a single thread.
///
/// **Hermes constraints surfaced as Swift constraints:**
/// - There is no `update` verb, so there's no `update(taskId:title:body:)`.
///   Mutations after create are state transitions (assign / claim /
///   complete / block / unblock / archive / comment) or new comments.
/// - The board is global with optional `tenant` namespacing — pass a
///   tenant via `KanbanListFilter.tenant` for project-scoped views.
/// - The CLI prints `"no matching tasks"` instead of `[]` when nothing
///   matches a filter. We fold that into `[]` rather than throwing.
public actor KanbanService {
    #if canImport(os)
    private static let logger = Logger(subsystem: "com.scarf", category: "KanbanService")
    #endif

    private let context: ServerContext

    public init(context: ServerContext) {
        self.context = context
    }

    // MARK: - Reads

    public func list(_ filter: KanbanListFilter = .all) async throws -> [HermesKanbanTask] {
        var args = ["kanban", "list"]
        args.append(contentsOf: filter.argv())
        let (code, stdout, stderr) = await runHermes(args: args, timeout: 20)
        try ensureSuccess(code: code, stdout: stdout, stderr: stderr, verb: "list")

        // Empty filter on an empty board prints "no matching tasks" instead
        // of `[]`. Treat as empty rather than letting the JSON decode fail.
        if stdout.contains("no matching tasks") {
            return []
        }
        guard let data = stdout.data(using: .utf8) else {
            throw KanbanError.decoding(message: "non-UTF8 stdout")
        }
        do {
            return try JSONDecoder().decode([HermesKanbanTask].self, from: data)
        } catch {
            throw KanbanError.decoding(message: error.localizedDescription)
        }
    }

    public func show(taskId: String) async throws -> HermesKanbanTaskDetail {
        let args = ["kanban", "show", taskId, "--json"]
        let (code, stdout, stderr) = await runHermes(args: args, timeout: 15)
        try ensureSuccess(code: code, stdout: stdout, stderr: stderr, verb: "show")
        guard let data = stdout.data(using: .utf8) else {
            throw KanbanError.decoding(message: "non-UTF8 stdout")
        }
        do {
            return try JSONDecoder().decode(HermesKanbanTaskDetail.self, from: data)
        } catch {
            throw KanbanError.decoding(message: error.localizedDescription)
        }
    }

    public func runs(taskId: String) async throws -> [HermesKanbanRun] {
        let args = ["kanban", "runs", taskId, "--json"]
        let (code, stdout, stderr) = await runHermes(args: args, timeout: 15)
        try ensureSuccess(code: code, stdout: stdout, stderr: stderr, verb: "runs")
        guard let data = stdout.data(using: .utf8) else {
            throw KanbanError.decoding(message: "non-UTF8 stdout")
        }
        do {
            return try JSONDecoder().decode([HermesKanbanRun].self, from: data)
        } catch {
            // Some Hermes builds emit a `{"runs": [...]}` envelope.
            struct Wrapper: Decodable { let runs: [HermesKanbanRun] }
            if let wrapped = try? JSONDecoder().decode(Wrapper.self, from: data) {
                return wrapped.runs
            }
            throw KanbanError.decoding(message: error.localizedDescription)
        }
    }

    public func stats() async throws -> HermesKanbanStats {
        let args = ["kanban", "stats", "--json"]
        let (code, stdout, stderr) = await runHermes(args: args, timeout: 15)
        try ensureSuccess(code: code, stdout: stdout, stderr: stderr, verb: "stats")
        guard let data = stdout.data(using: .utf8) else {
            throw KanbanError.decoding(message: "non-UTF8 stdout")
        }
        do {
            return try JSONDecoder().decode(HermesKanbanStats.self, from: data)
        } catch {
            throw KanbanError.decoding(message: error.localizedDescription)
        }
    }

    /// Print the captured worker log for a task — `hermes kanban log
    /// <id>`. Returns whatever `$HERMES_HOME/kanban/logs/<id>` contains.
    /// Empty string when the worker hasn't written anything yet (or
    /// the task has never been claimed). Pass `tailBytes` to cap the
    /// returned size (useful when polling at high cadence).
    public func log(taskId: String, tailBytes: Int? = nil) async throws -> String {
        var args = ["kanban", "log"]
        if let tailBytes {
            args.append(contentsOf: ["--tail", String(tailBytes)])
        }
        args.append(taskId)
        let (code, stdout, stderr) = await runHermes(args: args, timeout: 15)
        // `kanban log` exits with code 0 even when no log file exists —
        // it just prints "No log file." or similar to stdout. Tolerate
        // non-zero codes too: some Hermes versions emit a warning to
        // stderr and exit 1 when the log dir is missing.
        if code != 0 {
            let combined = stderr.isEmpty ? stdout : stderr
            // Treat "no log" sentinels as empty rather than as errors.
            let lower = combined.lowercased()
            if lower.contains("no log") || lower.contains("not found") {
                return ""
            }
            throw KanbanError.nonZeroExit(code: code, stderr: combined)
        }
        return stdout
    }

    public func assignees() async throws -> [HermesKanbanAssignee] {
        // The `assignees` verb doesn't take `--json` consistently across
        // 0.12.x — pass it anyway and fall back to a tab-delimited parse
        // if Hermes printed a human table.
        let args = ["kanban", "assignees"]
        let (code, stdout, stderr) = await runHermes(args: args, timeout: 15)
        try ensureSuccess(code: code, stdout: stdout, stderr: stderr, verb: "assignees")

        if let data = stdout.data(using: .utf8),
           let arr = try? JSONDecoder().decode([HermesKanbanAssignee].self, from: data) {
            return arr
        }

        // Fallback: each non-blank line of the form
        //   "<profile>\t<active>\t<total>"
        // OR "<profile>     <active>     <total>" (whitespace separated).
        return parseAssigneeTable(stdout)
    }

    private nonisolated func parseAssigneeTable(_ text: String) -> [HermesKanbanAssignee] {
        var result: [HermesKanbanAssignee] = []
        // Profile names follow the same convention as `hermes -p <name>`
        // — letters, digits, hyphen, underscore. Anything else is
        // chrome (header rows, Rich box-drawing, fallback messages
        // like "(no assignees — create a profile with `hermes -p
        // <name> setup`)") and gets skipped.
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            // Skip the column header row.
            if line.lowercased().hasPrefix("profile") { continue }
            // Skip the empty-state sentinel without trying to tokenize
            // it (used to leak "(no" into the picker).
            if line.lowercased().contains("no assignees") { continue }
            // Skip Rich box-drawing separators (only ─ + whitespace).
            if line.unicodeScalars.allSatisfy({ $0.value == 0x2500 || $0.properties.isWhitespace }) {
                continue
            }
            // Strip the active marker `◆` (U+25C6) some `hermes`
            // commands prefix to the active profile.
            var working = line
            if working.hasPrefix("◆") {
                working = String(working.dropFirst()).trimmingCharacters(in: .whitespaces)
            }
            let parts = working
                .split(whereSeparator: { $0 == "\t" || $0 == " " })
                .map { String($0) }
                .filter { !$0.isEmpty }
            guard let profile = parts.first else { continue }
            // Validate: must look like a real profile slug, not a word
            // out of an English sentence.
            guard profile.range(of: "^[a-zA-Z0-9_-]+$", options: .regularExpression) != nil else {
                continue
            }
            let active = (parts.count > 1) ? Int(parts[1]) ?? 0 : 0
            let total = (parts.count > 2) ? Int(parts[2]) ?? 0 : active
            result.append(HermesKanbanAssignee(profile: profile, activeCount: active, totalCount: total))
        }
        return result
    }

    // MARK: - Writes

    public func create(_ request: KanbanCreateRequest) async throws -> HermesKanbanTask {
        var args = ["kanban", "create"]
        args.append(contentsOf: request.argv())
        let (code, stdout, stderr) = await runHermes(args: args, timeout: 30)
        try ensureSuccess(code: code, stdout: stdout, stderr: stderr, verb: "create")
        guard let data = stdout.data(using: .utf8) else {
            throw KanbanError.decoding(message: "non-UTF8 stdout")
        }
        // Hermes returns the full task object when --json is set.
        do {
            return try JSONDecoder().decode(HermesKanbanTask.self, from: data)
        } catch {
            // Some builds emit just the new id on stdout. Fall back to a
            // follow-up `show` so the caller always gets a typed task.
            let trimmed = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, !trimmed.contains("\n"), !trimmed.contains("{") {
                let detail = try await show(taskId: trimmed)
                return detail.task
            }
            throw KanbanError.decoding(message: error.localizedDescription)
        }
    }

    public func assign(taskId: String, profile: String?) async throws {
        let target = (profile?.isEmpty ?? true) ? "none" : profile!
        let args = ["kanban", "assign", taskId, target]
        let (code, _, stderr) = await runHermes(args: args, timeout: 15)
        try ensureSuccess(code: code, stdout: "", stderr: stderr, verb: "assign")
    }

    @discardableResult
    public func claim(taskId: String, ttlSeconds: Int = 900) async throws -> String {
        let args = ["kanban", "claim", taskId, "--ttl", String(ttlSeconds)]
        let (code, stdout, stderr) = await runHermes(args: args, timeout: 20)
        try ensureSuccess(code: code, stdout: stdout, stderr: stderr, verb: "claim")
        // claim prints the resolved workspace path on stdout.
        return stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func comment(taskId: String, text: String, author: String? = nil) async throws {
        var args = ["kanban", "comment"]
        if let author, !author.isEmpty {
            args.append(contentsOf: ["--author", author])
        }
        args.append(taskId)
        args.append(text)
        let (code, _, stderr) = await runHermes(args: args, timeout: 15)
        try ensureSuccess(code: code, stdout: "", stderr: stderr, verb: "comment")
    }

    public func complete(
        taskIds: [String],
        result: String? = nil,
        summary: String? = nil,
        metadataJSON: String? = nil
    ) async throws {
        guard !taskIds.isEmpty else { return }
        var args = ["kanban", "complete"]
        if let result, !result.isEmpty {
            args.append(contentsOf: ["--result", result])
        }
        if let summary, !summary.isEmpty {
            args.append(contentsOf: ["--summary", summary])
        }
        if let metadataJSON, !metadataJSON.isEmpty {
            args.append(contentsOf: ["--metadata", metadataJSON])
        }
        args.append(contentsOf: taskIds)
        let (code, _, stderr) = await runHermes(args: args, timeout: 30)
        try ensureSuccess(code: code, stdout: "", stderr: stderr, verb: "complete")
    }

    public func block(taskId: String, reason: String? = nil) async throws {
        var args = ["kanban", "block", taskId]
        if let reason, !reason.trimmingCharacters(in: .whitespaces).isEmpty {
            // Hermes accepts free-form trailing words as the reason.
            args.append(contentsOf: reason.split(separator: " ").map(String.init))
        }
        let (code, _, stderr) = await runHermes(args: args, timeout: 15)
        try ensureSuccess(code: code, stdout: "", stderr: stderr, verb: "block")
    }

    public func unblock(taskIds: [String]) async throws {
        guard !taskIds.isEmpty else { return }
        var args = ["kanban", "unblock"]
        args.append(contentsOf: taskIds)
        let (code, _, stderr) = await runHermes(args: args, timeout: 15)
        try ensureSuccess(code: code, stdout: "", stderr: stderr, verb: "unblock")
    }

    public func archive(taskIds: [String]) async throws {
        guard !taskIds.isEmpty else { return }
        var args = ["kanban", "archive"]
        args.append(contentsOf: taskIds)
        let (code, _, stderr) = await runHermes(args: args, timeout: 15)
        try ensureSuccess(code: code, stdout: "", stderr: stderr, verb: "archive")
    }

    @discardableResult
    public func dispatch(maxTasks: Int? = nil, dryRun: Bool = false) async throws -> KanbanDispatchSummary {
        var args = ["kanban", "dispatch", "--json"]
        if dryRun { args.append("--dry-run") }
        if let maxTasks { args.append(contentsOf: ["--max", String(maxTasks)]) }
        let (code, stdout, stderr) = await runHermes(args: args, timeout: 60)
        try ensureSuccess(code: code, stdout: stdout, stderr: stderr, verb: "dispatch")
        guard let data = stdout.data(using: .utf8) else {
            throw KanbanError.decoding(message: "non-UTF8 stdout")
        }
        do {
            return try JSONDecoder().decode(KanbanDispatchSummary.self, from: data)
        } catch {
            // Older builds may print human output. Return a stub summary.
            return KanbanDispatchSummary(promoted: 0, failed: 0, dryRun: dryRun, perTask: [])
        }
    }

    public func link(parent: String, child: String) async throws {
        let args = ["kanban", "link", parent, child]
        let (code, _, stderr) = await runHermes(args: args, timeout: 15)
        try ensureSuccess(code: code, stdout: "", stderr: stderr, verb: "link")
    }

    public func unlink(parent: String, child: String) async throws {
        let args = ["kanban", "unlink", parent, child]
        let (code, _, stderr) = await runHermes(args: args, timeout: 15)
        try ensureSuccess(code: code, stdout: "", stderr: stderr, verb: "unlink")
    }

    // MARK: - Hallucination gate (v0.13)

    /// Mark a worker-created card as user-verified — flips
    /// `hallucination_gate_status` from `pending` to `verified` so the
    /// dispatcher can pick it up. The polling loop picks up the new
    /// state on the next tick (and the VM optimistically clears the
    /// pending banner immediately on the click).
    ///
    /// **Pre-v0.13 hosts:** the verb doesn't exist; callers MUST gate
    /// on `HermesCapabilities.hasKanbanDiagnostics` before invoking this.
    /// A pre-v0.13 binary will surface the failure as
    /// `KanbanError.nonZeroExit` with stderr containing "unknown command".
    // TODO(WS-3-Q1): Confirm the exact CLI verb name for the
    // hallucination-gate verify path against a v0.13 binary (`hermes
    // kanban --help`). The v0.13 release notes describe "hallucination
    // gate + recovery UX" but don't enumerate the verb name. This
    // implementation assumes `hermes kanban verify <id>`. If Hermes ships
    // it as `hermes kanban gate verify <id>`, `hermes kanban hallucination
    // verify <id>`, or another name, update the args here. The Reject
    // path does NOT depend on this verb (it routes through
    // `archive` + a comment), so the recovery UX stays functional even
    // if Verify is a stub for an early v0.13.x.
    public func verify(taskId: String) async throws {
        let args = ["kanban", "verify", taskId]
        let (code, _, stderr) = await runHermes(args: args, timeout: 15)
        try ensureSuccess(code: code, stdout: "", stderr: stderr, verb: "verify")
    }

    /// Reject a worker-created card as a hallucinated reference. There
    /// is no dedicated `kanban reject` verb in v0.13; the right action
    /// per the v0.13 release notes is to archive the card (the work
    /// doesn't exist) with a comment recording the rejection reason for
    /// the audit trail. Routing this through the existing `comment` +
    /// `archive` verbs keeps the wire shape stable across versions.
    ///
    /// If a future Hermes adds a dedicated `kanban reject` verb, swap
    /// the body here — the public surface stays "reject" returning Void.
    public func rejectHallucinated(taskId: String) async throws {
        // Best-effort comment first so the audit trail records the
        // rejection. A failure here shouldn't block the archive — log
        // and continue.
        do {
            try await comment(
                taskId: taskId,
                text: "Rejected as hallucinated (no underlying work).",
                author: nil
            )
        } catch {
            #if canImport(os)
            Self.logger.warning("kanban reject: comment failed, proceeding to archive (\(error.localizedDescription, privacy: .public))")
            #endif
        }
        try await archive(taskIds: [taskId])
    }

    // MARK: - Drag-drop transition mapper

    /// Map a board-level column transition to the right Hermes verb call.
    /// Returns the list of CLI invocations the caller should run in order.
    /// Pure — no I/O. Called from VMs to build an action plan; the VM
    /// then either prompts the user (e.g. for a block reason) or calls
    /// the matching `KanbanService` methods.
    ///
    /// Forbidden transitions throw `KanbanError.forbiddenTransition`
    /// rather than returning an empty plan, so callers can surface the
    /// reason to the user.
    public nonisolated static func plan(
        for transition: KanbanTransition
    ) throws -> KanbanTransitionPlan {
        let from = transition.from
        let to = transition.to
        if from == to {
            return KanbanTransitionPlan(steps: [])
        }

        // "Done" is terminal — Hermes has no `reopen` verb.
        if from == .done {
            throw KanbanError.forbiddenTransition(
                from: from.displayName,
                to: to.displayName,
                reason: "Done is terminal — create a follow-up task to continue work."
            )
        }

        // Triage promotion isn't a CLI verb in v0.12 — it happens via
        // a specifier worker. UI should disallow drag from triage.
        if from == .triage {
            throw KanbanError.forbiddenTransition(
                from: from.displayName,
                to: to.displayName,
                reason: "Triage tasks are promoted by a specifier agent. Use the specifier worker pipeline."
            )
        }

        // Archive lives outside the board — only via context menu.
        if to == .archived {
            return KanbanTransitionPlan(steps: [.archive])
        }

        switch (from, to) {
        case (.upNext, .running):
            return KanbanTransitionPlan(steps: [.dispatch])
        case (.upNext, .blocked):
            return KanbanTransitionPlan(steps: [.block(reasonRequired: true)])
        case (.upNext, .done):
            // Direct todo→done is unusual but allowed (manual checkoff).
            return KanbanTransitionPlan(steps: [.complete(resultRequired: false)])
        case (.running, .blocked):
            return KanbanTransitionPlan(steps: [.block(reasonRequired: true)])
        case (.running, .done):
            return KanbanTransitionPlan(steps: [.complete(resultRequired: false)])
        case (.running, .upNext):
            // Release back to ready — no direct verb. Closest is unblock,
            // which only works for blocked tasks. Forbid for now.
            throw KanbanError.forbiddenTransition(
                from: from.displayName,
                to: to.displayName,
                reason: "Use the inspector's Comment + Unassign actions to hand a running task back."
            )
        case (.blocked, .upNext):
            return KanbanTransitionPlan(steps: [.unblock])
        case (.blocked, .running):
            return KanbanTransitionPlan(steps: [.unblock, .dispatch])
        case (.blocked, .done):
            return KanbanTransitionPlan(steps: [.unblock, .complete(resultRequired: false)])
        default:
            throw KanbanError.forbiddenTransition(
                from: from.displayName,
                to: to.displayName,
                reason: "No CLI path exists for this transition."
            )
        }
    }

    // MARK: - CLI invocation

    private nonisolated func runHermes(
        args: [String],
        timeout: TimeInterval
    ) async -> (exitCode: Int32, stdout: String, stderr: String) {
        let context = self.context
        return await Task.detached(priority: .utility) { () -> (Int32, String, String) in
            let transport = context.makeTransport()
            let executable = context.paths.hermesBinary
            do {
                let result = try transport.runProcess(
                    executable: executable,
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
        }.value
    }

    private nonisolated func ensureSuccess(
        code: Int32,
        stdout: String,
        stderr: String,
        verb: String
    ) throws {
        guard code != 0 else { return }
        if code == -1 && stderr.lowercased().contains("hermes binary not found") {
            throw KanbanError.cliMissing
        }
        let combined = stderr.isEmpty ? stdout : stderr
        #if canImport(os)
        Self.logger.warning("kanban \(verb) exit=\(code, privacy: .public) stderr=\(combined, privacy: .public)")
        #endif
        throw KanbanError.nonZeroExit(code: code, stderr: combined)
    }
}

// MARK: - Transition planning

/// Source/destination columns for a single drag-drop. Comparable to
/// SwiftUI's `.dropDestination` payload but kept Sendable + Hashable
/// so it can also drive iOS context-menu "Move to…" actions.
public struct KanbanTransition: Sendable, Hashable {
    public let from: KanbanBoardColumn
    public let to: KanbanBoardColumn

    public init(from: KanbanBoardColumn, to: KanbanBoardColumn) {
        self.from = from
        self.to = to
    }
}

/// One Hermes verb call produced by `KanbanService.plan(for:)`. The VM
/// resolves any user-input requirements (block reason, completion
/// result) before invoking the corresponding actor method.
///
/// **Why `.dispatch` and not `.claim`.** `hermes kanban claim` reserves
/// a task atomically and prints the workspace path — but it's a
/// "manual alternative to the dispatcher" that assumes the caller will
/// spawn the worker themselves. Scarf is not a worker host; the
/// gateway-running dispatcher is. Calling `claim` from drag-drop
/// flipped status to `running` without spawning any work, and the
/// task got reclaimed (stale_lock) ~15 minutes later. The right
/// verb is `dispatch`, which causes the dispatcher to spawn workers
/// for every assigned `ready` task in one pass.
public enum KanbanTransitionStep: Sendable, Equatable {
    /// Force a dispatcher pass so the gateway spawns workers for
    /// assigned `ready` tasks. Requires the task have an assignee
    /// — the dispatcher silently skips unassigned tasks.
    case dispatch
    case unblock
    case block(reasonRequired: Bool)
    case complete(resultRequired: Bool)
    case archive
}

public struct KanbanTransitionPlan: Sendable, Equatable {
    public let steps: [KanbanTransitionStep]

    public init(steps: [KanbanTransitionStep]) {
        self.steps = steps
    }

    public var requiresBlockReason: Bool {
        steps.contains { if case .block(true) = $0 { return true } else { return false } }
    }

    public var requiresCompleteResult: Bool {
        steps.contains { if case .complete(true) = $0 { return true } else { return false } }
    }
}
