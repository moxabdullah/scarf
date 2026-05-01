import Foundation

/// One task from `hermes kanban list --json` (v0.12+).
///
/// Hermes ships a SQLite-backed task board under `~/.hermes/kanban.db`
/// — multi-profile collaboration was reverted upstream while the
/// design is reworked, so Scarf v2.6 surfaces this as a read-only
/// list. Create / claim / dispatch / dependency-link UI is deferred
/// until upstream stabilizes.
public struct HermesKanbanTask: Sendable, Equatable, Identifiable, Codable {
    public let id: String
    public let title: String
    public let body: String?
    public let assignee: String?
    public let status: String          // archived | blocked | done | ready | running | todo | triage
    public let priority: Int?
    public let tenant: String?
    public let workspaceKind: String?  // scratch | worktree | dir
    public let workspacePath: String?
    public let createdBy: String?
    public let createdAt: String?      // ISO timestamp
    public let startedAt: String?
    public let completedAt: String?
    public let result: String?
    public let skills: [String]

    public init(
        id: String,
        title: String,
        body: String? = nil,
        assignee: String? = nil,
        status: String,
        priority: Int? = nil,
        tenant: String? = nil,
        workspaceKind: String? = nil,
        workspacePath: String? = nil,
        createdBy: String? = nil,
        createdAt: String? = nil,
        startedAt: String? = nil,
        completedAt: String? = nil,
        result: String? = nil,
        skills: [String] = []
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.assignee = assignee
        self.status = status
        self.priority = priority
        self.tenant = tenant
        self.workspaceKind = workspaceKind
        self.workspacePath = workspacePath
        self.createdBy = createdBy
        self.createdAt = createdAt
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.result = result
        self.skills = skills
    }

    enum CodingKeys: String, CodingKey {
        case id, title, body, assignee, status, priority, tenant
        case workspaceKind = "workspace_kind"
        case workspacePath = "workspace_path"
        case createdBy = "created_by"
        case createdAt = "created_at"
        case startedAt = "started_at"
        case completedAt = "completed_at"
        case result, skills
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.title = try c.decode(String.self, forKey: .title)
        self.body = try c.decodeIfPresent(String.self, forKey: .body)
        self.assignee = try c.decodeIfPresent(String.self, forKey: .assignee)
        self.status = try c.decodeIfPresent(String.self, forKey: .status) ?? "unknown"
        self.priority = try c.decodeIfPresent(Int.self, forKey: .priority)
        self.tenant = try c.decodeIfPresent(String.self, forKey: .tenant)
        self.workspaceKind = try c.decodeIfPresent(String.self, forKey: .workspaceKind)
        self.workspacePath = try c.decodeIfPresent(String.self, forKey: .workspacePath)
        self.createdBy = try c.decodeIfPresent(String.self, forKey: .createdBy)
        self.createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt)
        self.startedAt = try c.decodeIfPresent(String.self, forKey: .startedAt)
        self.completedAt = try c.decodeIfPresent(String.self, forKey: .completedAt)
        self.result = try c.decodeIfPresent(String.self, forKey: .result)
        self.skills = try c.decodeIfPresent([String].self, forKey: .skills) ?? []
    }
}
