import Foundation

/// GLM 是模型来源；客户端仍负责事件、权限和会话身份。
enum GLMIntegration {
    static let clients: [AgentType] = [.claudeCode, .openCode, .cline, .pi]

    static func isGLMModel(_ model: String) -> Bool {
        let name = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard name.utf8.count <= 256 else { return false }
        return name.range(of: #"^(?:[a-z0-9._-]+/)*glm(?:-[a-z0-9][a-z0-9._-]*(?:\[[a-z0-9]+\])?|[0-9][a-z0-9._-]*)?$"#,
                          options: .regularExpression) != nil
    }
}

extension AgentSession {
    var usesGLMModel: Bool { GLMIntegration.isGLMModel(tokenUsage.model) }
}
