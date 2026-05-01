import Foundation
import Observation
#if canImport(os)
import os
#endif

/// Mac + iOS view model for the v0.12 Curator surface.
///
/// Drives `hermes curator status / run / pause / resume / pin / unpin /
/// restore` plus a parsed view of `~/.hermes/skills/.curator_state`
/// JSON. The CLI doesn't ship a `--json` flag for `status`, so we
/// text-parse stdout (HermesCuratorStatusParser) and use the state
/// file for richer last-run metadata.
///
/// Capability-gated: callers should construct this only when
/// `HermesCapabilities.hasCurator` is true. The view model does not
/// gate itself — the gate happens at sidebar/tab routing time.
@Observable
@MainActor
public final class CuratorViewModel {
    #if canImport(os)
    private let logger = Logger(subsystem: "com.scarf", category: "CuratorViewModel")
    #endif

    public let context: ServerContext

    public private(set) var status: HermesCuratorStatus = .empty
    public private(set) var isLoading = false
    public private(set) var lastReportMarkdown: String?
    public var transientMessage: String?

    public init(context: ServerContext) {
        self.context = context
    }

    public func load() async {
        isLoading = true
        defer { isLoading = false }
        let context = self.context
        let parsed = await Task.detached(priority: .userInitiated) { () -> (HermesCuratorStatus, String?) in
            let textResult = Self.runCuratorStatus(context: context)
            let stateData = context.readData(context.paths.curatorStateFile)
            let parsed = HermesCuratorStatusParser.parse(text: textResult, stateFileJSON: stateData)
            // Best-effort markdown report: the state file points at the
            // most recent <YYYYMMDD-HHMMSS>/ dir; load REPORT.md from
            // there. Missing on first run, which is fine.
            var report: String?
            if let reportDir = parsed.lastReportPath {
                let reportPath = reportDir.hasSuffix("/")
                    ? "\(reportDir)REPORT.md"
                    : "\(reportDir)/REPORT.md"
                report = context.readText(reportPath)
            }
            return (parsed, report)
        }.value
        self.status = parsed.0
        self.lastReportMarkdown = parsed.1
    }

    public func runNow() async {
        await runAndReload(args: ["curator", "run"], successMessage: "Curator run started")
    }

    public func pause() async {
        await runAndReload(args: ["curator", "pause"], successMessage: "Curator paused")
    }

    public func resume() async {
        await runAndReload(args: ["curator", "resume"], successMessage: "Curator resumed")
    }

    public func pin(_ skill: String) async {
        await runAndReload(args: ["curator", "pin", skill], successMessage: "Pinned \(skill)")
    }

    public func unpin(_ skill: String) async {
        await runAndReload(args: ["curator", "unpin", skill], successMessage: "Unpinned \(skill)")
    }

    public func restore(_ skill: String) async {
        await runAndReload(args: ["curator", "restore", skill], successMessage: "Restored \(skill)")
    }

    private func runAndReload(args: [String], successMessage: String) async {
        let context = self.context
        let exitCode = await Task.detached(priority: .userInitiated) {
            Self.runHermes(context: context, args: args).exitCode
        }.value
        transientMessage = exitCode == 0 ? successMessage : "Command failed"
        await load()
        // Auto-clear toast after 3s.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            self?.transientMessage = nil
        }
    }

    /// Wrap the transport-level `runProcess` so the call sites don't
    /// have to reach for it directly. Combined stdout+stderr.
    nonisolated private static func runHermes(
        context: ServerContext,
        args: [String]
    ) -> (exitCode: Int32, output: String) {
        let transport = context.makeTransport()
        do {
            let result = try transport.runProcess(
                executable: context.paths.hermesBinary,
                args: args,
                stdin: nil,
                timeout: 30
            )
            return (result.exitCode, result.stdoutString + result.stderrString)
        } catch let error as TransportError {
            return (-1, error.diagnosticStderr.isEmpty
                ? (error.errorDescription ?? "transport error")
                : error.diagnosticStderr)
        } catch {
            return (-1, error.localizedDescription)
        }
    }

    nonisolated private static func runCuratorStatus(context: ServerContext) -> String {
        runHermes(context: context, args: ["curator", "status"]).output
    }
}
