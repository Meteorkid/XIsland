import XCTest
@testable import XIsland

final class AgentTypeTests: XCTestCase {

    // MARK: - from() parsing

    func testFromDirectRawValue() {
        XCTAssertEqual(AgentType.from("claude_code"), .claudeCode)
        XCTAssertEqual(AgentType.from("codex"), .codex)
        XCTAssertEqual(AgentType.from("cursor"), .cursor)
    }

    func testFromDisplayName() {
        XCTAssertEqual(AgentType.from("Claude Code"), .claudeCode)
        XCTAssertEqual(AgentType.from("Gemini CLI"), .geminiCli)
    }

    func testFromAlias() {
        XCTAssertEqual(AgentType.from("claude"), .claudeCode)
        XCTAssertEqual(AgentType.from("windsurf"), .windsurf)
        XCTAssertEqual(AgentType.from("zhipu"), .glm)
    }

    func testFromAliasNewAgents() {
        XCTAssertEqual(AgentType.from("roo"), .rooCode)
        XCTAssertEqual(AgentType.from("roo-cline"), .rooCode)
        XCTAssertEqual(AgentType.from("pearai"), .pearai)
        XCTAssertEqual(AgentType.from("zed"), .zed)
        XCTAssertEqual(AgentType.from("zed-ai"), .zed)
        XCTAssertEqual(AgentType.from("jetbrains"), .jetbrainsAi)
        XCTAssertEqual(AgentType.from("intellij"), .jetbrainsAi)
    }

    func testFromSubstringFallback() {
        XCTAssertEqual(AgentType.from("my-claude-agent"), .claudeCode)
        XCTAssertEqual(AgentType.from("cursor-ide"), .cursor)
    }

    func testFromNilReturnsNil() {
        XCTAssertNil(AgentType.from(nil))
        XCTAssertNil(AgentType.from(""))
        XCTAssertNil(AgentType.from("   "))
    }

    func testFromUnknownReturnsNil() {
        XCTAssertNil(AgentType.from("totally_unknown_agent_xyz"))
    }

    // MARK: - fromBundleId

    func testFromBundleId() {
        XCTAssertEqual(AgentType.fromBundleId("com.todesktop.230313mzl4w4u92"), .cursor)
        XCTAssertEqual(AgentType.fromBundleId("com.openai.codex"), .codex)
        XCTAssertEqual(AgentType.fromBundleId("com.trae.app"), .trae)
        XCTAssertEqual(AgentType.fromBundleId("cn.trae.solo.app"), .trae)
    }

    func testFromBundleIdNewAgents() {
        XCTAssertEqual(AgentType.fromBundleId("dev.pearai"), .pearai)
        XCTAssertEqual(AgentType.fromBundleId("com.pearai.app"), .pearai)
        XCTAssertEqual(AgentType.fromBundleId("dev.zed.Zed"), .zed)
        XCTAssertEqual(AgentType.fromBundleId("dev.zed.Zed-Preview"), .zed)
    }

    func testFromBundleIdCaseInsensitive() {
        XCTAssertEqual(AgentType.fromBundleId("COM.OPENAI.CODEX"), .codex)
    }

    func testFromBundleIdUnknownReturnsNil() {
        XCTAssertNil(AgentType.fromBundleId("com.unknown.app"))
    }

    // MARK: - Meta properties

    func testAllCasesHaveMeta() {
        for agent in AgentType.allCases {
            XCTAssertFalse(agent.displayName.isEmpty, "\(agent) displayName is empty")
            XCTAssertFalse(agent.shortName.isEmpty, "\(agent) shortName is empty")
            XCTAssertFalse(agent.iconSymbol.isEmpty, "\(agent) iconSymbol is empty")
        }
    }

    func testShortNameIsShorterThanDisplayName() {
        for agent in AgentType.allCases {
            XCTAssertLessThanOrEqual(agent.shortName.count, agent.displayName.count,
                "\(agent) shortName should be <= displayName")
        }
    }

    // MARK: - Registry completeness

    func testRegistryContainsAllCases() {
        for agent in AgentType.allCases {
            XCTAssertNotNil(AgentType.registry[agent], "\(agent) missing from registry")
        }
    }

    // MARK: - Codable

    func testAgentTypeEncodesAndDecodes() throws {
        let agent: AgentType = .claudeCode
        let data = try JSONEncoder().encode(agent)
        let decoded = try JSONDecoder().decode(AgentType.self, from: data)
        XCTAssertEqual(decoded, agent)
    }

    // MARK: - Identifiable

    func testIdIsRawValue() {
        XCTAssertEqual(AgentType.claudeCode.id, "claude_code")
        XCTAssertEqual(AgentType.geminiCli.id, "gemini_cli")
    }
}
