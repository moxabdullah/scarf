import Testing
import Foundation
@testable import ScarfCore

/// Pure parser tests for `HermesCapabilities`. The detection store
/// (`HermesCapabilitiesStore`) is exercised separately under integration
/// tests since it spawns `hermes --version`.
@Suite struct HermesCapabilitiesTests {

    // MARK: - Version line parsing

    @Test func parseV013ReleaseLine() {
        let caps = HermesCapabilities.parseLine("Hermes Agent v0.13.0 (2026.5.7)")
        #expect(caps.semver == HermesCapabilities.SemVer(major: 0, minor: 13, patch: 0))
        #expect(caps.dateVersion == HermesCapabilities.DateVersion(year: 2026, month: 5, day: 7))
        #expect(caps.detected)
    }

    @Test func parseV012ReleaseLine() {
        let caps = HermesCapabilities.parseLine("Hermes Agent v0.12.0 (2026.4.30)")
        #expect(caps.semver == HermesCapabilities.SemVer(major: 0, minor: 12, patch: 0))
        #expect(caps.dateVersion == HermesCapabilities.DateVersion(year: 2026, month: 4, day: 30))
        #expect(caps.detected)
    }

    @Test func parseV011ReleaseLine() {
        let caps = HermesCapabilities.parseLine("Hermes Agent v0.11.0 (2026.4.23)")
        #expect(caps.semver == HermesCapabilities.SemVer(major: 0, minor: 11, patch: 0))
        #expect(caps.dateVersion == HermesCapabilities.DateVersion(year: 2026, month: 4, day: 23))
    }

    @Test func parseSemverWithoutDate() {
        // Some older Hermes builds emit only the semver suffix.
        let caps = HermesCapabilities.parseLine("Hermes Agent v0.10.5")
        #expect(caps.semver == HermesCapabilities.SemVer(major: 0, minor: 10, patch: 5))
        #expect(caps.dateVersion == nil)
    }

    @Test func parseFullStdoutBlock() {
        // Real `hermes --version` output is multi-line; the version sits on
        // the first line and the rest is metadata.
        let stdout = """
        Hermes Agent v0.12.0 (2026.4.30)
        Project: /Users/alan/.hermes/hermes-agent
        Python: 3.11.15
        OpenAI SDK: 2.31.0
        Up to date
        """
        let caps = HermesCapabilities.parse(stdout)
        #expect(caps.semver?.minor == 12)
        #expect(caps.dateVersion?.year == 2026)
    }

    @Test func parseRejectsUnrelatedOutput() {
        let caps = HermesCapabilities.parse("hermes: command not found")
        #expect(caps.semver == nil)
        #expect(!caps.detected)
    }

    @Test func parseHandlesEmptyString() {
        let caps = HermesCapabilities.parse("")
        #expect(caps == .empty)
    }

    @Test func parseHandlesPartialSemver() {
        // "v0.11" without the patch component shouldn't accidentally match.
        let caps = HermesCapabilities.parseLine("Hermes Agent v0.11")
        #expect(caps.semver == nil)
    }

    // MARK: - SemVer ordering

    @Test func semverOrdering() {
        let v0_11_0 = HermesCapabilities.SemVer(major: 0, minor: 11, patch: 0)
        let v0_12_0 = HermesCapabilities.SemVer(major: 0, minor: 12, patch: 0)
        let v0_12_5 = HermesCapabilities.SemVer(major: 0, minor: 12, patch: 5)
        let v1_0_0 = HermesCapabilities.SemVer(major: 1, minor: 0, patch: 0)
        #expect(v0_11_0 < v0_12_0)
        #expect(v0_12_0 < v0_12_5)
        #expect(v0_12_5 < v1_0_0)
    }

    // MARK: - Capability flags

    @Test func v013FlagsAllOn() {
        let caps = HermesCapabilities.parseLine("Hermes Agent v0.13.0 (2026.5.7)")
        // v0.12 surfaces remain on.
        #expect(caps.hasCurator)
        #expect(caps.hasKanban)
        #expect(caps.hasACPImagePrompts)
        #expect(!caps.hasFlushMemoriesAux)
        // v0.13 surfaces light up.
        #expect(caps.hasGoals)
        #expect(caps.hasACPQueue)
        #expect(caps.hasACPSteerOnIdle)
        #expect(caps.hasKanbanDiagnostics)
        #expect(caps.hasCuratorArchive)
        #expect(caps.hasGoogleChatPlatform)
        #expect(caps.hasGatewayAllowlists)
        #expect(caps.hasGatewayBusyAckToggle)
        #expect(caps.hasGatewayRestartNotification)
        #expect(caps.hasGatewayList)
        #expect(caps.hasMCPSSETransport)
        #expect(caps.hasCronNoAgent)
        #expect(caps.hasWebToolsBackendSplit)
        #expect(caps.hasProfileNoSkills)
        #expect(caps.hasContextCompressionCount)
        #expect(caps.hasNewWithSessionName)
        #expect(caps.hasUpdateNonInteractive)
        #expect(caps.hasOpenRouterResponseCache)
        #expect(caps.hasImageGenModel)
        #expect(caps.hasDisplayLanguage)
        #expect(caps.hasXAIVoiceCloning)
        #expect(caps.hasVideoAnalyze)
        #expect(caps.hasTransformLLMOutputHook)
        #expect(caps.hasACPSetSessionModel)
    }

