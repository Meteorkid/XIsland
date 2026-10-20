import Foundation

enum IntegrationSetupAction: Equatable {
    case prepareAll
    case configure(AgentType)
    case openClient(AgentType)
    case prepareFiles(AgentType)
    case openGuide(AgentType)
    case refresh
}

/// 展示次序和下一步动作只依据已有证据，不在界面中推断授权。
enum IntegrationSetupPresentation {
    static func pendingRows(_ rows: [IntegrationSetupRow]) -> [IntegrationSetupRow] {
        rows.enumerated().filter { priority($0.element) != nil }.sorted {
            let left = priority($0.element)!, right = priority($1.element)!
            return left == right ? $0.offset < $1.offset : left < right
        }.map(\.element)
    }

    static func readyRows(_ rows: [IntegrationSetupRow]) -> [IntegrationSetupRow] {
        rows.filter { $0.phase == .waitingForActivity || $0.phase == .connected }
    }

    static func otherRows(_ rows: [IntegrationSetupRow]) -> [IntegrationSetupRow] {
        rows.filter { priority($0) == nil && $0.phase != .waitingForActivity && $0.phase != .connected }
    }

    static func primaryAction(_ rows: [IntegrationSetupRow], canPrepareAll: Bool,
                              canPrepareFiles: Bool) -> IntegrationSetupAction? {
        let pending = pendingRows(rows)
        if let configurable = pending.first(where: { $0.phase == .needsConfiguration && $0.canConfigure }) {
            return canPrepareAll ? .prepareAll : .configure(configurable.agent)
        }
        return pending.first.flatMap { rowAction($0, canPrepareFiles: canPrepareFiles) }
    }

    static func rowAction(_ row: IntegrationSetupRow, canPrepareFiles: Bool) -> IntegrationSetupAction? {
        if row.agent == .glm { return .openGuide(row.agent) }
        switch row.phase {
        case .needsConfiguration:
            return row.canConfigure ? .configure(row.agent) : .openGuide(row.agent)
        case .disabled: return nil
        case .needsAuthorization: return .openClient(row.agent)
        case .needsSetup:
            return canPrepareFiles && [.workBuddy, .kiro].contains(row.agent)
                ? .prepareFiles(row.agent) : .openGuide(row.agent)
        case .waitingForActivity, .checkFailed: return .refresh
        case .notInstalled: return .openGuide(row.agent)
        case .connected: return nil
        }
    }

    private static func priority(_ row: IntegrationSetupRow) -> Int? {
        guard row.agent.isSupported, row.agent != .glm else { return nil }
        switch row.phase {
        case .needsConfiguration: return row.canConfigure ? 0 : 2
        case .needsAuthorization: return 1
        case .needsSetup: return 2
        case .checkFailed: return 3
        case .notInstalled, .disabled, .waitingForActivity, .connected: return nil
        }
    }
}
