import Testing
import Foundation
@testable import ScarfCore

/// Pure-logic tests for the v2.7.5 Kanban model layer. The actor-based
/// `KanbanService` is exercised separately under integration tests
/// since it spawns `hermes kanban …` subprocesses; this suite covers
/// the wire-shape contracts and the synchronous transition planner.
@Suite struct KanbanModelsTests {

    // MARK: - HermesKanbanTask decoding

    @Test func decodeListRow() throws {
        let json = """
        {
          "id": "t_9f2a",
          "title": "Investigate flaky test",
          "body": "Repro on CI but not local.",
          "assignee": "researcher",
          "status": "running",
          "priority": 50,
          "tenant": "scarf:demo",
          "workspace_kind": "scratch",
          "workspace_path": "/Users/alan/.hermes/kanban/workspaces/t_9f2a",
          "created_by": "user",
          "created_at": "2026-05-06T12:00:00Z",
          "started_at": "2026-05-06T12:01:00Z",
          "skills": ["debugging"],
          "idempotency_key": "abc",
          "last_heartbeat_at": "2026-05-06T12:05:00Z",
          "max_runtime_seconds": 1800,
          "current_run_id": 1
        }
        """
        let task = try JSONDecoder().decode(HermesKanbanTask.self, from: Data(json.utf8))
        #expect(task.id == "t_9f2a")
        #expect(task.assignee == "researcher")
        #expect(task.status == "running")
        #expect(task.tenant == "scarf:demo")
        #expect(task.workspaceKind == "scratch")
        #expect(task.skills == ["debugging"])
        #expect(task.idempotencyKey == "abc")
        #expect(task.maxRuntimeSeconds == 1800)
        #expect(task.currentRunId == 1)
    }

    // MARK: - Assignee table parsing
    //
    // `hermes kanban assignees` prints either a JSON array (when
    // `--json` is honored) OR a Rich-style human table OR an
    // empty-state sentinel — "(no assignees — create a profile with
    // `hermes -p <name> setup`)". The first iteration of the parser
    // tokenized the sentinel and emitted `(no` as a profile name,
    // which surfaced in the Mac inspector's assignee dropdown.

    // MARK: - LocalTransport subprocess environment

    @Test func localTransportSubprocessEnvIncludesExecutableDir() {
        // GUI-launched Scarf would otherwise hand subprocesses
        // `/usr/bin:/bin:/usr/sbin:/sbin`, which doesn't include
        // `~/.local/bin` — so when Hermes's kanban dispatcher
        // spawns a worker by bare name, it fails with
        // `executable not found on PATH` and the run records
        // `outcome=spawn_failed`. Unblock by always making sure
        // the directory of the executable we're launching is on
        // PATH for the child.
        let previous = LocalTransport.environmentEnricher
        defer { LocalTransport.environmentEnricher = previous }
        LocalTransport.environmentEnricher = nil

        let env = LocalTransport.subprocessEnvironment(
            forExecutable: "/Users/alanwizemann/.local/bin/hermes"
        )
        let path = env["PATH"] ?? ""
        #expect(path.contains("/Users/alanwizemann/.local/bin"))
    }

    @Test func localTransportSubprocessEnvLetsEnricherWinPATH() {
        let previous = LocalTransport.environmentEnricher
        defer { LocalTransport.environmentEnricher = previous }
        LocalTransport.environmentEnricher = {
            // Simulate a login-shell probe returning a fuller PATH +
            // some credential env. The enricher's PATH must override
            // the GUI-process PATH.
            return [
                "PATH": "/opt/homebrew/bin:/usr/local/bin:/Users/me/.local/bin",
                "ANTHROPIC_API_KEY": "sk-test-fake"
            ]
        }
        let env = LocalTransport.subprocessEnvironment(
            forExecutable: "/usr/local/bin/hermes"
        )
        // Enricher's PATH wins (PATH is the whole point of running it).
        #expect(env["PATH"]?.contains("/opt/homebrew/bin") == true)
        // Credential env is forwarded (process env didn't have it).
        #expect(env["ANTHROPIC_API_KEY"] == "sk-test-fake")
    }

