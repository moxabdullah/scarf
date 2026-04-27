import Foundation
#if canImport(os)
import os
#endif

/// Detects when a registered project directory contains its own `.hermes/`
/// subdirectory. Hermes' CLI uses the closest `.hermes/` as `$HERMES_HOME`
/// when invoked from inside such a directory, which **shadows** the user's
/// global Hermes home — credentials, config, sessions, skills, memories
/// all bind to the project-local copy without warning.
///
/// This causes confusing failure modes: the user runs `hermes auth add nous`
/// during setup expecting a global registration, but if their cwd happens to
/// be inside a project that already has a `.hermes/` (e.g. seeded by a
/// previous workflow, copied from another machine, or checked into git),
/// Hermes writes the credentials to the project-local `.hermes/auth.json`.
/// Scarf then reads the global path on every dashboard tick and shows
/// "missing provider" warnings even though the user did sign in successfully.
///
/// The detector enumerates the registered projects on a given server and
/// reports which ones carry a shadowing `.hermes/`. Views surface a yellow
/// banner so the user can consolidate.
public struct ProjectHermesShadowDetector: Sendable {
    public struct Shadow: Sendable, Hashable, Identifiable {
        public var id: String { projectPath }
        /// Project name from the registry (`ProjectEntry.name`).
        public let projectName: String
        /// Absolute path to the project on the target server.
        public let projectPath: String
        /// Absolute path to the shadowing `.hermes/` directory.
        public let shadowPath: String
        /// `true` when the shadow `.hermes/auth.json` exists. Strong signal
        /// that user credentials are landing in the wrong place.
        public let hasAuthJSON: Bool
        /// `true` when the shadow `.hermes/state.db` exists. Hermes wrote
        /// session state to the project-local home — the user's chat
        /// history is invisible to Scarf's global Dashboard for this slice.
        public let hasStateDB: Bool

        public init(
            projectName: String,
            projectPath: String,
            shadowPath: String,
            hasAuthJSON: Bool,
            hasStateDB: Bool
        ) {
            self.projectName = projectName
            self.projectPath = projectPath
            self.shadowPath = shadowPath
            self.hasAuthJSON = hasAuthJSON
            self.hasStateDB = hasStateDB
        }
    }

    #if canImport(os)
    private static let logger = Logger(subsystem: "com.scarf", category: "ProjectHermesShadowDetector")
    #endif

    private let context: ServerContext
    private let transport: any ServerTransport

    public init(context: ServerContext) {
        self.context = context
        self.transport = context.makeTransport()
    }

    /// Probe every project in `projects` for a shadowing `.hermes/`. Skips
    /// archived projects and projects whose absolute path equals the
    /// resolved Hermes home (rare but possible — a project literally
    /// rooted at `~/.hermes` shouldn't trigger a self-warning).
    public func detect(in projects: [ProjectEntry]) async -> [Shadow] {
        let hermesHome = await context.resolvedUserHome() + "/.hermes"
        var found: [Shadow] = []
        for project in projects where !project.archived {
            // A project nested inside the Hermes home itself is a weird
            // edge case (someone made `~/.hermes/notes` a Scarf project).
            // The project is BELOW the Hermes home, so its `.hermes` is
            // the same dir as `~/.hermes/.hermes` — almost certainly not
            // present and definitely not a shadow.
            if project.path.hasPrefix(hermesHome) { continue }
            let shadowPath = project.path + "/.hermes"
            guard transport.fileExists(shadowPath) else { continue }
            // It's only a shadow if the path is a directory; a stray
            // `.hermes` file would be filtered out here.
            guard transport.stat(shadowPath)?.isDirectory == true else { continue }
            let hasAuth = transport.fileExists(shadowPath + "/auth.json")
            let hasDB   = transport.fileExists(shadowPath + "/state.db")
            #if canImport(os)
            Self.logger.warning(
                "Detected shadow Hermes home at \(shadowPath, privacy: .public) (auth: \(hasAuth), state.db: \(hasDB))"
            )
            #endif
            found.append(Shadow(
                projectName: project.name,
                projectPath: project.path,
                shadowPath: shadowPath,
                hasAuthJSON: hasAuth,
                hasStateDB: hasDB
            ))
        }
        return found
    }

    /// Suggested shell command the user can copy-paste / run on the remote
    /// to consolidate a shadow's auth.json into their global Hermes home.
    /// Skips state.db / sessions / skills migration intentionally — those
    /// require Hermes to be quiesced and risk data loss; the user should
    /// decide what to keep on a case-by-case basis. We give them the
    /// load-bearing one-liner (auth) and let them handle the rest.
    public static func consolidationCommand(for shadow: Shadow, hermesHome: String) -> String? {
        guard shadow.hasAuthJSON else { return nil }
        return "cp \(shadow.shadowPath)/auth.json \(hermesHome)/auth.json && chmod 600 \(hermesHome)/auth.json"
    }
}
