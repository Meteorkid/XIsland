import Foundation

/// 负责把 JSON fixture 解码并注入测试运行时的加载器。
///
/// fixture 文件统一放在 `Tests/Fixtures/app` 目录，路径基于源码位置（`#filePath`）
/// 推导，因此与进程当前工作目录无关，测试里切换 cwd 也不会影响定位。
@MainActor
enum AppTestFixtureLoader {
    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    // MARK: - 目录解析

    /// 从源码位置向上回溯四级得到仓库根，再拼接 fixtures 目录。
    private static func defaultFixturesDirectoryURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Testing
            .deletingLastPathComponent() // DynamicIsland
            .deletingLastPathComponent() // Sources
            .deletingLastPathComponent() // 仓库根
            .appendingPathComponent("Tests/Fixtures/app", isDirectory: true)
    }

    // MARK: - 加载入口

    static func load(
        named fixtureName: String,
        into sessionManager: SessionManager,
        updateManager: UpdateManager,
        fixturesDirectoryURL: URL? = nil
    ) throws -> AppTestFixture {
        let directory = fixturesDirectoryURL ?? defaultFixturesDirectoryURL()
        return try load(
            from: directory.appendingPathComponent("\(fixtureName).json"),
            into: sessionManager,
            updateManager: updateManager
        )
    }

    static func load(
        from fixtureURL: URL,
        into sessionManager: SessionManager,
        updateManager: UpdateManager
    ) throws -> AppTestFixture {
        let fixture = try decoder.decode(AppTestFixture.self, from: Data(contentsOf: fixtureURL))
        apply(fixture, to: sessionManager, updateManager: updateManager)
        return fixture
    }

    /// 根据 `AppTestConfiguration` 决定按路径还是按名称加载；两者都未指定时返回 nil。
    @discardableResult
    static func load(
        configuration: AppTestConfiguration,
        into sessionManager: SessionManager,
        updateManager: UpdateManager,
        fixturesDirectoryURL: URL? = nil
    ) throws -> AppTestFixture? {
        if let fixturePath = configuration.fixturePath {
            return try load(
                from: URL(fileURLWithPath: fixturePath),
                into: sessionManager,
                updateManager: updateManager
            )
        }

        guard let fixtureName = configuration.fixtureName else {
            return nil
        }

        return try load(
            named: fixtureName,
            into: sessionManager,
            updateManager: updateManager,
            fixturesDirectoryURL: fixturesDirectoryURL
        )
    }

    // MARK: - 应用

    static func apply(
        _ fixture: AppTestFixture,
        to sessionManager: SessionManager,
        updateManager: UpdateManager
    ) {
        sessionManager.sessions = fixture.sessions.map(makeSession(from:))
        sessionManager.selectedSessionId = fixture.selectedSessionId ?? sessionManager.sessions.first?.id
        updateManager.applyFixture(fixture.update)
    }

    // MARK: - 会话重建

    private static func makeSession(from fixture: AppTestFixture.SessionFixture) -> AgentSession {
        let session = AgentSession(
            id: fixture.id,
            agentType: fixture.agentType,
            terminal: fixture.terminal ?? "",
            workingDirectory: fixture.workingDirectory ?? "",
            prompt: fixture.prompt ?? ""
        )
        session.status = fixture.status
        session.statusText = fixture.statusText ?? ""
        session.agentResponse = fixture.agentResponse ?? ""
        session.completedAt = fixture.completedAt

        applyPromptHistory(to: session, prompt: fixture.prompt)
        applyPendingInteractions(to: session, from: fixture)

        return session
    }

    /// 非空 prompt 记入聊天历史，保证界面能展示会话标题 / 首条用户消息。
    private static func applyPromptHistory(to session: AgentSession, prompt: String?) {
        guard let prompt, !prompt.isEmpty else { return }
        session.chatHistory.append(ChatMessage(timestamp: Date(), role: .user, content: prompt))
    }

    /// 把 fixture 里声明的等待交互装配到会话上（闭包仅作占位，测试不会真正响应）。
    private static func applyPendingInteractions(to session: AgentSession, from fixture: AppTestFixture.SessionFixture) {
        if let pendingPermission = fixture.pendingPermission {
            session.pendingPermission = PendingPermission(
                requestingAgent: pendingPermission.requestingAgent,
                tool: pendingPermission.tool,
                description: pendingPermission.description,
                diff: pendingPermission.diff,
                filePath: pendingPermission.filePath,
                respond: { _ in }
            )
        }

        if let pendingQuestion = fixture.pendingQuestion {
            session.pendingQuestion = PendingQuestion(
                requestingAgent: pendingQuestion.requestingAgent,
                text: pendingQuestion.text,
                options: pendingQuestion.options,
                respond: { _ in },
                cancel: nil
            )
        }

        if let pendingPlanReview = fixture.pendingPlanReview {
            session.pendingPlanReview = PendingPlanReview(
                requestingAgent: pendingPlanReview.requestingAgent,
                markdown: pendingPlanReview.markdown,
                respond: { _, _ in }
            )
        }
    }
}
