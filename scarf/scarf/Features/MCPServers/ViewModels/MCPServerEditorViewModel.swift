import Foundation
import ScarfCore

@Observable
final class MCPServerEditorViewModel {
    struct KeyValueRow: Identifiable, Equatable {
        let id = UUID()
        var key: String
        var value: String
    }

    let context: ServerContext
    private let fileService: HermesFileService
    let server: HermesMCPServer

    var envDraft: [KeyValueRow]
    var headersDraft: [KeyValueRow]
    var includeDraft: String
    var excludeDraft: String
    var resourcesEnabled: Bool
    var promptsEnabled: Bool
    var timeoutDraft: String
    var connectTimeoutDraft: String
    /// SSE-only — renders as a third numeric on `.sse` servers. Empty string
    /// means "use Hermes default" (writer drops the scalar).
    var sseReadTimeoutDraft: String
    /// v0.14 — supports_parallel_tool_calls toggle. Three states:
    /// nil = "use Hermes default" (no key written), true = opt in,
    /// false = opt out explicitly. Bound to a tri-state Picker in the
    /// editor under the v0.14 capability gate.
    var parallelToolCallsDraft: Bool?
    var showSecrets: Bool = false
    var isSaving: Bool = false
    var saveError: String?

    init(server: HermesMCPServer, context: ServerContext = .local) {
        self.server = server
        self.context = context
        self.fileService = HermesFileService(context: context)
        self.envDraft = server.env.keys.sorted().map { KeyValueRow(key: $0, value: server.env[$0] ?? "") }
        self.headersDraft = server.headers.keys.sorted().map { KeyValueRow(key: $0, value: server.headers[$0] ?? "") }
        self.includeDraft = server.toolsInclude.joined(separator: ", ")
        self.excludeDraft = server.toolsExclude.joined(separator: ", ")
        self.resourcesEnabled = server.resourcesEnabled
        self.promptsEnabled = server.promptsEnabled
        self.timeoutDraft = server.timeout.map { String($0) } ?? ""
        self.connectTimeoutDraft = server.connectTimeout.map { String($0) } ?? ""
        self.sseReadTimeoutDraft = server.sseReadTimeout.map { String($0) } ?? ""
        self.parallelToolCallsDraft = server.supportsParallelToolCalls
    }

    func appendEnvRow() {
        envDraft.append(KeyValueRow(key: "", value: ""))
    }

    func removeEnvRow(id: UUID) {
        envDraft.removeAll { $0.id == id }
    }

    func appendHeaderRow() {
        headersDraft.append(KeyValueRow(key: "", value: ""))
    }

    func removeHeaderRow(id: UUID) {
        headersDraft.removeAll { $0.id == id }
    }

    func save(completion: @escaping (Bool) -> Void) {
        isSaving = true
        saveError = nil

        let envMap = Dictionary(uniqueKeysWithValues: envDraft
            .filter { !$0.key.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { ($0.key.trimmingCharacters(in: .whitespaces), $0.value) })
        let headerMap = Dictionary(uniqueKeysWithValues: headersDraft
            .filter { !$0.key.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { ($0.key.trimmingCharacters(in: .whitespaces), $0.value) })
        let include = includeDraft.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let exclude = excludeDraft.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let timeoutValue = Int(timeoutDraft.trimmingCharacters(in: .whitespaces))
        let connectValue = Int(connectTimeoutDraft.trimmingCharacters(in: .whitespaces))
        let trimmedSSE = sseReadTimeoutDraft.trimmingCharacters(in: .whitespaces)
        let sseTimeoutValue: Int? = trimmedSSE.isEmpty ? nil : Int(trimmedSSE)
        let parallelDraft = parallelToolCallsDraft
        let originalParallel = server.supportsParallelToolCalls

        let service = fileService
        let transport = server.transport
        let name = server.name
        let resources = resourcesEnabled
        let prompts = promptsEnabled

        Task.detached {
            // Compute success as an immutable so the MainActor.run closure
            // captures a value, not a mutable var. Swift 6 rejects
            // var-captures across concurrent closures as data races.
            let success: Bool = {
                var ok = true
                switch transport {
                case .stdio:
                    if !service.setMCPServerEnv(name: name, env: envMap) { ok = false }
                case .http:
                    if !service.setMCPServerHeaders(name: name, headers: headerMap) { ok = false }
                case .sse:
                    // SSE servers carry headers like .http does, plus an
                    // optional sse_read_timeout written below.
                    if !service.setMCPServerHeaders(name: name, headers: headerMap) { ok = false }
                    if !service.setMCPServerSSETimeout(name: name, sseReadTimeout: sseTimeoutValue) { ok = false }
                }
                if !service.updateMCPToolFilters(
                    name: name,
                    include: include,
                    exclude: exclude,
                    resources: resources,
                    prompts: prompts
                ) { ok = false }
                if !service.setMCPServerTimeouts(name: name, timeout: timeoutValue, connectTimeout: connectValue) {
                    ok = false
                }
                // v0.14 — only write the parallel-tool-calls scalar when
                // the user touched the field. Skipping a no-op write
                // keeps the YAML diff small and avoids churning the
                // file when the toggle wasn't surfaced (pre-v0.14 hosts
                // hide the row entirely, so parallelDraft == originalParallel
                // there as well).
                if parallelDraft != originalParallel {
                    if !service.setMCPServerParallelToolCalls(name: name, enabled: parallelDraft) {
                        ok = false
                    }
                }
                return ok
            }()
            await MainActor.run {
                self.isSaving = false
                if !success {
                    self.saveError = "One or more fields could not be written. Check \(self.context.paths.configYAML)."
                }
                completion(success)
            }
        }
    }

    func clearOAuthToken(completion: @escaping (Bool) -> Void) {
        let service = fileService
        let name = server.name
        Task.detached {
            let ok = service.deleteMCPOAuthToken(name: name)
            await MainActor.run { completion(ok) }
        }
    }
}
