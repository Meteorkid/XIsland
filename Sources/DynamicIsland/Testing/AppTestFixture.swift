import Foundation

/// UI 测试场景的声明式描述，与 `Tests/Fixtures/app/*.json` 一一对应。
///
/// 加载器（`AppTestFixtureLoader`）把它解码后注入 `SessionManager` / `UpdateManager`，
/// 从而在没有真实代理进程的情况下复现特定界面状态。JSON 键名由 Codable 合成，
/// 因此字段名即契约：fixture 文件与其它模块都依赖它们，不可随意改名或改类型。
struct AppTestFixture: Codable {
    let selectedSessionId: String?
    let sessions: [SessionFixture]
    let update: UpdateFixture?

    // MARK: - 会话

    struct SessionFixture: Codable {
        let id: String
        let agentType: AgentType
        let terminal: String?
        let workingDirectory: String?
        let prompt: String?
        let status: SessionStatus
        let statusText: String?
        let agentResponse: String?
        let completedAt: Date?
        let pendingPermission: PendingPermissionFixture?
        let pendingQuestion: PendingQuestionFixture?
        let pendingPlanReview: PendingPlanReviewFixture?
    }

    // MARK: - 等待中的交互

    struct PendingPermissionFixture: Codable {
        let requestingAgent: AgentType
        let tool: String
        let description: String
        let filePath: String?
        let diff: String?
    }

    struct PendingQuestionFixture: Codable {
        let requestingAgent: AgentType
        let text: String
        let options: [String]
    }

    struct PendingPlanReviewFixture: Codable {
        let requestingAgent: AgentType
        let markdown: String
    }

    // MARK: - 更新

    struct UpdateFixture: Codable {
        let state: State
        let release: UpdateManager.ReleaseInfo?
        let version: String?
        let stage: String?
        let message: String?

        enum State: String, Codable {
            case idle
            case checking
            case upToDate
            case updateAvailable
            case installing
            case failed
        }
    }
}
