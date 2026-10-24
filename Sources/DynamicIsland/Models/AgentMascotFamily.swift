import SwiftUI

/// XIsland 自定义角色：客户端由轮廓识别，颜色由聊天／任务身份决定。
enum AgentMascotFamily: String, CaseIterable, Identifiable, Sendable {
    case crab, robot, star, pointer, sprout, book, gear, magnifier
    case goggles, bear, briefcase, cloud, crescent, whale, ghost, bolt
    case pi, wingedEnvelope, crystal, glove, wave, helmet, bubble, cat
    case dog, tent, chevron, paperPlane, kangaroo, pear, zebra, octopus
    case unknown

    var id: String { rawValue }

    static func forAgent(_ agentType: AgentType?) -> Self {
        guard let agentType else { return .unknown }
        switch agentType {
        case .claudeCode: return .crab
        case .codex: return .robot
        case .geminiCli: return .star
        case .cursor: return .pointer
        case .trae: return .sprout
        case .openCode: return .book
        case .droid: return .gear
        case .qoder: return .magnifier
        case .copilot: return .goggles
        case .codeBuddy: return .bear
        case .workBuddy: return .briefcase
        case .qwen: return .cloud
        case .kimi: return .crescent
        case .deepseek: return .whale
        case .kiro: return .ghost
        case .amp: return .bolt
        case .pi: return .pi
        case .hermes: return .wingedEnvelope
        case .glm: return .crystal
        case .aider: return .glove
        case .windsurf: return .wave
        case .devin: return .helmet
        case .amazonQ: return .bubble
        case .tabnine: return .cat
        case .cody: return .dog
        case .cline: return .tent
        case .continue: return .chevron
        case .copilotCli: return .paperPlane
        case .rooCode: return .kangaroo
        case .pearai: return .pear
        case .zed: return .zebra
        case .jetbrainsAi: return .octopus
        }
    }

    var faceScale: CGFloat { faceLayout.scale }

    /// 相对于头像边长的位移；调用方乘以实际 size 后使用。
    var faceOffset: CGSize { faceLayout.offset }

    private var faceLayout: (scale: CGFloat, offset: CGSize) {
        let layout: (CGFloat, CGFloat, CGFloat)
        switch self {
        case .robot: layout = (1, 0, 0)
        case .crab: layout = (0.64, 0, 0.06)
        case .star: layout = (0.60, 0, 0)
        case .pointer: layout = (0.55, -0.10, -0.05)
        case .sprout: layout = (0.64, 0, 0.15)
        case .book: layout = (0.70, 0, 0)
        case .gear: layout = (0.72, 0, 0)
        case .magnifier: layout = (0.72, -0.12, -0.12)
        case .goggles: layout = (0.64, 0, 0)
        case .bear: layout = (0.72, 0, 0.04)
        case .briefcase: layout = (0.70, 0, 0.08)
        case .cloud: layout = (0.72, 0, 0.06)
        case .crescent: layout = (0.52, -0.20, 0.04)
        case .whale: layout = (0.62, -0.11, 0.08)
        case .ghost: layout = (0.72, 0, -0.01)
        case .bolt: layout = (0.50, 0, -0.03)
        case .pi: layout = (0.58, 0, -0.07)
        case .wingedEnvelope: layout = (0.64, 0, 0)
        case .crystal: layout = (0.65, 0, 0)
        case .glove: layout = (0.62, 0, 0.10)
        case .wave: layout = (0.56, -0.08, 0.12)
        case .helmet: layout = (0.64, 0, 0.10)
        case .bubble: layout = (0.73, 0, -0.04)
        case .cat: layout = (0.72, 0, 0.07)
        case .dog: layout = (0.65, 0, 0)
        case .tent: layout = (0.58, 0, 0.10)
        case .chevron: layout = (0.55, -0.05, 0)
        case .paperPlane: layout = (0.56, 0.02, 0)
        case .kangaroo: layout = (0.61, 0, 0.12)
        case .pear: layout = (0.67, 0, 0.10)
        case .zebra: layout = (0.64, 0, 0.07)
        case .octopus: layout = (0.68, 0, -0.04)
        case .unknown: layout = (0.75, 0, 0)
        }
        return (layout.0, CGSize(width: layout.1, height: layout.2))
    }
}
