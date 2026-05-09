import Testing
import Foundation
@testable import ScarfCore

/// Pure mapping tests for `GatewayAllowlistKind`. Locks down the (platform →
/// kind) table so a refactor doesn't accidentally drop a platform.
@Suite struct GatewayAllowlistKindTests {

    @Test func mapsKnownPlatformsToCorrectKind() {
        #expect(GatewayAllowlistKind.kind(for: "slack")      == .channels)
        #expect(GatewayAllowlistKind.kind(for: "mattermost") == .channels)
        #expect(GatewayAllowlistKind.kind(for: "google-chat") == .channels)
        #expect(GatewayAllowlistKind.kind(for: "telegram")   == .chats)
        #expect(GatewayAllowlistKind.kind(for: "whatsapp")   == .chats)
        #expect(GatewayAllowlistKind.kind(for: "matrix")     == .rooms)
        #expect(GatewayAllowlistKind.kind(for: "dingtalk")   == .rooms)
    }

    @Test func acceptsBothGoogleChatSpellings() {
        // // TODO(WS-5-Q1) — both spellings round-trip until Hermes confirms
        // the wire identifier.
        #expect(GatewayAllowlistKind.kind(for: "google-chat") == .channels)
        #expect(GatewayAllowlistKind.kind(for: "googlechat")  == .channels)
    }

    @Test func returnsNilForPlatformsWithoutAllowlist() {
        #expect(GatewayAllowlistKind.kind(for: "cli")            == nil)
        #expect(GatewayAllowlistKind.kind(for: "yuanbao")        == nil)
        #expect(GatewayAllowlistKind.kind(for: "microsoft-teams") == nil)
        #expect(GatewayAllowlistKind.kind(for: "discord")        == nil)
        #expect(GatewayAllowlistKind.kind(for: "signal")         == nil)
        #expect(GatewayAllowlistKind.kind(for: "homeassistant")  == nil)
        #expect(GatewayAllowlistKind.kind(for: "")               == nil)
        #expect(GatewayAllowlistKind.kind(for: "unknown")        == nil)
    }

    @Test func yamlKeyMatchesHermesContract() {
        #expect(GatewayAllowlistKind.channels.yamlKey == "allowed_channels")
        #expect(GatewayAllowlistKind.chats.yamlKey    == "allowed_chats")
        #expect(GatewayAllowlistKind.rooms.yamlKey    == "allowed_rooms")
    }

    @Test func nounsAreUserFacingSafe() {
        #expect(GatewayAllowlistKind.channels.noun == "channel")
        #expect(GatewayAllowlistKind.chats.noun    == "chat")
        #expect(GatewayAllowlistKind.rooms.noun    == "room")
        #expect(GatewayAllowlistKind.channels.pluralNoun == "channels")
        #expect(GatewayAllowlistKind.chats.pluralNoun    == "chats")
        #expect(GatewayAllowlistKind.rooms.pluralNoun    == "rooms")
    }

    @Test func placeholdersAreNonEmpty() {
        // Smoke test — placeholder strings are advisory; we just don't want
        // them silently emptied during a refactor.
        #expect(!GatewayAllowlistKind.channels.inputPlaceholder.isEmpty)
        #expect(!GatewayAllowlistKind.chats.inputPlaceholder.isEmpty)
        #expect(!GatewayAllowlistKind.rooms.inputPlaceholder.isEmpty)
    }

    @Test func gatewayPlatformSettingsItemsForKind() {
        let s = GatewayPlatformSettings(
            allowedChannels: ["C01"],
            allowedChats: ["@user"],
            allowedRooms: ["!room:matrix.org"]
        )
        #expect(s.items(for: .channels) == ["C01"])
        #expect(s.items(for: .chats)    == ["@user"])
        #expect(s.items(for: .rooms)    == ["!room:matrix.org"])
    }
}
