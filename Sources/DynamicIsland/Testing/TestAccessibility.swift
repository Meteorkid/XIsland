import Foundation

public enum TestAccessibility {
    public static let islandRoot = "island.root"
    public static let collapsedPill = "island.collapsed-pill"
    public static let sessionList = "island.session-list"
    public static let permissionPanel = "island.permission-panel"
    public static let permissionApproveButton = "island.permission-approve"
    public static let permissionDenyButton = "island.permission-deny"
    public static let questionPanel = "island.question-panel"
    public static let planPanel = "island.plan-panel"
    public static let planApproveButton = "island.plan-approve"
    public static let planRejectButton = "island.plan-reject"
    public static let planFeedbackField = "island.plan-feedback"
    public static let preferencesRoot = "preferences.root"
    public static let updateCheckButton = "preferences.update-check"
    public static let updateInstallButton = "preferences.update-install"
    public static let updateStatusLabel = "preferences.update-status"
    public static let agentFlowRegion = "island.agent-flow-region"
    /// 专用状态（permission / question / planReview）下进入 Agent Flow 总览的入口按钮。
    public static let agentFlowViewEntryButton = "island.agent-flow.view-entry"

    public static func sessionCard(id: String) -> String {
        "island.session-card.\(id)"
    }

    public static func questionOption(index: Int) -> String {
        "island.question-option.\(index)"
    }

    public static func agentFlowProjectCard(id: String) -> String {
        "island.agent-flow.project.\(id)"
    }

    public static func agentFlowBlockerRow(id: String) -> String {
        "island.agent-flow.blocker.\(id)"
    }

    public static func agentFlowJumpButton(id: String) -> String {
        "island.agent-flow.jump.\(id)"
    }
}
