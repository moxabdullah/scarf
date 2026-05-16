import Testing
import Foundation
@testable import ScarfCore

/// Tests for `ModelPreset` Codable round-trip and `ModelPresetService`
/// CRUD semantics.
///
/// Pure-data tests are pure JSON round-trips — no disk. The actor's
/// disk-integration paths are exercised by a single test that writes
/// under a per-test scratch home so we don't clobber the developer's
/// real `~/.hermes/scarf/model_presets.json`.
@Suite struct ModelPresetCodableTests {

    @Test func roundTripPreservesAllFields() throws {
        let preset = ModelPreset(
            id: UUID(uuidString: "12345678-1234-1234-1234-123456789abc")!,
            name: "Sonnet 4.6",
            modelID: "claude-sonnet-4.6",
            providerID: "anthropic",
            notes: "Daily driver",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_100)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(preset)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ModelPreset.self, from: data)
        #expect(decoded.id == preset.id)
        #expect(decoded.name == preset.name)
        #expect(decoded.modelID == preset.modelID)
        #expect(decoded.providerID == preset.providerID)
        #expect(decoded.notes == preset.notes)
        #expect(decoded.createdAt == preset.createdAt)
        #expect(decoded.updatedAt == preset.updatedAt)
    }

    @Test func nilNotesRoundTrips() throws {
        let preset = ModelPreset(name: "Haiku", modelID: "claude-haiku-4-5", providerID: "anthropic")
        #expect(preset.notes == nil)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(preset)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ModelPreset.self, from: data)
        #expect(decoded.notes == nil)
    }

    @Test func storeDefaultsToCurrentVersion() {
        let store = ModelPresetStore()
        #expect(store.version == ModelPresetStore.currentVersion)
        #expect(store.presets.isEmpty)
    }

    @Test func storeIsCodable() throws {
        let store = ModelPresetStore(
            version: 1,
            presets: [
                ModelPreset(name: "A", modelID: "a", providerID: "p1"),
                ModelPreset(name: "B", modelID: "b", providerID: "p2"),
            ],
            updatedAt: "2026-05-15T12:00:00Z"
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(store)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ModelPresetStore.self, from: data)
        #expect(decoded.version == 1)
        #expect(decoded.presets.count == 2)
        #expect(decoded.updatedAt == "2026-05-15T12:00:00Z")
    }
}

/// Disk-integration tests for `ModelPresetService`. Each test stages a
/// fresh `~/.hermes/scarf/model_presets.json` under a tmpdir-backed
/// `ServerContext` and tears down after. We use `.local` with the real
/// `HermesPathSet`-derived path under a tmp HOME via a small helper
/// that backs up + restores the user's actual file.
///
/// **Why not subclass ServerContext.** `ServerContext.paths` derives
/// from `HermesPathSet.defaultLocalHome` which is computed from
/// `NSHomeDirectory()` and is not test-injectable. Rather than reshape
/// the production API for testability, we serialize through one suite
/// and back up + restore the user's real file. This is the same
/// compromise `M5FeatureVMTests` makes for `ServerContext.sshTransportFactory`.
@Suite(.serialized) struct ModelPresetServiceDiskTests {

    /// Back up the user's real file if it exists, run the body, restore
    /// the backup. Always restores even on test failure.
    static func sandboxed(_ body: () async throws -> Void) async throws {
        let path = ServerContext.local.paths.modelPresetsJSON
        let backupURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("model_presets_backup_\(UUID().uuidString).json")
        let hadOriginal = FileManager.default.fileExists(atPath: path)
        if hadOriginal {
            try FileManager.default.copyItem(atPath: path, toPath: backupURL.path)
        }
        defer {
            try? FileManager.default.removeItem(atPath: path)
            if hadOriginal {
                try? FileManager.default.copyItem(atPath: backupURL.path, toPath: path)
                try? FileManager.default.removeItem(at: backupURL)
            }
        }
        try await body()
    }

    @Test func listReturnsEmptyWhenFileMissing() async throws {
        try await Self.sandboxed {
            // Make sure the file is absent.
            let path = ServerContext.local.paths.modelPresetsJSON
            try? FileManager.default.removeItem(atPath: path)
            let svc = ModelPresetService(context: .local)
            let presets = try await svc.list()
            #expect(presets.isEmpty)
        }
    }