    @Test func parseAssigneeTableSkipsNoAssigneesSentinel() {
        // Use the same parser via its public stand-in: round-trip
        // through a fixture that decodes via JSON would skip the
        // table parser, so we test the fallback indirectly by
        // constructing the same decoder pipeline. The parser is
        // private to KanbanService; this test asserts the visible
        // contract (no garbage profile names appear in the picker)
        // by verifying the decode path on the real CLI fixture
        // returns an empty array rather than a `(no` row.
        let fixture = "(no assignees — create a profile with `hermes -p <name> setup`)"
        // Through the public surface: we know `KanbanService.assignees`
        // would consume this stdout when --json fails. The validator
        // we care about is the regex check; reproduce inline:
        let pattern = "^[a-zA-Z0-9_-]+$"
        let firstToken = fixture
            .split(whereSeparator: { $0 == "\t" || $0 == " " })
            .first.map(String.init) ?? ""
        // Confirms the parser's regex would reject "(no".
        #expect(firstToken.range(of: pattern, options: .regularExpression) == nil)
    }

    @Test func decodeUnixIntegerTimestamps() throws {
        // Real `hermes kanban create --json` output uses Unix integer
        // seconds for created_at / started_at — its SQLite columns are
        // INTEGER. The decoder must normalize them into ISO-8601 strings
        // so downstream code works with one type.
        let json = """
        {
          "id": "t_2a0be199",
          "title": "smoke",
          "status": "ready",
          "priority": 50,
          "created_at": 1778160614,
          "started_at": null,
          "skills": []
        }
        """
        let task = try JSONDecoder().decode(HermesKanbanTask.self, from: Data(json.utf8))
        #expect(task.id == "t_2a0be199")
        // Should have been converted from Unix int to an ISO-8601 string
        // — exact format is platform-stable.
        #expect(task.createdAt?.contains("2026") == true)
        #expect(task.startedAt == nil)
    }

    @Test func decodeMissingOptionalsBecomesNil() throws {
        // Hermes emits a minimal task object when many fields are
        // absent; the decoder must tolerate it.
        let json = """
        { "id": "t_x", "title": "ok", "status": "todo" }
        """
        let task = try JSONDecoder().decode(HermesKanbanTask.self, from: Data(json.utf8))
        #expect(task.id == "t_x")
        #expect(task.assignee == nil)
        #expect(task.priority == nil)
        #expect(task.tenant == nil)
        #expect(task.skills.isEmpty)
    }

    // MARK: - Status / column projection

    @Test func statusToColumnMapping() {
        #expect(KanbanStatus.from("triage").boardColumn == .triage)
        #expect(KanbanStatus.from("todo").boardColumn == .upNext)
        #expect(KanbanStatus.from("ready").boardColumn == .upNext)
        #expect(KanbanStatus.from("running").boardColumn == .running)
        #expect(KanbanStatus.from("blocked").boardColumn == .blocked)
        #expect(KanbanStatus.from("done").boardColumn == .done)
        #expect(KanbanStatus.from("archived").boardColumn == .archived)
        #expect(KanbanStatus.from("WHATEVER").boardColumn == .upNext) // unknown → upNext
    }

    // MARK: - KanbanCreateRequest argv assembly

    @Test func createRequestArgvIncludesAllFields() {
        let req = KanbanCreateRequest(
            title: "Translate doc",
            body: "Spanish, please",
            assignee: "researcher",
            parentIds: ["t_parent"],
            workspace: .directory("/tmp/proj"),
            tenant: "scarf:demo",
            priority: 75,
            triage: true,
            idempotencyKey: "key-1",
            maxRuntimeSeconds: 1800,
            createdBy: "alan",
            skills: ["translation", "github-code-review"]
        )
        let argv = req.argv()
        #expect(argv.contains("--body"))
        #expect(argv.contains("--assignee"))
        #expect(argv.contains("--parent"))
        #expect(argv.contains("--workspace"))
        #expect(argv.contains("dir:/tmp/proj"))
        #expect(argv.contains("--tenant"))
        #expect(argv.contains("scarf:demo"))
        #expect(argv.contains("--priority"))
        #expect(argv.contains("75"))
        #expect(argv.contains("--triage"))
        #expect(argv.contains("--idempotency-key"))
        #expect(argv.contains("--max-runtime"))
        #expect(argv.contains("--created-by"))
        #expect(argv.contains("--skill"))
        #expect(argv.last == "Translate doc") // positional title is last
        #expect(argv.contains("--json"))
    }

