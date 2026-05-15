import Foundation

enum MatchField: String, CaseIterable, Codable {
    case agentType
    case tool
    case workingDir

    var displayName: String {
        switch self {
        case .agentType: "Agent Type"
        case .tool: "Tool Name"
        case .workingDir: "Working Directory"
        }
    }
}

struct MuteRule: Codable, Identifiable {
    var id = UUID()
    var pattern: String
    var matchField: MatchField = .agentType
    var isEnabled: Bool = true

    func matches(session: AgentSession, event: SoundEvent) -> Bool {
        guard isEnabled, !pattern.isEmpty else { return false }
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return false }

        let target: String
        switch matchField {
        case .agentType:
            target = session.agentType.rawValue
        case .tool:
            target = event.rawValue
        case .workingDir:
            target = session.workingDirectory
        }

        let range = NSRange(target.startIndex..<target.endIndex, in: target)
        return regex.firstMatch(in: target, options: [], range: range) != nil
    }
}
