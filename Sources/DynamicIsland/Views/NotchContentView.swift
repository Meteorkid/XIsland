import SwiftUI

enum IslandState: Equatable {
    case collapsed
    case expanded
    case permission(String)
    case question(String)
    case planReview(String)
}

struct NotchContentView: View {
    @Environment(SessionManager.self) private var manager
    @Environment(AudioEngine.self) private var audio
    @Environment(QuotaTracker.self) private var quotaTracker
    @State private var islandObscuredByNotch = false
    @State private var state: IslandState = .collapsed
    @State private var isHovering = false
    @State private var expandedByHover = false
    @State private var expandedAt: Date = .distantPast
    @State private var showContent = false
    @State private var jumpMouseLocation: CGPoint?
    @State private var hoverTimer: Timer?
    @State private var lastCollapseAt: Date = .distantPast
    @State private var expandPending = false
    @State private var collapseAnimating = false
    @State private var collapseGeneration = 0
    @State private var expandedAutoHideWorkItem: DispatchWorkItem?
    @State private var lastExpandedInteractionAt: Date = .distantPast
    @State private var lastExpandedInteractionMarkAt: Date = .distantPast
    /// Last known expanded `shapeHeight` (black panel), used to interpolate notch corner radii with `shapeHeight` during spring (avoids boolean snap).
    @State private var cachedExpandedShapeHeight: CGFloat = 220
    @State var activityLogExpanded = false
    @State private var notificationTokens: [NSObjectProtocol] = []
    @AppStorage("disableAnimations") private var disableAnimations = false
    @AppStorage("autoCollapseDelay") private var autoCollapseDelay = 3.0
    @AppStorage("smartSuppression") private var smartSuppression = true
    @AppStorage("autoHideWhenNoActiveSessions") private var autoHideWhenNoActiveSessions = false
    var onSizeChange: ((CGFloat, CGFloat, Bool) -> Void)?

    private var isExpanded: Bool { state != .collapsed }

    private var contentWidth: CGFloat {
        isExpanded ? expandedWidth : pillWidth
    }

    private var collapsedShapeHeight: CGFloat { 32 }
    private var collapsedOuterHeight: CGFloat { collapsedShapeHeight }

    private var contentHeight: CGFloat {
        isExpanded ? expandedHeight : collapsedOuterHeight
    }

    private var expandedWidth: CGFloat {
        switch state {
        case .collapsed: return 0
        case .expanded: return 420
        case .permission, .question: return 440
        case .planReview: return 500
        }
    }

    private var expandedHeight: CGFloat {
        switch state {
        case .collapsed: return 0
        case .expanded:
            let count = manager.visibleSessions.count
            let listH = min(CGFloat(count) * 80 + 30, 480)
            let logH: CGFloat = activityLogExpanded ? 140 : 0
            return Self.expandedPanelHeaderHeight + listH + logH + Self.expandedPanelBottomInset
        case .permission(let id):
            return permissionExpandedTotalHeight(sessionId: id)
        case .question(let id):
            return questionExpandedTotalHeight(sessionId: id)
        case .planReview: return 480
        }
    }

    /// Permission card body only (matches `PermissionApprovalView` layout estimate).
    private func permissionCardInnerHeight(sessionId: String) -> CGFloat {
        let perm = manager.sessions.first(where: { $0.id == sessionId })?.pendingPermission
        var h: CGFloat = 42 + 1 + 30
        let hasDesc = perm != nil && !perm!.description.isEmpty
        let hasPath = perm?.filePath.map { !$0.isEmpty } ?? false
        let hasDiff = perm?.diff.map { !$0.isEmpty } ?? false
        h += hasDesc ? 52 : (hasPath ? 52 : 0)
        if hasDesc && hasPath { h += 22 }
        if hasDiff { h += 130 }
        h += 52
        return min(h, 480)
    }

