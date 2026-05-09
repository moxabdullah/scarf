import Foundation

/// Cross-profile snapshot returned by `hermes gateway list --json` (Hermes
/// v0.13+). Each profile is one configured Messaging Gateway instance — most
/// users have a single `default` profile, but power users keep separate
/// profiles for work / personal / project-specific accounts.
public struct GatewayListSnapshot: Sendable, Equatable {
    public struct ProfileEntry: Sendable, Equatable {
        public let profile: String
        public let isRunning: Bool
        public let pid: Int?
        public let platforms: [String]   // platform names connected/configured

        public init(
            profile: String,
            isRunning: Bool,
            pid: Int?,
            platforms: [String]
        ) {
            self.profile = profile
            self.isRunning = isRunning
            self.pid = pid
            self.platforms = platforms
        }
    }
    public let profiles: [ProfileEntry]
    public let detectedAt: Date

    public init(profiles: [ProfileEntry], detectedAt: Date = Date()) {
        self.profiles = profiles
        self.detectedAt = detectedAt
    }

    /// One-line digest for the Messaging Gateway page header. Format depends
    /// on shape:
    /// - 0 profiles: `"no profiles configured"`
    /// - 1 profile, running: `"default profile · running · slack, telegram"`
    /// - 1 profile, stopped: `"default profile · stopped"`
    /// - >1 profile: `"3 profiles (2 running) · default: slack, telegram"`
    public var headerDigest: String {
        if profiles.isEmpty { return "no profiles configured" }

        if profiles.count == 1 {
            let p = profiles[0]
            let state = p.isRunning ? "running" : "stopped"
            if p.isRunning && !p.platforms.isEmpty {
                let plats = p.platforms.joined(separator: ", ")
                return "\(p.profile) profile · \(state) · \(plats)"
            }
            return "\(p.profile) profile · \(state)"
        }

        let runningCount = profiles.filter(\.isRunning).count
        // Surface the platforms of the first running profile (or first profile
        // if none are running) so the digest carries one specimen of context
        // beyond just counts.
        let highlight = profiles.first(where: \.isRunning) ?? profiles[0]
        let platsClause: String
        if highlight.platforms.isEmpty {
            platsClause = ""
        } else {
            platsClause = " · \(highlight.profile): \(highlight.platforms.joined(separator: ", "))"
        }
        return "\(profiles.count) profiles (\(runningCount) running)\(platsClause)"
    }
}

/// Pure parser + sync fetcher for `hermes gateway list --json`. Pre-v0.13
/// hosts exit non-zero on the unknown subcommand; the fetcher returns `nil`
/// in that case so the digest row hides itself.
///
/// The detection is **synchronous** — run from a `Task.detached` to avoid
/// blocking MainActor on remote SSH round-trips. The pure `parse(_:)`
/// helper has no I/O and can be used in tests against canned JSON.
public enum HermesGatewayListService {

    /// Parse a JSON blob from `hermes gateway list --json` into a snapshot.
    /// Tolerant of unknown keys; returns `nil` for unparseable / empty input.
    ///
    /// // TODO(WS-5-Q3): the JSON shape below is the plan's best-guess.
    /// Confirm against actual Hermes v0.13 output once available. Possible
    /// alternative shapes:
    /// - root array of profile objects (no `profiles` wrapper)
    /// - `state` enum string instead of `running` bool
    /// - `connected_platforms` instead of `platforms`
    /// The parser is intentionally tolerant so a small shape change can be
    /// absorbed by tweaking field names without breaking older fixtures.
    public static func parse(_ json: Data) -> GatewayListSnapshot? {
        guard !json.isEmpty,
              let raw = try? JSONSerialization.jsonObject(with: json) else {
            return nil
        }

        // Accept both `{"profiles": [...]}` and a bare `[...]` of profiles.
        let profilesArray: [Any]
        if let dict = raw as? [String: Any], let arr = dict["profiles"] as? [Any] {
            profilesArray = arr
        } else if let arr = raw as? [Any] {
            profilesArray = arr
        } else {
            return nil
        }

        var entries: [GatewayListSnapshot.ProfileEntry] = []
        for raw in profilesArray {
            guard let obj = raw as? [String: Any] else { continue }
            let profile = (obj["name"] as? String)
                ?? (obj["profile"] as? String)
                ?? "default"
            let isRunning: Bool
            if let v = obj["running"] as? Bool {
                isRunning = v
            } else if let s = obj["state"] as? String {
                isRunning = s.lowercased() == "running"
            } else {
                isRunning = false
            }
            let pid = obj["pid"] as? Int
            let platforms = (obj["platforms"] as? [String])
                ?? (obj["connected_platforms"] as? [String])
                ?? []
            entries.append(GatewayListSnapshot.ProfileEntry(
                profile: profile,
                isRunning: isRunning,
                pid: pid,
                platforms: platforms
            ))
        }
        return GatewayListSnapshot(profiles: entries)
    }

    /// Synchronous fetch helper — call from a `Task.detached`. Returns
    /// `nil` when the subcommand fails (pre-v0.13 host) or when the
    /// output isn't parseable.
    public static func fetch(context: ServerContext) -> GatewayListSnapshot? {
        let transport = context.makeTransport()
        let executable = context.paths.hermesBinary
        do {
            let result = try transport.runProcess(
                executable: executable,
                args: ["gateway", "list", "--json"],
                stdin: nil,
                timeout: 10
            )
            guard result.exitCode == 0 else { return nil }
            return parse(result.stdout)
        } catch {
            return nil
        }
    }
}