    @Test func upsertThenListRoundTrips() async throws {
        try await Self.sandboxed {
            let path = ServerContext.local.paths.modelPresetsJSON
            try? FileManager.default.removeItem(atPath: path)
            let svc = ModelPresetService(context: .local)
            let preset = ModelPreset(name: "Sonnet", modelID: "claude-sonnet-4.6", providerID: "anthropic")
            try await svc.upsert(preset)
            let presets = try await svc.list()
            #expect(presets.count == 1)
            #expect(presets[0].id == preset.id)
            #expect(presets[0].name == "Sonnet")
            #expect(presets[0].modelID == "claude-sonnet-4.6")
        }
    }

    @Test func upsertExistingIdUpdatesInPlace() async throws {
        try await Self.sandboxed {
            let path = ServerContext.local.paths.modelPresetsJSON
            try? FileManager.default.removeItem(atPath: path)
            let svc = ModelPresetService(context: .local)
            let id = UUID()
            try await svc.upsert(
                ModelPreset(id: id, name: "Sonnet", modelID: "claude-sonnet-4.6", providerID: "anthropic")
            )
            // Same id, different fields.
            try await svc.upsert(
                ModelPreset(id: id, name: "Sonnet (renamed)", modelID: "claude-sonnet-4.6", providerID: "anthropic", notes: "now with notes")
            )
            let presets = try await svc.list()
            #expect(presets.count == 1)
            #expect(presets[0].name == "Sonnet (renamed)")
            #expect(presets[0].notes == "now with notes")
        }
    }

    @Test func deleteRemovesPreset() async throws {
        try await Self.sandboxed {
            let path = ServerContext.local.paths.modelPresetsJSON
            try? FileManager.default.removeItem(atPath: path)
            let svc = ModelPresetService(context: .local)
            let id = UUID()
            try await svc.upsert(
                ModelPreset(id: id, name: "Sonnet", modelID: "claude-sonnet-4.6", providerID: "anthropic")
            )
            try await svc.delete(id: id)
            let presets = try await svc.list()
            #expect(presets.isEmpty)
        }
    }

    @Test func deleteMissingIdIsNoOp() async throws {
        try await Self.sandboxed {
            let path = ServerContext.local.paths.modelPresetsJSON
            try? FileManager.default.removeItem(atPath: path)
            let svc = ModelPresetService(context: .local)
            try await svc.delete(id: UUID())  // Should not throw.
            let presets = try await svc.list()
            #expect(presets.isEmpty)
        }
    }

    @Test func getById() async throws {
        try await Self.sandboxed {
            let path = ServerContext.local.paths.modelPresetsJSON
            try? FileManager.default.removeItem(atPath: path)
            let svc = ModelPresetService(context: .local)
            let id = UUID()
            try await svc.upsert(
                ModelPreset(id: id, name: "Sonnet", modelID: "claude-sonnet-4.6", providerID: "anthropic")
            )
            let found = try await svc.get(id: id)
            #expect(found != nil)
            #expect(found?.name == "Sonnet")
            let missing = try await svc.get(id: UUID())
            #expect(missing == nil)
        }
    }

    @Test func listSortsByNameCaseInsensitive() async throws {
        try await Self.sandboxed {
            let path = ServerContext.local.paths.modelPresetsJSON
            try? FileManager.default.removeItem(atPath: path)
            let svc = ModelPresetService(context: .local)
            try await svc.upsert(ModelPreset(name: "zeta", modelID: "z", providerID: "p"))
            try await svc.upsert(ModelPreset(name: "Alpha", modelID: "a", providerID: "p"))
            try await svc.upsert(ModelPreset(name: "beta", modelID: "b", providerID: "p"))
            let presets = try await svc.list()
            #expect(presets.map(\.name) == ["Alpha", "beta", "zeta"])
        }
    }

    @Test func corruptStoreThrows() async throws {
        try await Self.sandboxed {
            let path = ServerContext.local.paths.modelPresetsJSON
            let dir = (path as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try "not json".write(toFile: path, atomically: true, encoding: .utf8)
            let svc = ModelPresetService(context: .local)
            await #expect(throws: ModelPresetServiceError.self) {
                _ = try await svc.list()
            }
        }
    }
}
