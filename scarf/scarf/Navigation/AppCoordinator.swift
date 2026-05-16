import Foundation

enum SidebarSection: String, CaseIterable, Identifiable {
    // Monitor
    case dashboard = "Dashboard"
    case insights = "Insights"
    case sessions = "Sessions"
    case activity = "Activity"
    // Projects
    case projects = "Projects"
    // Interact
    case chat = "Chat"
    case memory = "Memory"
    case curator = "Curator"
    case skills = "Skills"
    // Configure (Phase 2/3 additions)
    case platforms = "Platforms"
    case personalities = "Personalities"
    case quickCommands = "Quick Commands"
    case credentialPools = "Credential Pools"
    case plugins = "Plugins"
    case webhooks = "Webhooks"
    case profiles = "Profiles"
    case models = "Models"
    // Manage
    case tools = "Tools"
    case mcpServers = "MCP Servers"
    case gateway = "Gateway"
    case cron = "Cron"
    case kanban = "Kanban"
    case health = "Health"
    case logs = "Logs"
    case settings = "Settings"

    var id: String { rawValue }

    var displayName: LocalizedStringResource {
        switch self {
        case .dashboard: return "Dashboard"
        case .insights: return "Insights"
        case .sessions: return "Sessions"
        case .activity: return "Activity"
        case .projects: return "Projects"
        case .chat: return "Chat"
        case .memory: return "Memory"
        case .curator: return "Curator"
        case .skills: return "Skills"
        case .platforms: return "Platforms"
        case .personalities: return "Personalities"
        case .quickCommands: return "Quick Commands"
        case .credentialPools: return "Credential Pools"
        case .plugins: return "Plugins"
        case .webhooks: return "Webhooks"
        case .profiles: return "Profiles"
        case .models: return "Models"
        case .tools: return "Tools"
        case .mcpServers: return "MCP Servers"
        case .gateway: return "Messaging Gateway"
        case .cron: return "Cron"
        case .kanban: return "Kanban"
        case .health: return "Health"
        case .logs: return "Logs"
        case .settings: return "Settings"
        }
    }

    var icon: String {
        switch self {
        case .dashboard: return "gauge.with.dots.needle.33percent"
        case .insights: return "chart.bar"
        case .sessions: return "bubble.left.and.bubble.right"
        case .activity: return "bolt.horizontal"
        case .projects: return "square.grid.2x2"
        case .chat: return "text.bubble"
        case .memory: return "brain"
        case .curator: return "sparkles"
        case .skills: return "lightbulb"
        case .platforms: return "dot.radiowaves.left.and.right"
        case .personalities: return "theatermasks"
        case .quickCommands: return "command.square"
        case .credentialPools: return "key.horizontal"
        case .plugins: return "app.badge.checkmark"
        case .webhooks: return "arrow.up.right.square"
        case .profiles: return "person.2.crop.square.stack"
        case .models: return "cpu"
        case .tools: return "wrench.and.screwdriver"
        case .mcpServers: return "puzzlepiece.extension"
        case .gateway: return "antenna.radiowaves.left.and.right"
        case .cron: return "clock.arrow.2.circlepath"
        case .kanban: return "rectangle.split.3x1"
        case .health: return "stethoscope"
        case .logs: return "doc.text"
        case .settings: return "gearshape"
        }
    }
}

@Observable
final class AppCoordinator {
    var selectedSection: SidebarSection = .dashboard
    var selectedSessionId: String?
    var selectedProjectName: String?

    /// When non-nil, ChatView should start a fresh ACP session with
    /// this absolute project path as cwd and then clear the value.
    /// Wired from the per-project Sessions tab's "New Chat" button
    /// (v2.3): the tab sets this, switches `selectedSection` to
    /// `.chat`, and ChatView reacts on its next render.
    ///
    /// Separate from `selectedSessionId` (which resumes an existing
    /// session) — a new session needs a cwd override Scarf doesn't
    /// yet have an id for.
    var pendingProjectChat: String?

    /// Optional first message to send automatically once a
    /// `pendingProjectChat` session has connected. Set alongside
    /// `pendingProjectChat` by the "New Project from Scratch" wizard
    /// (v2.8) so the agent receives a kickoff prompt that activates
    /// the `scarf-template-author` skill without the user having to
    /// type one. Sister slot to `pendingProjectChat`: ChatView consumes
    /// both in lockstep and clears them. Nil for plain "open project
    /// chat" handoffs (the Sessions tab's "New Chat" button).
    var pendingInitialPrompt: String?

    /// Lowercase OAuth provider name to re-authenticate. Set by the
    /// chat error banner's "Re-authenticate" button, consumed by
    /// CredentialPoolsView, which auto-presents the OAuth sheet seeded
    /// to this provider. Cleared by the consumer once handled. Sister
    /// of `pendingProjectChat` — a hand-off slot, not a long-lived
    /// state value.
    var pendingOAuthReauth: String?

    /// Hand-off from the chat surface to the global Kanban surface.
    /// Set by `SessionInfoBar`'s Kanban chip, consumed by `KanbanView`
    /// on its next render, which builds a `KanbanBoardView` with the
    /// tenant + project pre-applied AND seeds the "Since chat opened"
    /// time filter from `sessionOpenedAt`. Cleared after consumption
    /// so a sidebar return to the same Kanban surface doesn't re-apply
    /// a stale filter.
    var pendingKanbanHandoff: KanbanHandoff?
}

/// Snapshot of "where did this Kanban view come from?" passed across
/// the AppCoordinator hand-off. The destination view consumes the
/// fields at most once. `tenant` is the project's `scarf:<slug>` slug
/// when the chat is project-scoped; nil for global chats. `projectPath`
/// + `projectName` drive the create-sheet workspace defaults +
/// subtitle. `sessionOpenedAt` seeds the optional client-side
/// "Since chat opened" filter — it's a wall-clock time, not the
/// underlying session's `created_at`, so resumed sessions still get
/// a meaningful baseline.
struct KanbanHandoff: Equatable {
    let tenant: String?
    let projectPath: String?
    let projectName: String?
    let sessionOpenedAt: Date
}