    /// Full expanded height for permission mode: island toolbar + card + bottom inset (same as session list layout).
    private func permissionExpandedTotalHeight(sessionId: String) -> CGFloat {
        let inner = permissionCardInnerHeight(sessionId: sessionId)
        return inner + Self.expandedPanelHeaderHeight + Self.expandedPanelBottomInset
    }

    /// Full expanded height for question mode: island toolbar + question card + bottom inset.
    private func questionExpandedTotalHeight(sessionId: String) -> CGFloat {
        let optionCount = manager.sessions.first(where: { $0.id == sessionId })?.pendingQuestion?.options.count ?? 0
        let questionInnerHeight: CGFloat = min(120 + CGFloat(max(optionCount, 2)) * 42, 480)
        let total = questionInnerHeight + Self.expandedPanelHeaderHeight + Self.expandedPanelBottomInset
        return min(total, 480)
    }

    private var shapeWidth: CGFloat {
        isExpanded ? expandedWidth : pillWidth
    }

    private var shapeHeight: CGFloat {
        isExpanded ? expandedHeight : collapsedShapeHeight
    }

    private var pillFillColor: Color { IslandStyle.surface }

    private var pillStrokeOpacity: CGFloat { IslandStyle.strokeOpacity }

    /// 0 = collapsed strip (flat top), 1 = full expanded card — follows `shapeHeight` during spring so corners don’t snap before size.
    private var notchShapeOpenProgress: CGFloat {
        NotchShapeGeometry.openProgress(
            shapeHeight: shapeHeight,
            cachedExpandedShapeHeight: cachedExpandedShapeHeight
        )
    }

    private var notchTopCornerRadius: CGFloat {
        NotchShapeGeometry.topCornerRadius(state: state)
    }

    private var notchBottomCornerRadius: CGFloat {
        NotchShapeGeometry.bottomCornerRadius(openProgress: notchShapeOpenProgress)
    }

    private static let expandSpring = Animation.spring(response: 0.4, dampingFraction: 0.82)
    private static let collapseSpring = Animation.spring(response: 0.35, dampingFraction: 0.8)
    private static let contentFade = Animation.easeInOut(duration: 0.2)
    private static let expandedInactivityAutoHideDelay: TimeInterval = 10

    struct TransitionTiming: Equatable {
        let expandStartDelay: TimeInterval
        let contentRevealDelay: TimeInterval
        let collapseCompletionDelay: TimeInterval
    }

    static func transitionTiming(disableAnimations: Bool) -> TransitionTiming {
        disableAnimations
            ? TransitionTiming(expandStartDelay: 0, contentRevealDelay: 0, collapseCompletionDelay: 0)
            : TransitionTiming(expandStartDelay: 0.05, contentRevealDelay: 0.12, collapseCompletionDelay: 0.45)
    }

    private var transitionTiming: TransitionTiming {
        Self.transitionTiming(disableAnimations: disableAnimations)
    }

    static func initialAutoExpandedState(for manager: SessionManager) -> IslandState? {
        guard let session = manager.prioritizedInteractionSession else { return nil }

        switch session.status {
        case .waitingPermission:
            return .permission(session.id)
        case .waitingAnswer:
            return .question(session.id)
        case .waitingPlanReview:
            return .planReview(session.id)
        default:
            return nil
        }
    }

    static func initialIslandState(for manager: SessionManager) -> IslandState {
        initialAutoExpandedState(for: manager) ?? .collapsed
    }

    static func diagnosticsIslandState(for manager: SessionManager, currentState: IslandState) -> IslandState {
        if let interactionState = initialAutoExpandedState(for: manager) {
            return interactionState
        }

        switch currentState {
        case .expanded:
            return .expanded
        case .collapsed, .permission, .question, .planReview:
            return .collapsed
        }
    }

    @MainActor
    static func handleIslandStateChange(_ newState: IslandState, manager: SessionManager) {
        manager.currentIslandState = newState
        AppDelegate.shared?.refreshDiagnostics(islandState: manager.diagnosticsIslandState)
    }