    @Test func v012FlagsAllOn() {
        let caps = HermesCapabilities.parseLine("Hermes Agent v0.12.0 (2026.4.30)")
        // v0.12 surfaces on.
        #expect(caps.hasCurator)
        #expect(caps.hasFallbackCommand)
        #expect(caps.hasKanban)
        #expect(caps.hasOneShot)
        #expect(caps.hasSkillURLInstall)
        #expect(caps.hasACPImagePrompts)
        #expect(caps.hasUpdateCheck)
        #expect(caps.hasPiperTTS)
        #expect(caps.hasVercelTerminal)
        #expect(caps.hasCuratorAux)
        #expect(caps.hasTeamsPlatform)
        #expect(caps.hasYuanbaoPlatform)
        #expect(caps.hasCronWorkdir)
        #expect(caps.hasPromptCacheTTL)
        #expect(caps.hasRedactionToggle)
        // flush_memories was REMOVED in v0.12 — flag inverts.
        #expect(!caps.hasFlushMemoriesAux)
        // v0.13 surfaces stay off on a v0.12 host.
        #expect(!caps.hasGoals)
        #expect(!caps.hasACPQueue)
        #expect(!caps.hasKanbanDiagnostics)
        #expect(!caps.hasCuratorArchive)
        #expect(!caps.hasGoogleChatPlatform)
        #expect(!caps.hasGatewayAllowlists)
        #expect(!caps.hasMCPSSETransport)
        #expect(!caps.hasCronNoAgent)
        #expect(!caps.hasWebToolsBackendSplit)
        #expect(!caps.hasProfileNoSkills)
        #expect(!caps.hasContextCompressionCount)
        #expect(!caps.hasOpenRouterResponseCache)
        #expect(!caps.hasImageGenModel)
        #expect(!caps.hasDisplayLanguage)
        #expect(!caps.hasXAIVoiceCloning)
        #expect(!caps.hasACPSetSessionModel)
    }

    @Test func v011FlagsAllOff() {
        let caps = HermesCapabilities.parseLine("Hermes Agent v0.11.0 (2026.4.23)")
        #expect(!caps.hasCurator)
        #expect(!caps.hasFallbackCommand)
        #expect(!caps.hasKanban)
        #expect(!caps.hasOneShot)
        #expect(!caps.hasSkillURLInstall)
        #expect(!caps.hasACPImagePrompts)
        #expect(!caps.hasUpdateCheck)
        #expect(!caps.hasPiperTTS)
        #expect(!caps.hasVercelTerminal)
        #expect(!caps.hasCuratorAux)
        #expect(!caps.hasTeamsPlatform)
        #expect(!caps.hasYuanbaoPlatform)
        #expect(!caps.hasCronWorkdir)
        #expect(!caps.hasPromptCacheTTL)
        #expect(!caps.hasRedactionToggle)
        // flush_memories aux row was still alive on v0.11.
        #expect(caps.hasFlushMemoriesAux)
    }

    @Test func emptyCapabilitiesAllOff() {
        // Undetected installs should hide every gated UI surface.
        let caps = HermesCapabilities.empty
        #expect(!caps.hasCurator)
        #expect(!caps.hasFlushMemoriesAux)   // unknown → hide either way
        #expect(!caps.detected)
    }

    @Test func futureVersionRetainsCapabilities() {
        // A v0.14 (hypothetical) should still see all v0.12 + v0.13 capabilities on.
        let caps = HermesCapabilities.parseLine("Hermes Agent v0.14.0 (2026.7.1)")
        #expect(caps.hasCurator)
        #expect(caps.hasACPImagePrompts)
        #expect(caps.hasGoals)
        #expect(caps.hasKanbanDiagnostics)
        #expect(caps.hasCuratorArchive)
        // And flush_memories stays gone.
        #expect(!caps.hasFlushMemoriesAux)
    }

    @Test func v0_13_patchReleaseStillEnablesAllFlags() {
        // A v0.13.4 patch release should still enable every v0.13 flag.
        let caps = HermesCapabilities.parseLine("Hermes Agent v0.13.4 (2026.5.20)")
        #expect(caps.hasGoals)
        #expect(caps.hasACPQueue)
        #expect(caps.hasKanbanDiagnostics)
        #expect(caps.hasGoogleChatPlatform)
    }

    // MARK: - isV013OrLater convenience predicate

    @Test func isV013OrLater_v013HostTrue() {
        let caps = HermesCapabilities.parseLine("Hermes Agent v0.13.0 (2026.5.7)")
        #expect(caps.isV013OrLater)
    }

    @Test func isV013OrLater_v012HostFalse() {
        let caps = HermesCapabilities.parseLine("Hermes Agent v0.12.0 (2026.4.30)")
        #expect(!caps.isV013OrLater)
    }

    @Test func isV013OrLater_emptyFalse() {
        let caps = HermesCapabilities.empty
        #expect(!caps.isV013OrLater)
    }

    @Test func isV013OrLater_v014HostTrue() {
        let caps = HermesCapabilities.parseLine("Hermes Agent v0.14.0 (2026.7.1)")
        #expect(caps.isV013OrLater)
    }
}
