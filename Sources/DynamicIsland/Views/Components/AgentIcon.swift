import SwiftUI

struct AgentIcon: View {
    let agentType: AgentType
    var size: CGFloat = 24
    var status: SessionStatus = .active
    var showMascot: Bool = true
    @AppStorage("reduceMotion") private var reduceMotion = false

    private var statusColor: Color {
        status.uiColor
    }

    private var shouldPulse: Bool {
        status == .active || status == .thinking || status == .compacting
    }

    var body: some View {
        ZStack {
            // 脉冲光环
            if shouldPulse && !reduceMotion {
                RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                    .fill(statusColor.opacity(0.3))
                    .frame(width: size + 4, height: size + 4)
                    .phaseAnimator([false, true]) { content, phase in
                        content.opacity(phase ? 0.6 : 0.2)
                    } animation: { _ in .easeInOut(duration: 1.5).repeatForever(autoreverses: true) }
            }

            // 背景 + 边框
            RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                .fill(agentType.color.opacity(0.2))
                .frame(width: size, height: size)
                .overlay {
                    RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                        .strokeBorder(statusColor.opacity(0.6), lineWidth: 1.5)
                }

            // 吉祥物表情 or SF Symbol fallback
            if showMascot && size >= 20 {
                MascotView(status: status, size: size)
            } else {
                Image(systemName: agentType.iconSymbol)
                    .font(.system(size: size * 0.45, weight: .semibold))
                    .foregroundStyle(agentType.color)
            }
        }
    }
}
