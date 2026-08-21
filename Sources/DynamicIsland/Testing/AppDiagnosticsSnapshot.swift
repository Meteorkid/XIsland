import Foundation

/// 供 UI 测试与诊断工具消费的运行时快照。
///
/// 把「灵动岛当前状态 + 选中/可见会话 + 等待中的交互 + 更新状态 + 可访问性标识符」
/// 序列化成一个稳定、可 JSON 编码的纯数据对象。UI 测试通过读取诊断 JSON 断言界面状态，
/// 因此字段命名与字符串取值都属于对外契约，必须保持稳定。
public struct AppDiagnosticsSnapshot: Codable, Equatable {
    public let islandState: String
    public let selectedSessionId: String?
    public let pendingInteraction: String?
    public let visibleSessions: [SessionSnapshot]
    public let visibleAccessibilityIdentifiers: [String]
    public let update: UpdateSnapshot

    /// 单个会话在诊断快照中的投影，只保留测试关心的字段。
    public struct SessionSnapshot: Codable, Equatable {
        public let id: String
        public let agentType: String
        public let status: String
        public let workingDirectory: String
        public let prompt: String
        public let pendingInteraction: String?
    }

    /// 更新子系统的诊断投影。
    public struct UpdateSnapshot: Codable, Equatable {
        public let state: String
        public let version: String?
        public let dmgURL: String?
    }

    // MARK: - 构建快照

    /// 基于会话管理器与更新管理器的当前状态生成一份快照。
    @MainActor
    static func make(
        sessionManager: SessionManager,
        updateManager: UpdateManager,
        islandState: String,
        preferencesVisible: Bool = false
    ) -> Self {
        let primarySession = sessionManager.prioritizedInteractionSession ?? sessionManager.selectedSession

        return Self(
            islandState: islandState,
            selectedSessionId: sessionManager.selectedSessionId,
            pendingInteraction: primarySession.flatMap(Self.interactionKind(for:)),
            visibleSessions: Self.makeSessionSnapshots(from: sessionManager),
            visibleAccessibilityIdentifiers: Self.makeAccessibilityIdentifiers(
                sessionManager: sessionManager,
                updateManager: updateManager,
                islandState: islandState,
                preferencesVisible: preferencesVisible
            ),
            update: Self.makeUpdateSnapshot(from: updateManager)
        )
    }

    // MARK: - 会话投影

    @MainActor
    private static func makeSessionSnapshots(from sessionManager: SessionManager) -> [SessionSnapshot] {
        sessionManager.visibleSessions.map { session in
            SessionSnapshot(
                id: session.id,
                agentType: session.agentType.rawValue,
                status: session.status.rawValue,
                workingDirectory: session.workingDirectory,
                prompt: session.prompt,
                pendingInteraction: interactionKind(for: session)
            )
        }
    }

    // MARK: - 可访问性标识符

    /// 计算测试当前应当能在界面上定位到的可访问性标识符集合。
    ///
    /// 测试逐项断言，因此这里刻意保持「根节点 → 交互面板 → 偏好设置」的稳定追加顺序。
    @MainActor
    private static func makeAccessibilityIdentifiers(
        sessionManager: SessionManager,
        updateManager: UpdateManager,
        islandState: String,
        preferencesVisible: Bool
    ) -> [String] {
        var identifiers: [String] = []

        identifiers.append(islandState == "collapsed" ? TestAccessibility.collapsedPill : TestAccessibility.islandRoot)

        if let session = sessionManager.prioritizedInteractionSession ?? sessionManager.selectedSession {
            identifiers.append(contentsOf: interactionIdentifiers(for: session))
        }

        if preferencesVisible {
            identifiers.append(contentsOf: preferencesIdentifiers(for: updateManager))
        }

        return identifiers
    }

    /// 针对等待中的交互，追加对应的面板与按钮标识符。
    private static func interactionIdentifiers(for session: AgentSession) -> [String] {
        switch interactionKind(for: session) {
        case "permission":
            return [
                TestAccessibility.permissionPanel,
                TestAccessibility.permissionDenyButton,
                TestAccessibility.permissionApproveButton,
            ]
        case "question":
            let options = session.pendingQuestion?.options.indices.map(TestAccessibility.questionOption(index:)) ?? []
            return [TestAccessibility.questionPanel] + options
        case "planReview":
            return [
                TestAccessibility.planPanel,
                TestAccessibility.planRejectButton,
                TestAccessibility.planApproveButton,
            ]
        default:
            return []
        }
    }

    /// 偏好设置窗口可见时追加的标识符；只有存在可下载安装包时才追加安装按钮。
    @MainActor
    private static func preferencesIdentifiers(for updateManager: UpdateManager) -> [String] {
        var identifiers = [
            TestAccessibility.preferencesRoot,
            TestAccessibility.updateStatusLabel,
            TestAccessibility.updateCheckButton,
        ]
        if updateManager.latestRelease?.dmgURL != nil {
            identifiers.append(TestAccessibility.updateInstallButton)
        }
        return identifiers
    }

    // MARK: - 状态映射

    /// 把会话状态映射成稳定的交互类别字符串（无交互时为 nil）。
    private static func interactionKind(for session: AgentSession) -> String? {
        switch session.status {
        case .waitingPermission:
            return "permission"
        case .waitingAnswer:
            return "question"
        case .waitingPlanReview:
            return "planReview"
        default:
            return nil
        }
    }

    /// 把更新状态映射成稳定的字符串。
    private static func updateStateName(_ state: UpdateManager.State) -> String {
        switch state {
        case .idle: return "idle"
        case .checking: return "checking"
        case .upToDate: return "upToDate"
        case .updateAvailable: return "updateAvailable"
        case .installing: return "installing"
        case .failed: return "failed"
        }
    }

    // MARK: - 更新投影

    @MainActor
    private static func makeUpdateSnapshot(from updateManager: UpdateManager) -> UpdateSnapshot {
        UpdateSnapshot(
            state: updateStateName(updateManager.state),
            version: updateVersion(from: updateManager),
            dmgURL: updateManager.latestRelease?.dmgURL?.absoluteString
        )
    }

    /// 优先使用「有新版本」状态携带的版本号，否则回退到最新发布的规范化版本。
    @MainActor
    private static func updateVersion(from updateManager: UpdateManager) -> String? {
        if case .updateAvailable(let version) = updateManager.state {
            return version
        }
        return updateManager.latestRelease?.normalizedVersion
    }
}

extension IslandState {
    /// 该状态在诊断输出中的字符串表示，与界面测试约定保持一致。
    var diagnosticsValue: String {
        switch self {
        case .collapsed: return "collapsed"
        case .expanded: return "expanded"
        case .permission: return "permission"
        case .question: return "question"
        case .planReview: return "planReview"
        }
    }
}
