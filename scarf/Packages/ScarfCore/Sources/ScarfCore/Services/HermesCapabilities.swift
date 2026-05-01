import Foundation
import Observation
#if canImport(os)
import os
#endif

/// What this Hermes installation can do, derived from `hermes --version`.
///
/// Scarf tracks Hermes feature releases by date-version + semver. v0.12 added
/// a dozen surfaces (Curator, Kanban, multimodal ACP, ...) and removed a few
/// (`flush_memories` aux task). UI that branches on these surfaces calls
/// the boolean accessors here so older Hermes installs degrade silently
/// instead of throwing on an unknown CLI subcommand.
///
/// Pure value type — no side effects. The async detection lives in
/// `HermesCapabilitiesStore`.
public struct HermesCapabilities: Sendable, Equatable {
    /// Raw version line as printed by `hermes --version`. Preserved verbatim
    /// so diagnostics views can show the exact string Scarf saw.
    public let versionLine: String
    /// Parsed `0.X.Y`. `nil` when the output didn't match the expected format
    /// (e.g. Hermes returned an error, or a future format change).
    public let semver: SemVer?
    /// Parsed `YYYY.M.D` from the parenthesized date suffix. `nil` when
    /// absent — older Hermes builds didn't always emit it.
    public let dateVersion: DateVersion?

    public init(versionLine: String, semver: SemVer?, dateVersion: DateVersion?) {
        self.versionLine = versionLine
        self.semver = semver
        self.dateVersion = dateVersion
    }

    /// Sentinel for "not yet detected" / "detection failed". All capability
    /// flags resolve to `false` so unguarded UI stays hidden until the real
    /// version lands.
    public static let empty = HermesCapabilities(
        versionLine: "",
        semver: nil,
        dateVersion: nil
    )

    public var detected: Bool { semver != nil }

    // MARK: - Capability flags
    //
    // Add a new flag here when Scarf gains UI that conditionally branches on
    // a Hermes capability. Keep the comparison conservative: `>= 0.12.0`
    // covers users still on the 0.12 line who haven't upgraded to 0.13 yet.

    /// `hermes curator` autonomous skill maintenance (v0.12+).
    public var hasCurator: Bool { atLeastSemver(0, 12, 0) }

    /// `hermes fallback` provider management (v0.12+).
    public var hasFallbackCommand: Bool { atLeastSemver(0, 12, 0) }

    /// `hermes kanban` task board CLI (v0.12+).
    public var hasKanban: Bool { atLeastSemver(0, 12, 0) }

    /// `hermes -z <prompt>` non-interactive one-shot mode (v0.12+).
    public var hasOneShot: Bool { atLeastSemver(0, 12, 0) }

    /// `hermes skills install <https-url>` direct-URL install (v0.12+).
    public var hasSkillURLInstall: Bool { atLeastSemver(0, 12, 0) }

    /// ACP `session/prompt` accepts image content blocks (v0.12+).
    public var hasACPImagePrompts: Bool { atLeastSemver(0, 12, 0) }

    /// `hermes update --check` preflight (v0.12+).
    public var hasUpdateCheck: Bool { atLeastSemver(0, 12, 0) }

    /// Pluggable TTS providers including native Piper (v0.12+).
    public var hasPiperTTS: Bool { atLeastSemver(0, 12, 0) }

    /// `terminal.backend = vercel` Vercel Sandbox option (v0.12+).
    public var hasVercelTerminal: Bool { atLeastSemver(0, 12, 0) }

    /// `auxiliary.flush_memories` config row was removed in v0.12.
    /// Inverse semantics — `true` means the row should still be shown.
    public var hasFlushMemoriesAux: Bool {
        guard let s = semver else { return false }       // unknown → hide
        return s < SemVer(major: 0, minor: 12, patch: 0) // pre-v0.12 only
    }

    /// `auxiliary.curator` aux task is configurable (v0.12+).
    public var hasCuratorAux: Bool { atLeastSemver(0, 12, 0) }

