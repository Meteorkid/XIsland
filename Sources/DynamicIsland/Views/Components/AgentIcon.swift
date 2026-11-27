import AppKit
import SwiftUI

struct AgentIcon: View {
    let agentType: AgentType
    var size: CGFloat = 24
    var status: SessionStatus = .active
    var showMascot: Bool = true
    var taskIdentity: MascotTaskIdentity?
    var completionNeedsReview = false
    var taskTitle: String? = nil
    var attentionToken: String?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.taskAttentionPresented) private var taskAttentionPresented
    @AppStorage("reduceMotion") private var appReduceMotion = false
    @AppStorage("disableAnimations") private var disableAnimations = false
    @AppStorage("taskAttentionEnabled") private var taskAttentionEnabled = true
    @AppStorage("mascotIconStyle") private var iconStyleRaw = MascotIconStyle.mascot.rawValue
    @State private var mascotRevision = 0
    private static let appIconCache = NSCache<NSString, NSImage>()

    private var iconStyle: MascotIconStyle {
        MascotIconStyle(rawValue: iconStyleRaw) ?? .mascot
    }

    init(agentType: AgentType, size: CGFloat = 24, status: SessionStatus = .active,
         showMascot: Bool = true, taskIdentity: MascotTaskIdentity? = nil, completionNeedsReview: Bool = false) {
        self.agentType = agentType; self.size = size; self.status = status
        self.showMascot = showMascot; self.taskIdentity = taskIdentity
        self.completionNeedsReview = completionNeedsReview
        attentionToken = Self.attentionToken(status: status, completionNeedsReview: completionNeedsReview)
    }

    @MainActor
    init(session: AgentSession, size: CGFloat = 24, agentType: AgentType? = nil, status: SessionStatus? = nil) {
        self.init(agentType: agentType ?? session.agentType, size: size, status: status ?? session.mascotStatus,
                  taskIdentity: MascotTaskIdentityRegistry.shared.identity(for: session, agentType: agentType),
                  completionNeedsReview: session.completionNeedsReview)
        taskTitle = session.displayTitle
        if let permission = session.pendingPermission {
            attentionToken = "permission-\(session.id)-\(permission.nativeRequestId ?? permission.id.uuidString)"
        } else if let question = session.pendingQuestion {
            attentionToken = "question-\(session.id)-\(question.nativeRequestId ?? question.id.uuidString)"
        } else if let plan = session.pendingPlanReview {
            attentionToken = "plan-\(plan.id)"
        } else if session.status == .completed, session.completionNeedsReview {
            attentionToken = "completion-\(session.id)-\(session.completedAt?.timeIntervalSince1970 ?? 0)"
        } else {
            attentionToken = Self.attentionToken(status: self.status, completionNeedsReview: false)
                .map { "observed-\(session.id)-\($0)" }
        }
    }

    static func attentionToken(status: SessionStatus, completionNeedsReview: Bool) -> String? {
        switch status {
        case .completed where completionNeedsReview: return "completion"
        case .waitingPermission: return "permission"
        case .waitingAnswer: return "question"
        case .waitingPlanReview: return "plan"
        default: return nil
        }
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

    @ViewBuilder
    private var mascotContent: some View {
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
    }

    @ViewBuilder
    private var appLogoContent: some View {
        if let url = appURL {
            Image(nsImage: Self.appIcon(for: url))
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        } else {
            mascotContent
        }
    }

    @ViewBuilder
    private var customIconContent: some View {
        let _ = mascotRevision
        Group {
            if let image = CustomMascotStore.image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
            } else {
                mascotContent
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .customMascotDidChange)) { _ in
            mascotRevision += 1
        }
    }

    private static func appIcon(for url: URL) -> NSImage {
        let key = url.path as NSString
        if let cached = appIconCache.object(forKey: key) { return cached }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        appIconCache.setObject(icon, forKey: key)
        return icon
    }

    private var appURL: URL? {
        for identifier in agentType.meta.bundleIds {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) {
                return url
            }
        }
        return nil
    }

    var body: some View {
        ZStack {
            // 非吉祥物模式补一层呼吸光晕，保持运行中的视觉提示一致。
            if iconStyle != .mascot, shouldPulse, !reduceMotion {
                RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                    .fill(tint.opacity(0.25))
                    .padding(-2)
                    .phaseAnimator([false, true]) { content, phase in
                        content.opacity(phase ? 0.6 : 0.2)
                    } animation: { _ in .easeInOut(duration: 1.5) }
            }
            if showMascot {
                switch iconStyle {
                case .appLogo: appLogoContent
                case .custom: customIconContent
                case .mascot: mascotContent
                }
            } else {
                Image(systemName: agentType.iconSymbol)
                    .font(.system(size: size * 0.55, weight: .semibold))
                    .foregroundStyle(tint)
            }
        }
        .frame(width: size, height: size)
        .colorMultiply(iconStyle == .mascot && colorScheme == .light ? Color(white: 0.68) : .white)
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
        .modifier(TaskAttentionBounce(token: attentionToken, size: size,
                                      enabled: showMascot && taskAttentionEnabled && taskAttentionPresented && !reduceMotion,
                                      repeats: completionNeedsReview))
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
