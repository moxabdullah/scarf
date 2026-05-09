import Testing
import Foundation
@testable import ScarfCore

/// Parser tests for `hermes gateway list --json`. Pure — no transport, no
/// process calls.
@Suite struct HermesGatewayListServiceTests {

    private func data(_ s: String) -> Data { s.data(using: .utf8)! }

    @Test func parsesSingleProfileSinglePlatform() {
        let json = data(#"""
        {"profiles":[{"name":"default","running":true,"pid":1234,
        "platforms":["slack","telegram"]}]}
        """#)
        let snap = HermesGatewayListService.parse(json)
        #expect(snap?.profiles.count == 1)
        #expect(snap?.profiles[0].profile == "default")
        #expect(snap?.profiles[0].pid == 1234)
        #expect(snap?.profiles[0].isRunning == true)
        #expect(snap?.profiles[0].platforms == ["slack", "telegram"])
    }

    @Test func parsesMultipleProfiles() {
        let json = data(#"""
        {"profiles":[
            {"name":"work","running":true,"pid":2001,"platforms":["slack"]},
            {"name":"personal","running":false,"platforms":["telegram"]}
        ]}
        """#)
        let snap = HermesGatewayListService.parse(json)
        #expect(snap?.profiles.count == 2)
        #expect(snap?.profiles[0].profile == "work")
        #expect(snap?.profiles[0].isRunning == true)
        #expect(snap?.profiles[1].profile == "personal")
        #expect(snap?.profiles[1].isRunning == false)
        #expect(snap?.profiles[1].pid == nil)
    }

    @Test func parsesBareArrayShape() {
        // Tolerance for a top-level array (no `profiles` wrapper).
        let json = data(#"""
        [{"name":"default","running":true,"pid":42,"platforms":["discord"]}]
        """#)
        let snap = HermesGatewayListService.parse(json)
        #expect(snap?.profiles.count == 1)
        #expect(snap?.profiles[0].profile == "default")
    }

    @Test func toleratesAlternateFieldNames() {
        // `profile` instead of `name`, `state` instead of `running`,
        // `connected_platforms` instead of `platforms` — defensive defaults
        // keep the parser happy if Hermes ships any of these.
        let json = data(#"""
        {"profiles":[{"profile":"alt","state":"running","pid":7,
        "connected_platforms":["matrix"]}]}
        """#)
        let snap = HermesGatewayListService.parse(json)
        #expect(snap?.profiles[0].profile == "alt")
        #expect(snap?.profiles[0].isRunning == true)
        #expect(snap?.profiles[0].platforms == ["matrix"])
    }

    @Test func returnsNilOnEmptyData() {
        #expect(HermesGatewayListService.parse(Data()) == nil)
    }

    @Test func returnsNilOnUnparseableJSON() {
        let json = data("not-json")
        #expect(HermesGatewayListService.parse(json) == nil)
    }

    @Test func returnsEmptySnapshotOnEmptyProfilesArray() {
        let json = data(#"{"profiles":[]}"#)
        let snap = HermesGatewayListService.parse(json)
        #expect(snap?.profiles.isEmpty == true)
    }

    @Test func toleratesUnknownKeys() {
        // Forward-compat: a future v0.13.x Hermes adds extra fields, parser
        // still works.
        let json = data(#"""
        {"profiles":[{"name":"default","running":true,"platforms":["slack"],
        "future_field":"value","another":42}]}
        """#)
        let snap = HermesGatewayListService.parse(json)
        #expect(snap?.profiles[0].profile == "default")
    }

    // MARK: - headerDigest

    @Test func headerDigestEmptyProfiles() {
        let snap = GatewayListSnapshot(profiles: [])
        #expect(snap.headerDigest == "no profiles configured")
    }

    @Test func headerDigestSingleProfileRunning() {
        let snap = GatewayListSnapshot(profiles: [
            .init(profile: "default", isRunning: true, pid: 100,
                  platforms: ["slack", "telegram"])
        ])
        #expect(snap.headerDigest == "default profile · running · slack, telegram")
    }

    @Test func headerDigestSingleProfileStopped() {
        let snap = GatewayListSnapshot(profiles: [
            .init(profile: "default", isRunning: false, pid: nil, platforms: [])
        ])
        #expect(snap.headerDigest == "default profile · stopped")
    }

    @Test func headerDigestMultipleProfilesSomeRunning() {
        let snap = GatewayListSnapshot(profiles: [
            .init(profile: "work", isRunning: true, pid: 1, platforms: ["slack"]),
            .init(profile: "home", isRunning: false, pid: nil, platforms: ["matrix"]),
            .init(profile: "extra", isRunning: true, pid: 2, platforms: [])
        ])
        // 3 profiles total, 2 running, surface first running profile's
        // platform list as the highlight.
        #expect(snap.headerDigest == "3 profiles (2 running) · work: slack")
    }

    @Test func headerDigestMultipleProfilesNoneRunning() {
        let snap = GatewayListSnapshot(profiles: [
            .init(profile: "a", isRunning: false, pid: nil, platforms: ["slack"]),
            .init(profile: "b", isRunning: false, pid: nil, platforms: ["matrix"])
        ])
        // No running profile — fall back to the first profile's platforms.
        #expect(snap.headerDigest == "2 profiles (0 running) · a: slack")
    }
}