    /// Microsoft Teams (19th platform) and Yuanbao (18th) added in v0.12.
    public var hasTeamsPlatform: Bool { atLeastSemver(0, 12, 0) }
    public var hasYuanbaoPlatform: Bool { atLeastSemver(0, 12, 0) }

    /// Cron jobs accept `--workdir` and `--context-from` flags (v0.12+).
    public var hasCronWorkdir: Bool { atLeastSemver(0, 12, 0) }

    /// `prompt_caching.cache_ttl` config knob (v0.12+).
    public var hasPromptCacheTTL: Bool { atLeastSemver(0, 12, 0) }

    /// `redaction.enabled` is now off by default in v0.12 — Scarf surfaces
    /// the toggle so users can flip it back on.
    public var hasRedactionToggle: Bool { atLeastSemver(0, 12, 0) }

    private func atLeastSemver(_ major: Int, _ minor: Int, _ patch: Int) -> Bool {
        guard let s = semver else { return false }
        return s >= SemVer(major: major, minor: minor, patch: patch)
    }

    public struct SemVer: Sendable, Equatable, Comparable, CustomStringConvertible {
        public let major: Int
        public let minor: Int
        public let patch: Int

        public init(major: Int, minor: Int, patch: Int) {
            self.major = major
            self.minor = minor
            self.patch = patch
        }

        public var description: String { "\(major).\(minor).\(patch)" }

        public static func < (a: SemVer, b: SemVer) -> Bool {
            if a.major != b.major { return a.major < b.major }
            if a.minor != b.minor { return a.minor < b.minor }
            return a.patch < b.patch
        }
    }

    public struct DateVersion: Sendable, Equatable, Comparable, CustomStringConvertible {
        public let year: Int
        public let month: Int
        public let day: Int

        public init(year: Int, month: Int, day: Int) {
            self.year = year
            self.month = month
            self.day = day
        }

        public var description: String { "\(year).\(month).\(day)" }

        public static func < (a: DateVersion, b: DateVersion) -> Bool {
            if a.year != b.year { return a.year < b.year }
            if a.month != b.month { return a.month < b.month }
            return a.day < b.day
        }
    }

    /// Parse a `Hermes Agent v0.12.0 (2026.4.30)` line out of `hermes --version`
    /// output. Tolerates leading/trailing whitespace, extra header lines
    /// (e.g. `Project:`, `Python:`), and the absence of the parenthesized
    /// date suffix.
    ///
    /// Returns `.empty` when no recognizable version line is present so
    /// callers don't have to special-case nil.
    public static func parse(_ output: String) -> HermesCapabilities {
        for raw in output.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.contains("Hermes Agent v") else { continue }
            return parseLine(line)
        }
        return .empty
    }

    /// `Hermes Agent v0.12.0 (2026.4.30)` → semver + date. Returns `.empty`
    /// when the line doesn't match. Public for unit tests; production callers
    /// should use `parse(_:)`.
    public static func parseLine(_ line: String) -> HermesCapabilities {
        // Locate the "v" right after "Hermes Agent ". Don't anchor at line
        // start — older builds prefix with ANSI color codes Scarf would
        // need to strip.
        guard let vRange = line.range(of: "Hermes Agent v") else { return .empty }
        let tail = String(line[vRange.upperBound...])

        // Read digits separated by dots until we hit non-version content.
        // First three components are semver. A trailing `(Y.M.D)` is the
        // date version.
        let semverEnd = tail.firstIndex(where: { c in
            !(c.isNumber || c == ".")
        }) ?? tail.endIndex
        let semverStr = String(tail[..<semverEnd])
        let semverParts = semverStr.split(separator: ".").compactMap { Int($0) }
        guard semverParts.count >= 3 else { return .empty }
        let semver = SemVer(
            major: semverParts[0],
            minor: semverParts[1],
            patch: semverParts[2]
        )

        // Optional date suffix.
        var dateVersion: DateVersion?
        if let openParen = tail.firstIndex(of: "("),
           let closeParen = tail.firstIndex(of: ")"),
           openParen < closeParen {
            let dateStr = tail[tail.index(after: openParen)..<closeParen]
            let dateParts = dateStr.split(separator: ".").compactMap { Int($0) }
            if dateParts.count == 3 {
                dateVersion = DateVersion(
                    year: dateParts[0],
                    month: dateParts[1],
                    day: dateParts[2]
                )
            }
        }

        return HermesCapabilities(
            versionLine: line,
            semver: semver,
            dateVersion: dateVersion
        )
    }
}

