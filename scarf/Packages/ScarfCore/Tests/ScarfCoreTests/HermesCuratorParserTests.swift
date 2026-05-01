import Testing
import Foundation
@testable import ScarfCore

@Suite struct HermesCuratorParserTests {

    /// Real `hermes curator status` output captured from a v0.12.0
    /// install with no curator runs yet. Locks in the empty-state
    /// happy path so a Hermes layout tweak surfaces here before
    /// CuratorView starts rendering "—" placeholders silently.
    private static let realFreshOutput = """
    curator: ENABLED
      runs:           0
      last run:       never
      last summary:   (none)
      interval:       every 7d
      stale after:    30d unused
      archive after:  90d unused

    agent-created skills: 18 total
      active     18
      stale      0
      archived   0

    least recently active (top 5):
      Scarf Dashboard Chart Widget Parse Error Fix  activity=  0  use=  0  view=  0  patches=  0  last_activity=never
      Scarf Project Registry Format Fix         activity=  0  use=  0  view=  0  patches=  0  last_activity=never
      clip                                      activity=  0  use=  0  view=  0  patches=  0  last_activity=never
      find-nearby                               activity=  0  use=  0  view=  0  patches=  0  last_activity=never
      gguf-quantization                         activity=  0  use=  0  view=  0  patches=  0  last_activity=never

    least active (top 5):
      Scarf Dashboard Chart Widget Parse Error Fix  activity=  0  use=  0  view=  0  patches=  0  last_activity=never
      Scarf Project Registry Format Fix         activity=  0  use=  0  view=  0  patches=  0  last_activity=never
      clip                                      activity=  0  use=  0  view=  0  patches=  0  last_activity=never
      find-nearby                               activity=  0  use=  0  view=  0  patches=  0  last_activity=never
      gguf-quantization                         activity=  0  use=  0  view=  0  patches=  0  last_activity=never
    """

    @Test func parseRealFreshOutput() {
        let s = HermesCuratorStatusParser.parse(text: Self.realFreshOutput)
        #expect(s.state == .enabled)
        #expect(s.runCount == 0)
        #expect(s.lastRunISO == nil)
        #expect(s.lastSummary == nil)
        #expect(s.intervalLabel == "every 7d")
        #expect(s.staleAfterLabel == "30d unused")
        #expect(s.archiveAfterLabel == "90d unused")
        #expect(s.totalSkills == 18)
        #expect(s.activeSkills == 18)
        #expect(s.staleSkills == 0)
        #expect(s.archivedSkills == 0)
        #expect(s.pinnedNames.isEmpty)
        #expect(s.leastRecentlyActive.count == 5)
        #expect(s.leastActive.count == 5)
        #expect(s.mostActive.isEmpty)
        let firstRow = s.leastRecentlyActive.first
        #expect(firstRow?.name == "Scarf Dashboard Chart Widget Parse Error Fix")
        #expect(firstRow?.activityCount == 0)
        #expect(firstRow?.lastActivityLabel == "never")
    }

    @Test func parsedPausedState() {
        let text = """
        curator: PAUSED
          runs:           5
          last run:       2026-04-29T03:10:00Z
          last summary:   pruned 2 skills, consolidated 1
          interval:       every 7d
          stale after:    30d unused
          archive after:  90d unused

        agent-created skills: 12 total
          active     8
          stale      3
          archived   1

        pinned (2): kanban-orchestrator, scarf-template-author
        """
        let s = HermesCuratorStatusParser.parse(text: text)
        #expect(s.state == .paused)
        #expect(s.runCount == 5)
        #expect(s.lastRunISO == "2026-04-29T03:10:00Z")
        #expect(s.lastSummary == "pruned 2 skills, consolidated 1")
        #expect(s.totalSkills == 12)
        #expect(s.activeSkills == 8)
        #expect(s.staleSkills == 3)
        #expect(s.archivedSkills == 1)
        #expect(s.pinnedNames == ["kanban-orchestrator", "scarf-template-author"])
    }

    @Test func stateFileOverridesTextSummary() {
        // The state file is authoritative for last_run_at /
        // last_run_summary / last_report_path because it carries full
        // ISO timestamps the text output may have rounded. Verify that
        // a state file with richer values overrides parsed text.
        let text = """
        curator: ENABLED
          runs:           1
          last run:       2026-04-30T11:00:00Z
          last summary:   short
          interval:       every 7d
          stale after:    30d unused
          archive after:  90d unused

        agent-created skills: 3 total
          active     3
          stale      0
          archived   0
        """
        let stateJSON: [String: Any] = [
            "run_count": 4,
            "last_run_at": "2026-04-30T18:42:13.001Z",
            "last_run_summary": "richer summary from state file",
            "last_report_path": "/Users/u/.hermes/logs/curator/20260430-184213"
        ]
        let data = try! JSONSerialization.data(withJSONObject: stateJSON)
        let s = HermesCuratorStatusParser.parse(text: text, stateFileJSON: data)
        #expect(s.runCount == 4)
        #expect(s.lastRunISO == "2026-04-30T18:42:13.001Z")
        #expect(s.lastSummary == "richer summary from state file")
        #expect(s.lastReportPath == "/Users/u/.hermes/logs/curator/20260430-184213")
    }

    @Test func parsedDisabledStatus() {
        let s = HermesCuratorStatusParser.parse(text: "curator: DISABLED\n  runs:           0\n")
        #expect(s.state == .disabled)
    }

    @Test func parsedEmptyOutputStaysSafe() {
        let s = HermesCuratorStatusParser.parse(text: "")
        #expect(s.state == .unknown)
        #expect(s.totalSkills == 0)
        #expect(s.leastRecentlyActive.isEmpty)
    }

    @Test func skillRowParserHandlesMultiWordNames() {
        // Names with spaces are common (Scarf Dashboard Chart Widget…)
        // The parser slices at the first `activity=` so names can be
        // arbitrary length without breaking the counter columns.
        let row = "  Some Long Skill Name v2  activity= 12  use= 4  view= 6  patches= 2  last_activity=2026-04-25"
        let s = HermesCuratorStatusParser.parse(text: """
        least recently active (top 5):
        \(row)
        """)
        let parsed = s.leastRecentlyActive.first
        #expect(parsed?.name == "Some Long Skill Name v2")
        #expect(parsed?.activityCount == 12)
        #expect(parsed?.useCount == 4)
        #expect(parsed?.viewCount == 6)
        #expect(parsed?.patchCount == 2)
        #expect(parsed?.lastActivityLabel == "2026-04-25")
    }
}
