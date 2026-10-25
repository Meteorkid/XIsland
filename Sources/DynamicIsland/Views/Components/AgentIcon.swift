import SwiftUI

struct AgentIcon: View {
    let agentType: AgentType
    var size: CGFloat = 24
    var status: SessionStatus = .active
    var showMascot: Bool = true
    var taskIdentity: MascotTaskIdentity?
    var completionNeedsReview = false
    var taskTitle: String? = nil
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @AppStorage("reduceMotion") private var appReduceMotion = false
    @AppStorage("disableAnimations") private var disableAnimations = false

    init(agentType: AgentType, size: CGFloat = 24, status: SessionStatus = .active,
         showMascot: Bool = true, taskIdentity: MascotTaskIdentity? = nil, completionNeedsReview: Bool = false) {
        self.agentType = agentType; self.size = size; self.status = status
        self.showMascot = showMascot; self.taskIdentity = taskIdentity
        self.completionNeedsReview = completionNeedsReview
    }

    @MainActor
    init(session: AgentSession, size: CGFloat = 24, agentType: AgentType? = nil, status: SessionStatus? = nil) {
        self.init(agentType: agentType ?? session.agentType, size: size, status: status ?? session.mascotStatus,
                  taskIdentity: MascotTaskIdentityRegistry.shared.identity(for: session, agentType: agentType),
                  completionNeedsReview: session.completionNeedsReview)
        taskTitle = session.displayTitle
    }

    private var reduceMotion: Bool {
        !IslandMotionPolicy(reduceMotion: appReduceMotion, systemReduceMotion: systemReduceMotion,
                            disableAnimations: disableAnimations).allowsContinuousAnimation
    }

    private var tint: Color { taskIdentity?.color ?? agentType.color }
    private var family: AgentMascotFamily { .forAgent(agentType) }
    private var shouldPulse: Bool { [.active, .thinking, .compacting].contains(status) }

    var accessibilityDescription: String {
        [agentType.displayName, taskIdentity.map { L10n.mascotTask($0.ordinal) },
         status == .completed && completionNeedsReview ? L10n.completedNeedsReview : status.displayName, taskTitle]
            .compactMap { $0 }.joined(separator: " · ")
    }

    private var stateSymbol: String? {
        switch status {
        case .waitingPermission: return "lock.fill"
        case .waitingAnswer: return "questionmark"
        case .waitingPlanReview: return "doc.text"
        case .error: return "exclamationmark"
        case .completed: return completionNeedsReview ? "sparkle" : "checkmark"
        case .observationUnavailable: return "slash.circle"
        case .completionUnconfirmed: return "ellipsis"
        default: return nil
        }
    }

    var body: some View {
        ZStack {
            if showMascot {
                if shouldPulse && !reduceMotion {
                    AgentMascotShape(family: family)
                        .fill(tint.opacity(0.25))
                        .padding(-2)
                        .phaseAnimator([false, true]) { content, phase in
                            content.opacity(phase ? 0.6 : 0.2)
                        } animation: { _ in .easeInOut(duration: 1.5) }
                }
                AgentMascotShape(family: family)
                    .fill(tint.opacity(colorScheme == .dark ? 0.18 : 0.15))
                    .overlay { AgentMascotShape(family: family).stroke(tint, lineWidth: 1.35) }
                    .padding(0.8)
                MascotView(status: status, size: size * family.faceScale, tint: tint,
                           completionNeedsReview: completionNeedsReview, showsDecorations: false)
                    .offset(x: family.faceOffset.width * size, y: family.faceOffset.height * size)
                    .accessibilityHidden(true)
            } else {
                Image(systemName: agentType.iconSymbol)
                    .font(.system(size: size * 0.55, weight: .semibold))
                    .foregroundStyle(tint)
            }
        }
        .frame(width: size, height: size)
        .colorMultiply(colorScheme == .light ? Color(white: 0.68) : .white)
        .overlay(alignment: .topTrailing) {
            if let stateSymbol {
                Image(systemName: stateSymbol)
                    .font(.system(size: max(6, size * 0.27), weight: .black))
                    .foregroundStyle(status == .error ? Color.red : Color.primary)
                    .padding(1.2)
                    .background(colorScheme == .dark ? Color.black : Color.white, in: Circle())
                    .offset(x: 2, y: -2)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
        .accessibilityAddTraits(.isImage)
        .help(accessibilityDescription)
    }
}

extension AgentSession {
    var mascotStatus: SessionStatus {
        if pendingPermission != nil { return .waitingPermission }
        if pendingQuestion != nil { return .waitingAnswer }
        if pendingPlanReview != nil { return .waitingPlanReview }
        return status
    }
}