/// Per-server capability cache. One per `ContextBoundRoot` (Mac) / iOS scene
/// root, injected via `.environment(_:)`. Refreshes once on init; callers
/// invoke `refresh()` after a Hermes update or when the server changes.
///
/// Not thread-safe across instances — each server gets its own store, and
/// the underlying `runHermesCLI` call is detached so we never block
/// MainActor.
@Observable
@MainActor
public final class HermesCapabilitiesStore {
    #if canImport(os)
    private let logger = Logger(subsystem: "com.scarf", category: "HermesCapabilities")
    #endif

    public private(set) var capabilities: HermesCapabilities = .empty
    public private(set) var isLoading = true

    public let context: ServerContext
    private var refreshTask: Task<Void, Never>?

    public init(context: ServerContext) {
        self.context = context
        // Kick off a one-shot detection. Subsequent refreshes are explicit.
        // Task captures `[weak self]`, so if the store is freed before
        // detection completes the closure simply no-ops.
        refreshTask = Task { [weak self] in
            await self?.refresh()
        }
    }

    public func refresh() async {
        isLoading = true
        let context = self.context
        let parsed = await Task.detached(priority: .utility) { () -> HermesCapabilities in
            return Self.detectSync(context: context)
        }.value

        self.capabilities = parsed
        self.isLoading = false

        #if canImport(os)
        if parsed.detected {
            logger.info("Hermes \(parsed.versionLine, privacy: .public) detected on \(self.context.displayName, privacy: .public)")
        } else {
            logger.warning("Hermes version not detected on \(self.context.displayName, privacy: .public)")
        }
        #endif
    }

    /// Synchronous detection helper. Lives here (not on `HermesCapabilities`)
    /// because `ServerContext.makeTransport()` is a side-effecting call that
    /// pulls in the platform-appropriate transport (LocalTransport on Mac,
    /// CitadelServerTransport on iOS). The pure parser remains side-effect-free.
    nonisolated private static func detectSync(context: ServerContext) -> HermesCapabilities {
        let transport = context.makeTransport()
        let executable = context.paths.hermesBinary
        do {
            let result = try transport.runProcess(
                executable: executable,
                args: ["--version"],
                stdin: nil,
                timeout: 10
            )
            // `hermes --version` writes to stdout but Scarf's transport
            // helpers occasionally split error output across stderr — fold
            // both so the parser sees whichever stream the line lands on.
            let combined = result.stdoutString + result.stderrString
            guard result.exitCode == 0 else { return .empty }
            return HermesCapabilities.parse(combined)
        } catch {
            return .empty
        }
    }
}

// MARK: - SwiftUI environment wiring

#if canImport(SwiftUI)
import SwiftUI

private struct HermesCapabilitiesStoreKey: EnvironmentKey {
    static let defaultValue: HermesCapabilitiesStore? = nil
}

extension EnvironmentValues {
    /// The active server's capability store. `nil` outside the per-server
    /// `ContextBoundRoot`. Callers should treat `nil` and `.empty` capabilities
    /// the same — defensive code for harness scenarios (Previews, smoke tests).
    public var hermesCapabilities: HermesCapabilitiesStore? {
        get { self[HermesCapabilitiesStoreKey.self] }
        set { self[HermesCapabilitiesStoreKey.self] = newValue }
    }
}

extension View {
    /// Inject a `HermesCapabilitiesStore` into the environment. Mirrors the
    /// usual `.environment(_:)` shape but routes through the typed key
    /// above so callers don't need to import the key.
    public func hermesCapabilities(_ store: HermesCapabilitiesStore) -> some View {
        environment(\.hermesCapabilities, store)
    }
}
#endif
