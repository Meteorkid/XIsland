import XCTest
@testable import XIsland

@MainActor
final class MascotTaskIdentityTests: XCTestCase {
    func testIdentitySurvivesStatusChangesReorderingAndRegistryRebuild() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let registry = MascotTaskIdentityRegistry(defaults: defaults)
        let first = AgentSession(id: "chat-a", agentType: .codex, workingDirectory: "/work/a")
        let second = AgentSession(id: "chat-b", agentType: .codex)
        let original = registry.identity(for: first)
        _ = registry.identity(for: second)

        first.status = .waitingAnswer
        first.workingDirectory = "/work/renamed"
        first.windowNumber = 73
        _ = registry.identity(for: second)
        let reordered = registry.identity(for: first)
        XCTAssertEqual(reordered.ordinal, original.ordinal)
        XCTAssertEqual(reordered.paletteIndex, original.paletteIndex)

        let rebuilt = MascotTaskIdentityRegistry(defaults: defaults).identity(for: first)
        XCTAssertEqual(rebuilt.ordinal, original.ordinal)
        XCTAssertEqual(rebuilt.paletteIndex, original.paletteIndex)
        XCTAssertEqual(rebuilt.shortLabel, "1")
    }

    func testFirstTwelveTasksHaveDifferentColorsAndThirteenthKeepsUniqueNumber() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let registry = MascotTaskIdentityRegistry(defaults: defaults)
        let identities = (1...13).map { index in
            registry.identity(for: AgentSession(id: "chat-\(index)", agentType: .codex))
        }
        XCTAssertEqual(MascotTaskIdentity.palette.count, 12)
        XCTAssertEqual(Set(identities.prefix(12).map(\.paletteIndex)).count, 12)
        XCTAssertEqual(Set(identities.prefix(12).map { $0.paletteToken.hexRGB }).count, 12)
        XCTAssertEqual(identities.map(\.ordinal), Array(1...13))
        XCTAssertEqual(identities[12].paletteIndex, identities[0].paletteIndex)
        XCTAssertEqual(identities[12].shortLabel, "13")
    }

    func testClientsHaveIndependentOrdinalSequences() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let registry = MascotTaskIdentityRegistry(defaults: defaults)
        let codex = registry.identity(for: AgentSession(id: "same-id", agentType: .codex))
        let claude = registry.identity(for: AgentSession(id: "same-id", agentType: .claudeCode))
        let nextCodex = registry.identity(for: AgentSession(id: "second-id", agentType: .codex))
        XCTAssertEqual(codex.ordinal, 1)
        XCTAssertEqual(claude.ordinal, 1)
        XCTAssertEqual(nextCodex.ordinal, 2)
    }

    func testRequestingAgentKeepsItsOwnNumberingNamespace() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let registry = MascotTaskIdentityRegistry(defaults: defaults)
        let native = AgentSession(id: "claude-native", agentType: .claudeCode)
        let embedded = AgentSession(id: "cursor-hosted-claude", agentType: .cursor)
        XCTAssertEqual(registry.identity(for: native).ordinal, 1)
        XCTAssertEqual(registry.identity(for: embedded).ordinal, 1)
        let request = registry.identity(for: embedded, agentType: .claudeCode)
        XCTAssertEqual(request.ordinal, 2, "同一个客户端系列中，不同任务不能显示相同编号")
        XCTAssertEqual(MascotTaskIdentityRegistry(defaults: defaults)
            .identity(for: embedded, agentType: .claudeCode).ordinal, request.ordinal)
    }

    func testRooReloadPreservesNativeTaskIdentityAcrossObservationInstances() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let registry = MascotTaskIdentityRegistry(defaults: defaults)
        let first = AgentSession(id: "roo-old-observation", agentType: .rooCode)
        first.sourceNamespace = "roo-vscode"
        first.nativeTaskId = "task-42"
        first.sourceInstanceId = "extension-before-reload"
        let original = registry.identity(for: first)

        let reloaded = AgentSession(id: "roo-new-observation", agentType: .rooCode)
        reloaded.sourceNamespace = first.sourceNamespace
        reloaded.nativeTaskId = first.nativeTaskId
        reloaded.sourceInstanceId = "extension-after-reload"
        let restored = MascotTaskIdentityRegistry(defaults: defaults).identity(for: reloaded)
        XCTAssertEqual(restored.ordinal, original.ordinal)
        XCTAssertEqual(restored.paletteIndex, original.paletteIndex)
    }

    func testMissingNativeNamespaceFallsBackToSessionID() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let registry = MascotTaskIdentityRegistry(defaults: defaults)
        let first = AgentSession(id: "chat-a", agentType: .rooCode)
        let second = AgentSession(id: "chat-b", agentType: .rooCode)
        first.nativeTaskId = "shared-incomplete-id"
        second.nativeTaskId = first.nativeTaskId
        XCTAssertEqual(registry.identity(for: first).ordinal, 1)
        XCTAssertEqual(registry.identity(for: second).ordinal, 2)
    }

    func testMalformedCacheRecoversAndRetainsValidCounters() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("invalid-cache", forKey: MascotTaskIdentityRegistry.cacheDefaultsKey)
        defaults.set(["codex": 12, "claude_code": -4, "cursor": Int.max],
                     forKey: MascotTaskIdentityRegistry.counterDefaultsKey)
        let registry = MascotTaskIdentityRegistry(defaults: defaults)
        XCTAssertEqual(registry.identity(for: AgentSession(id: "chat", agentType: .codex)).ordinal, 12)
        XCTAssertEqual(registry.identity(for: AgentSession(id: "chat", agentType: .claudeCode)).ordinal, 1)
        XCTAssertEqual(registry.identity(for: AgentSession(id: "chat", agentType: .cursor)).ordinal, 1)
        XCTAssertEqual(try records(in: defaults).count, 3)
    }

    func testValidMappingsRecoverCorruptCounters() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let registry = MascotTaskIdentityRegistry(defaults: defaults)
        _ = registry.identity(for: AgentSession(id: "a", agentType: .codex))
        _ = registry.identity(for: AgentSession(id: "b", agentType: .codex))
        defaults.set(["codex": -1], forKey: MascotTaskIdentityRegistry.counterDefaultsKey)
        let rebuilt = MascotTaskIdentityRegistry(defaults: defaults)
        XCTAssertEqual(rebuilt.identity(for: AgentSession(id: "c", agentType: .codex)).ordinal, 3)
    }

    func testAllPersistedIdentitiesSurviveLargeHistoryAppendAndReload() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let oldest = AgentSession(id: "oldest-chat", agentType: .codex)
        let original = MascotTaskIdentityRegistry(defaults: defaults).identity(for: oldest)
        let oldestRecord = try XCTUnwrap(records(in: defaults).first)
        let seededCount = 5000
        var seededRecords = [oldestRecord]
        for ordinal in 2...seededCount {
            let suffix = String(ordinal, radix: 16)
            let digest = String(repeating: "0", count: 64 - suffix.count) + suffix
            seededRecords.append(["key": digest, "agent": "codex", "ordinal": ordinal])
        }
        defaults.set(["version": 1, "entries": seededRecords],
                     forKey: MascotTaskIdentityRegistry.cacheDefaultsKey)
        defaults.set(["codex": seededCount + 1], forKey: MascotTaskIdentityRegistry.counterDefaultsKey)

        let registry = MascotTaskIdentityRegistry(defaults: defaults)
        let next = registry.identity(for: AgentSession(id: "new-chat", agentType: .codex))
        XCTAssertEqual(next.ordinal, seededCount + 1)
        let restored = registry.identity(for: oldest)
        XCTAssertEqual(restored.ordinal, original.ordinal)
        XCTAssertEqual(restored.paletteIndex, original.paletteIndex)
        let retained = try records(in: defaults)
        XCTAssertEqual(retained.count, seededCount + 1)
        XCTAssertTrue(retained.contains { $0["key"] as? String == oldestRecord["key"] as? String })
        XCTAssertTrue(retained.contains { $0["ordinal"] as? Int == 2 })

        let rebuilt = MascotTaskIdentityRegistry(defaults: defaults)
        XCTAssertEqual(rebuilt.identity(for: oldest).ordinal, original.ordinal)
        XCTAssertEqual(rebuilt.identity(for: oldest).paletteIndex, original.paletteIndex)
        XCTAssertEqual(rebuilt.identity(for: AgentSession(id: "another-chat", agentType: .codex)).ordinal,
                       seededCount + 2)
        XCTAssertEqual(try records(in: defaults).count, seededCount + 2)
    }

    func testMalformedRowsAreIgnoredWithoutReplacingValidIdentity() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let session = AgentSession(id: "valid", agentType: .codex)
        _ = MascotTaskIdentityRegistry(defaults: defaults).identity(for: session)
        let valid = try XCTUnwrap(records(in: defaults).first)
        let malformed: [[String: Any]] = [
            ["key": "not-a-digest", "agent": "codex", "ordinal": 2],
            ["key": String(repeating: "a", count: 64), "agent": "codex", "ordinal": -2],
            ["key": String(repeating: "b", count: 64), "agent": "unknown-client", "ordinal": 2],
            ["key": String(repeating: "c", count: 64), "agent": "codex", "ordinal": 1],
        ]
        defaults.set(["version": 1, "entries": [valid] + malformed],
                     forKey: MascotTaskIdentityRegistry.cacheDefaultsKey)
        let registry = MascotTaskIdentityRegistry(defaults: defaults)
        XCTAssertEqual(registry.identity(for: session).ordinal, 1)
        XCTAssertEqual(registry.identity(for: AgentSession(id: "next", agentType: .codex)).ordinal, 2)
        XCTAssertEqual(try records(in: defaults).count, 2)
    }

    private func isolatedDefaults() throws -> (UserDefaults, String) {
        let suite = "dev.xisland.tests.mascot-task-identity.\(UUID().uuidString)"
        return (try XCTUnwrap(UserDefaults(suiteName: suite)), suite)
    }

    private func records(in defaults: UserDefaults) throws -> [[String: Any]] {
        let saved = try XCTUnwrap(defaults.dictionary(forKey: MascotTaskIdentityRegistry.cacheDefaultsKey))
        return try XCTUnwrap(saved["entries"] as? [[String: Any]])
    }
}