    var body: some View {
        ZStack(alignment: .top) {
            UnevenRoundedRectangle(
                topLeadingRadius: notchTopCornerRadius,
                bottomLeadingRadius: notchBottomCornerRadius,
                bottomTrailingRadius: notchBottomCornerRadius,
                topTrailingRadius: notchTopCornerRadius,
                style: .continuous
            )
            .fill(pillFillColor)
            .shadow(
                color: .white.opacity(0.04 + 0.02 * notchShapeOpenProgress),
                radius: 10 + 10 * notchShapeOpenProgress,
                y: 3 + notchShapeOpenProgress
            )
            .overlay {
                UnevenRoundedRectangle(
                    topLeadingRadius: notchTopCornerRadius,
                    bottomLeadingRadius: notchBottomCornerRadius,
                    bottomTrailingRadius: notchBottomCornerRadius,
                    topTrailingRadius: notchTopCornerRadius,
                    style: .continuous
                )
                .strokeBorder(.white.opacity(pillStrokeOpacity), lineWidth: 0.5)
            }
            .frame(width: shapeWidth, height: shapeHeight)

            expandedContent
                .frame(width: expandedWidth > 0 ? expandedWidth : 420,
                       height: isExpanded ? nil : 0, alignment: .top)
                .clipped()
                .opacity(showContent ? 1 : 0)
                .allowsHitTesting(showContent)
                .zIndex(1)

            CollapsedPillView(obscuredByNotch: islandObscuredByNotch) {
                expand(to: .expanded)
            }
            .frame(width: shapeWidth, height: collapsedShapeHeight)
            .opacity(showContent ? 0 : 1)
            .allowsHitTesting(!showContent)
            .zIndex(0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .clipped()
        .contentShape(Rectangle())
        .accessibilityIdentifier(TestAccessibility.islandRoot)
        .onChange(of: expandedHeight) { _, _ in
            if case .expanded = state {
                cachedExpandedShapeHeight = max(collapsedShapeHeight + 1, expandedHeight)
            }
        }
        .onChange(of: state) { _, newState in
            if newState == .collapsed {
                cancelExpandedAutoHide()
            } else {
                markExpandedInteraction()
            }
        }
        .onChange(of: manager.activeSessions.count) { _, _ in
            reportSize()
        }
        .onChange(of: manager.visibleSessions.count) { oldCount, newCount in
            reportSize()
            if autoHideWhenNoActiveSessions {
                if newCount == 0 && oldCount > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        if manager.visibleSessions.isEmpty {
                            NSApp.windows.first(where: { $0 is NotchWindow })?.orderOut(nil)
                        }
                    }
                } else if newCount > 0 && oldCount == 0 {
                    NSApp.windows.first(where: { $0 is NotchWindow })?.orderFrontRegardless()
                }
            }
        }
        .onChange(of: state) { _, newState in
            Self.handleIslandStateChange(newState, manager: manager)
        }
        .onAppear {
            if let w = NSApp.windows.first(where: { $0 is NotchWindow }) as? NotchWindow {
                islandObscuredByNotch = w.isObscuredByPhysicalNotch()
            }
            let initialState = Self.initialIslandState(for: manager)
            state = initialState
            Self.handleIslandStateChange(initialState, manager: manager)
            if initialState != .collapsed {
                showContent = true
                if case .expanded = initialState {
                    cachedExpandedShapeHeight = max(collapsedShapeHeight + 1, expandedHeight)
                }
            }
            reportSize()
            startHoverPolling()
            let collapseToken = NotificationCenter.default.addObserver(forName: .xislandCollapse, object: nil, queue: .main) { _ in
                collapse()
            }
            let toggleToken = NotificationCenter.default.addObserver(forName: .xislandToggleActivityLog, object: nil, queue: .main) { _ in
                toggleActivityLog()
            }
            notificationTokens = [collapseToken, toggleToken]
        }
        .onDisappear {
            cancelExpandedAutoHide()
            for token in notificationTokens {
                NotificationCenter.default.removeObserver(token)
            }
            notificationTokens = []
        }
        .onChange(of: manager.hasInteraction) { _, hasInteraction in
            if hasInteraction {
                if collapseAnimating {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                        guard manager.hasInteraction else { return }
                        autoExpandForInteraction()
                    }
                } else {
                    autoExpandForInteraction()
                }
            } else if case .permission = state {
                collapse()
            } else if case .question = state {
                collapse()
            } else if case .planReview = state {
                collapse()
            }
        }
    }

    private func expand(to newState: IslandState) {
        guard !expandPending else { return }
        collapseGeneration += 1
        collapseAnimating = false
        expandPending = true
        let timing = transitionTiming
        let target = targetSize(for: newState)
        if case .expanded = newState {
            let count = manager.visibleSessions.count
            let listH = min(CGFloat(count) * 80 + 30, 480)
            cachedExpandedShapeHeight = Self.expandedPanelHeaderHeight + listH + Self.expandedPanelBottomInset
        }
        onSizeChange?(target.width, target.height, true)
        let runExpansion = {
            if disableAnimations {
                self.isHovering = false
                self.state = newState
                self.showContent = true
            } else {
                withAnimation(Self.expandSpring) {
                    self.isHovering = false
                    self.state = newState
                }
                withAnimation(Self.contentFade.delay(timing.contentRevealDelay)) {
                    self.showContent = true
                }
            }
            self.expandPending = false
        }

        if timing.expandStartDelay == 0 {
            runExpansion()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + timing.expandStartDelay) {
                runExpansion()
            }
        }
    }

    private func collapse() {
        collapseGeneration += 1
        let generation = collapseGeneration
        let timing = transitionTiming
        lastCollapseAt = Date()
        collapseAnimating = true
        if disableAnimations {
            showContent = false
            state = .collapsed
        } else {
            withAnimation(Self.collapseSpring) {
                showContent = false
                state = .collapsed
            }
        }
        // Defer NSWindow frame sync to the next main runloop turn so we are not inside SwiftUI's
        // animation/layout commit (reduces AppKit exceptions in _reallySetFrame: during collapse).
        let finishCollapse = {
            guard generation == self.collapseGeneration, self.state == .collapsed else { return }
            let w = self.pillWidth
            let h = self.collapsedOuterHeight
            DispatchQueue.main.async {
                guard generation == self.collapseGeneration, self.state == .collapsed else { return }
                if let window = NSApp.windows.first(where: { $0 is NotchWindow }) as? NotchWindow {
                    window.resizeToFitCollapse(contentWidth: w, contentHeight: h)
                }
                self.collapseAnimating = false
            }
        }

        if timing.collapseCompletionDelay == 0 {
            finishCollapse()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + timing.collapseCompletionDelay) {
                finishCollapse()
            }
        }
    }

    private func reportSize() {
        guard !collapseAnimating else { return }
        onSizeChange?(contentWidth, contentHeight, true)
    }

    private func targetSize(for state: IslandState) -> (width: CGFloat, height: CGFloat) {
        let w: CGFloat
        let h: CGFloat
        switch state {
        case .collapsed:
            w = pillWidth
            h = collapsedOuterHeight
        case .expanded:
            let count = manager.visibleSessions.count
            let listH = min(CGFloat(count) * 80 + 30, 480)
            w = 420
            h = Self.expandedPanelHeaderHeight + listH + Self.expandedPanelBottomInset
        case .permission(let id):
            // Must not use `expandedHeight` here: `expand(to:)` runs before `state` updates, so
            // `expandedHeight` would still reflect `.collapsed` (0) and resize the window to ~8pt tall.
            w = 440
            h = permissionExpandedTotalHeight(sessionId: id) + 8
        case .question(let id):
            w = 440
            h = questionExpandedTotalHeight(sessionId: id) + 8
        case .planReview:
            w = 500; h = 480
        }
        return (w, h)
    }

    /// Toolbar row in `expandedHeader` (~10+10 vertical padding + ~28 controls).
    private static let expandedPanelHeaderHeight: CGFloat = 48
    /// Space between session list / cards and the bottom rounded edge of the expanded panel.
    private static let expandedPanelBottomInset: CGFloat = 16
    /// Spans slightly past the camera housing; kept compact (competitor-style bar).
    private static let collapsedPillWidthNotched: CGFloat = 276
    /// Bottom-only rounding when docked under the notch (top edge flush with screen).
    private var pillWidth: CGFloat {
        if islandObscuredByNotch {
            return Self.collapsedPillWidthNotched
        }
        let n = manager.visibleSessions.count
        if n == 0 { return 180 }
        let icon: CGFloat = 22
        let gap: CGFloat = 8
        let horizontalPadding: CGFloat = 40
        let w = horizontalPadding + CGFloat(n) * icon + CGFloat(max(0, n - 1)) * gap
        return min(max(w, 160), 420)
    }

    @ViewBuilder
    private var expandedContent: some View {
        VStack(spacing: 0) {
            expandedHeader

            switch state {
            case .expanded:
                SessionListView(onJump: {
                    expandedByHover = false
                    jumpMouseLocation = NSEvent.mouseLocation
                    collapse()
                })

                if activityLogExpanded {
                    activityLogContent
                }

            case .permission(let id):
                if let session = manager.sessions.first(where: { $0.id == id }) {
                    PermissionApprovalView(session: session) {
                        collapseAfterDelay()
                    }
                }

            case .question(let id):
                if let session = manager.sessions.first(where: { $0.id == id }) {
                    QuestionAnswerView(session: session) {
                        collapseAfterDelay()
                    }
                    .id(session.pendingQuestion?.id)
                }

            case .planReview(let id):
                if let session = manager.sessions.first(where: { $0.id == id }) {
                    PlanReviewView(session: session) {
                        collapseAfterDelay()
                    }
                }

            case .collapsed:
                EmptyView()
            }

            if case .expanded = state, !quotaTracker.quotas.isEmpty {
                quotaPills
            }
        }
        .padding(.bottom, Self.expandedPanelBottomInset)
        .simultaneousGesture(TapGesture().onEnded {
            markExpandedInteraction()
        })
        .simultaneousGesture(DragGesture(minimumDistance: 1).onChanged { _ in
            markExpandedInteraction(throttled: true)
        })
    }

    private var quotaPills: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(quotaTracker.quotas, id: \.provider) { quota in
                    if let (label, value, color) = quotaDisplayInfo(for: quota) {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(color)
                                .frame(width: 5, height: 5)
                            Text(label)
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(.white.opacity(0.55))
                            Text(value)
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .foregroundStyle(color)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(color.opacity(0.12))
                        )
                    }
                }
            }
            .padding(.horizontal, 12)
        }
        .padding(.top, 8)
    }

    /// Returns (providerLabel, valueText, accentColor) for a quota entry.
    private func quotaDisplayInfo(for quota: QuotaInfo) -> (String, String, Color)? {
        switch quota.provider {
        case "Anthropic":
            if let remaining = quota.tokensRemaining {
                return ("Claude", formatTokens(remaining), Color(red: 0.85, green: 0.45, blue: 0.25))
            }
        case "OpenAI":
            if let used = quota.tokensRemaining {
                return ("Codex", formatTokens(used), Color(red: 0.2, green: 0.8, blue: 0.4))
            }
        case "Kimi":
            // balance from Moonshot API is in approximate token count
            if let tokens = quota.tokensRemaining, tokens > 0 {
                return ("Kimi", "¥\(tokens / 100)", Color(red: 0.95, green: 0.35, blue: 0.45))
            }
        case "DeepSeek":
            if let tokens = quota.tokensRemaining {
                return tokens > 0
                    ? ("DeepSeek", formatTokens(tokens), Color(red: 0.25, green: 0.75, blue: 0.55))
                    : ("DeepSeek", "Exhausted", Color.red.opacity(0.7))
            }
        case "GLM":
            if let remaining = quota.requestsRemaining {
                return remaining > 0
                    ? ("GLM", "Active", Color(red: 0.25, green: 0.45, blue: 0.95))
                    : ("GLM", "N/A", Color.red.opacity(0.7))
            }
        default:
            break
        }
        return nil
    }

    private func formatTokens(_ count: Int) -> String {
        if count < 1000 { return "\(count)" }
        if count < 1_000_000 { return String(format: "%.1fK", Double(count) / 1000) }
        return String(format: "%.2fM", Double(count) / 1_000_000)
    }

    private var expandedHeader: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
            Button {
                markExpandedInteraction()
                audio.isMuted.toggle()
            } label: {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(audio.isMuted ? .white.opacity(0.25) : .white.opacity(0.72))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

            Button {
                markExpandedInteraction()
                openSettingsWindow()
            } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.62))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            Spacer()

            Group {
                if let session = interactionSession {
                    Text(session.displayTitle)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                        .truncationMode(.tail)
                } else {
                    Text("\(manager.activeSessions.count)\(L10n.activeSessions)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.3))
                }
            }

            Button {
                markExpandedInteraction()
                expandedByHover = false
                collapse()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white.opacity(0.4))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var interactionSession: AgentSession? {
        switch state {
        case .permission(let id), .question(let id), .planReview(let id):
            return manager.sessions.first(where: { $0.id == id })
        case .collapsed, .expanded:
            return nil
        }
    }

    private func openSettingsWindow() {
        AppDelegate.shared?.openPreferences()
    }

    private func isAgentTerminalFocused() -> Bool {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return false }
        let terminalBundleIds = [
            "com.googlecode.iterm2", "com.apple.Terminal",
            "com.mitchellh.ghostty", "dev.warp.Warp-Stable",
            "net.kovidgoyal.kitty",
            "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92",
            "com.codeium.windsurf", "com.trae.app", "cn.trae.app"
        ]
        return terminalBundleIds.contains(frontApp.bundleIdentifier ?? "")
    }

    private func autoExpandForInteraction() {
        guard let targetState = Self.initialAutoExpandedState(for: manager) else { return }

        if !isExpanded {
            expand(to: .expanded)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                guard manager.hasInteraction else { return }
                expand(to: targetState)
            }
            return
        }

        expand(to: targetState)
    }

    private func cancelExpandedAutoHide() {
        expandedAutoHideWorkItem?.cancel()
        expandedAutoHideWorkItem = nil
    }

    private func markExpandedInteraction(throttled: Bool = false) {
        guard isExpanded else { return }

        let now = Date()
        if throttled, now.timeIntervalSince(lastExpandedInteractionMarkAt) < 0.4 {
            return
        }
        lastExpandedInteractionMarkAt = now
        lastExpandedInteractionAt = now
        scheduleExpandedAutoHide()
    }

    private func scheduleExpandedAutoHide() {
        cancelExpandedAutoHide()
        guard isExpanded else { return }

        let workItem = DispatchWorkItem {
            guard self.isExpanded else { return }
            let elapsed = Date().timeIntervalSince(self.lastExpandedInteractionAt)
            guard elapsed >= Self.expandedInactivityAutoHideDelay else {
                self.scheduleExpandedAutoHide()
                return
            }
            self.expandedByHover = false
            self.collapse()
        }
        expandedAutoHideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.expandedInactivityAutoHideDelay, execute: workItem)
    }

    private func startHoverPolling() {
        stopHoverPolling()
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            Task { @MainActor in
                pollMousePosition()
            }
        }
    }

    private func stopHoverPolling() {
        hoverTimer?.invalidate()
        hoverTimer = nil
    }

    private func pollMousePosition() {
        guard let window = NSApp.windows.first(where: { $0 is NotchWindow }) as? NotchWindow else { return }
        guard !window.isDragging else { return }

        if !window.isVisible && (manager.hasInteraction || !manager.visibleSessions.isEmpty) {
            window.orderFrontRegardless()
        }

        let obscured = window.isObscuredByPhysicalNotch()
        if obscured != islandObscuredByNotch {
            islandObscuredByNotch = obscured
            reportSize()
        }

        let mouse = NSEvent.mouseLocation
        var hitFrame = window.frame
        hitFrame.size.height += 2
        let inside = hitFrame.contains(mouse)

        if inside && !isExpanded {
            guard Date().timeIntervalSince(lastCollapseAt) > 1.2 else { return }
            if let savedPos = jumpMouseLocation {
                let dx = mouse.x - savedPos.x
                let dy = mouse.y - savedPos.y
                if dx * dx + dy * dy < 9 { return }
                jumpMouseLocation = nil
            }
            if !manager.visibleSessions.isEmpty {
                if smartSuppression && isAgentTerminalFocused() { return }
                expandedByHover = true
                expandedAt = Date()
                expand(to: .expanded)
            } else if !isHovering {
                if disableAnimations {
                    isHovering = true
                } else {
                    withAnimation(.easeInOut(duration: 0.2)) { isHovering = true }
                }
            }
        } else if !inside && isHovering && !isExpanded {
            if disableAnimations {
                isHovering = false
            } else {
                withAnimation(.easeInOut(duration: 0.2)) { isHovering = false }
            }
        } else if ExpandedAutoCollapsePolicy.shouldCollapseOnMouseExit(
            isPointerInside: inside,
            state: state,
            expandedByHover: expandedByHover,
            visibleSessionCount: manager.visibleSessions.count,
            elapsedSinceExpand: Date().timeIntervalSince(expandedAt)
        ) {
            collapse()
            expandedByHover = false
        }
    }

    private func collapseAfterDelay() {
        guard autoCollapseDelay > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + autoCollapseDelay) {
            if !manager.hasInteraction {
                expandedByHover = false
                collapse()
            }
        }
    }

    private var activityLogContent: some View {
        let allEvents = manager.sessions
            .flatMap { session in
                session.events.map { (session: session, event: $0) }
            }
            .sorted { $0.event.timestamp > $1.event.timestamp }
            .prefix(30)

        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                HStack(spacing: 4) {
                    Image(systemName: "list.bullet.rectangle")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.4))
                    Text("Activity Log")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.6))
                }
                Spacer()
                Text("⌘O")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.3))
            }

            if allEvents.isEmpty {
                Text("No activity yet")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.2))
                    .padding(.top, 4)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(allEvents), id: \.event.id) { item in
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(item.session.agentType.color.opacity(0.6))
                                    .frame(width: 4, height: 4)
                                Text(item.session.agentType.shortName)
                                    .font(.system(size: 9, weight: .medium))
                                    .foregroundStyle(item.session.agentType.color.opacity(0.7))
                                Text(item.event.displayName)
                                    .font(.system(size: 9))
                                    .foregroundStyle(.white.opacity(0.5))
                                Text(item.event.summary)
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundStyle(.white.opacity(0.3))
                                    .lineLimit(1)
                                Spacer()
                                Text(item.event.timestamp, style: .time)
                                    .font(.system(size: 8, design: .monospaced))
                                    .foregroundStyle(.white.opacity(0.2))
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(maxHeight: 100)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(IslandStyle.insetFill)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private func toggleActivityLog() {
        activityLogExpanded.toggle()
        reportSize()
    }
}