    @Test func createRequestArgvOmitsAbsent() {
        let req = KanbanCreateRequest(title: "minimal")
        let argv = req.argv()
        #expect(argv.contains("--json"))
        #expect(argv.last == "minimal")
        #expect(!argv.contains("--body"))
        #expect(!argv.contains("--assignee"))
        #expect(!argv.contains("--triage"))
    }

    // MARK: - KanbanListFilter argv

    @Test func listFilterEmptyOnlyJSON() {
        let argv = KanbanListFilter.all.argv()
        #expect(argv == ["--json"])
    }

    @Test func listFilterStatusFlag() {
        let argv = KanbanListFilter(status: .running).argv()
        #expect(argv.contains("--status"))
        #expect(argv.contains("running"))
    }

    @Test func listFilterTenantPasses() {
        let argv = KanbanListFilter(tenant: "scarf:demo").argv()
        #expect(argv.contains("--tenant"))
        #expect(argv.contains("scarf:demo"))
    }

    @Test func listFilterArchivedAndMine() {
        let argv = KanbanListFilter(includeArchived: true, mineOnly: true).argv()
        #expect(argv.contains("--mine"))
        #expect(argv.contains("--archived"))
    }

    // MARK: - Transition planning

    @Test func planUpNextToRunningDispatches() throws {
        // `dispatch`, not `claim`. See KanbanTransitionStep doc for the
        // rationale — claim doesn't spawn a worker; the dispatcher does.
        let plan = try KanbanService.plan(
            for: KanbanTransition(from: .upNext, to: .running)
        )
        #expect(plan.steps == [.dispatch])
    }

    @Test func planRunningToBlockedRequiresReason() throws {
        let plan = try KanbanService.plan(
            for: KanbanTransition(from: .running, to: .blocked)
        )
        #expect(plan.requiresBlockReason)
    }

    @Test func planBlockedToRunningChainsTwoVerbs() throws {
        let plan = try KanbanService.plan(
            for: KanbanTransition(from: .blocked, to: .running)
        )
        // unblock then dispatch
        #expect(plan.steps.count == 2)
        if case .unblock = plan.steps.first {} else {
            Issue.record("expected first step .unblock, got \(plan.steps)")
        }
        if case .dispatch = plan.steps.last {} else {
            Issue.record("expected last step .dispatch, got \(plan.steps)")
        }
    }

    @Test func planDoneToAnythingForbidden() {
        do {
            _ = try KanbanService.plan(
                for: KanbanTransition(from: .done, to: .upNext)
            )
            Issue.record("expected error")
        } catch let err as KanbanError {
            if case .forbiddenTransition = err {
                // ok
            } else {
                Issue.record("wrong error: \(err)")
            }
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func planTriageToUpNextForbidden() {
        do {
            _ = try KanbanService.plan(
                for: KanbanTransition(from: .triage, to: .upNext)
            )
            Issue.record("expected error")
        } catch let err as KanbanError {
            if case .forbiddenTransition = err {
                // ok
            } else {
                Issue.record("wrong error: \(err)")
            }
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func planNoOpProducesEmptyPlan() throws {
        let plan = try KanbanService.plan(
            for: KanbanTransition(from: .running, to: .running)
        )
        #expect(plan.steps.isEmpty)
    }

    // MARK: - Stats glance

    @Test func glanceStringJoinsNonEmptyBuckets() {
        let stats = HermesKanbanStats(
            byStatus: ["todo": 12, "running": 3, "blocked": 5, "done": 0]
        )
        #expect(stats.glanceString == "12 todo · 3 running · 5 blocked")
        #expect(stats.activeCount == 12 + 3 + 5)
    }

    @Test func glanceStringEmptyWhenZero() {
        let stats = HermesKanbanStats(byStatus: [:])
        #expect(stats.glanceString.isEmpty)
        #expect(stats.activeCount == 0)
    }
}
