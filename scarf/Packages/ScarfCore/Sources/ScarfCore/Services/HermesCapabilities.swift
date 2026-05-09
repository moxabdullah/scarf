import Foundation
import Observation
#if canImport(os)
import os
#endif

/// What this Hermes installation can do, derived from `hermes --version`.
///
/// Scarf tracks Hermes feature releases by date-version + semver. v0.12 added
/// a dozen surfaces (Curator, Kanban, multimodal ACP, ...) and removed a few
/// (`flush_memories` aux task); v0.13 added Persistent Goals, ACP `/queue`,
/// Kanban diagnostics + recovery UX, Curator archive/prune, Google Chat (20th
/// platform), cross-platform allowlists, MCP SSE transport, Cron `no_agent`
/// mode, Web Tools per-capability backends, Profiles `--no-skills`, and a
/// handful of UX additions. UI that branches on these surfaces calls the
/// boolean accessors here so older Hermes installs degrade silently instead
/// of throwing on an unknown CLI subcommand.
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
    // a Hermes capability. Keep the comparison conservative: a flag introduced
    // in v0.13.0 should gate on `>= 0.13.0`, not `>= 0.13.5`, so users on
    // an early 0.13 patch still see the surface.

    // MARK: v0.12 (v2026.4.30) flags

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
    /// the toggle so users can flip it back on. v0.13 flips the server-side
    /// default back to ON; the toggle remains so users on v0.13 can opt out.
    public var hasRedactionToggle: Bool { atLeastSemver(0, 12, 0) }

    // MARK: v0.13 (v2026.5.7) flags

    /// `/goal` slash command + Persistent Goals + Checkpoints v2 single-store
    /// (v0.13+). Used by RichChatViewModel to add `/goal` to the
    /// non-interruptive command list and to render the "Goal locked" pill in
    /// the chat header.
    public var hasGoals: Bool { atLeastSemver(0, 13, 0) }

    /// `/queue` slash command in the ACP adapter (v0.13+). Queues a prompt
    /// to run after the current turn completes without interrupting.
    public var hasACPQueue: Bool { atLeastSemver(0, 13, 0) }

    /// `/steer` runs as a regular prompt on idle ACP sessions (v0.13+). Pre-
    /// v0.13 hosts silently no-op `/steer` when no turn is in flight; with
    /// this flag on, Scarf can surface `/steer` even when the agent isn't
    /// mid-turn without confusing UX.
    public var hasACPSteerOnIdle: Bool { atLeastSemver(0, 13, 0) }

    /// Kanban v0.13 reliability surface: hallucination gate on worker-created
    /// cards, generic diagnostics engine, per-task `max_retries`, multiline
    /// title/body create, `auto_blocked_reason` on blocked tasks, darwin
    /// zombie detection. All read through the `kanban show` JSON surface.
    public var hasKanbanDiagnostics: Bool { atLeastSemver(0, 13, 0) }

    /// `hermes curator archive`, `prune`, and `list-archived` subcommands
    /// (v0.13+). The synchronous manual `hermes curator run` lives behind
    /// this flag too — pre-v0.13 `run` returns immediately and the work
    /// happens in the background.
    public var hasCuratorArchive: Bool { atLeastSemver(0, 13, 0) }

    /// Google Chat — 20th messaging-gateway platform (v0.13+).
    public var hasGoogleChatPlatform: Bool { atLeastSemver(0, 13, 0) }

    /// Cross-platform allowlist keys: `allowed_channels` (Slack / Mattermost
    /// / Google Chat), `allowed_chats` (Telegram / WhatsApp), `allowed_rooms`
    /// (Matrix / DingTalk). Settable per platform in `config.yaml` (v0.13+).
    public var hasGatewayAllowlists: Bool { atLeastSemver(0, 13, 0) }

    /// `busy_ack_enabled` config to suppress per-message "agent is working…"
    /// acks across platforms (v0.13+).
    public var hasGatewayBusyAckToggle: Bool { atLeastSemver(0, 13, 0) }

    /// Per-platform `gateway_restart_notification` flag controls whether the
    /// platform posts a "Gateway restarted" notice on boot (v0.13+).
    public var hasGatewayRestartNotification: Bool { atLeastSemver(0, 13, 0) }

    /// `hermes gateway list` cross-profile status verb (v0.13+). Lets Scarf
    /// show which profile is currently running which platform.
    public var hasGatewayList: Bool { atLeastSemver(0, 13, 0) }

    /// MCP servers can use SSE transport (v0.13+). Adds an `sse_read_timeout`
    /// knob alongside the existing stdio/pipe transports.
    public var hasMCPSSETransport: Bool { atLeastSemver(0, 13, 0) }

    /// Cron `--no-agent` mode for script-only watchdog jobs (v0.13+). Skips
    /// the AI call entirely — useful for keep-alive / periodic-check jobs.
    public var hasCronNoAgent: Bool { atLeastSemver(0, 13, 0) }

    /// Web Tools split into per-capability backend selection: `web_search`
    /// and `web_extract` can now use distinct backends (v0.13+). SearXNG
    /// joined as a search-only backend.
    public var hasWebToolsBackendSplit: Bool { atLeastSemver(0, 13, 0) }

    /// `hermes profile create --no-skills` flag for empty profiles (v0.13+).
    public var hasProfileNoSkills: Bool { atLeastSemver(0, 13, 0) }

    /// Context compression count surfaced in the status feed (v0.13+). Scarf
    /// renders it next to the token count in the chat status bar.
    public var hasContextCompressionCount: Bool { atLeastSemver(0, 13, 0) }

    /// `/new` slash command accepts an optional session-name argument (v0.13+).
    public var hasNewWithSessionName: Bool { atLeastSemver(0, 13, 0) }

    /// `hermes update --yes` / `-y` skips interactive prompts (v0.13+). Used
    /// by Scarf's "Update Hermes" affordance to run unattended.
    public var hasUpdateNonInteractive: Bool { atLeastSemver(0, 13, 0) }

    /// OpenRouter response caching toggle in `config.yaml` (v0.13+).
    public var hasOpenRouterResponseCache: Bool { atLeastSemver(0, 13, 0) }

    /// `image_gen.model` honored from `config.yaml` (v0.13+). Pre-v0.13 the
    /// value was advertised but ignored at runtime.
    public var hasImageGenModel: Bool { atLeastSemver(0, 13, 0) }

    /// `display.language` config key for static-message translation: zh / ja /
    /// de / es / fr / uk / tr (v0.13+).
    public var hasDisplayLanguage: Bool { atLeastSemver(0, 13, 0) }

    /// xAI Custom Voices — voice cloning support (v0.13+). Exposed in Scarf
    /// as a "Cloning supported" badge next to the xAI TTS provider entry.
    public var hasXAIVoiceCloning: Bool { atLeastSemver(0, 13, 0) }

    /// `video_analyze` tool — native video understanding on Gemini and
    /// compatible models (v0.13+). Hermes handles this transparently inside
    /// the agent loop; Scarf has no UI surface yet, but the flag lets future
    /// dashboards / activity views light up video-tool annotations.
    public var hasVideoAnalyze: Bool { atLeastSemver(0, 13, 0) }

    /// `transform_llm_output` plugin hook for shaping LLM output before the
    /// conversation receives it (v0.13+). Plugin-author concern; Scarf's
    /// PluginsView surfaces it as a documented hook in plugin metadata.
    public var hasTransformLLMOutputHook: Bool { atLeastSemver(0, 13, 0) }

    // MARK: Convenience predicates

    /// Whether the connected host is on the v0.13 line or newer. Convenience
    /// for UI copy that needs to switch on the v0.12 → v0.13 boundary without
    /// proxying through a feature-specific flag (e.g. "v0.13 features active"
    /// badges, redaction default-state hints). Equivalent to any individual
    /// v0.13 flag; prefer this when the call site isn't actually about a
    /// specific feature.
    public var isV013OrLater: Bool { atLeastSemver(0, 13, 0) }

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
