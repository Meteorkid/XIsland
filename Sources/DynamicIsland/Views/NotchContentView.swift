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
    @Environment(ThemeManager.self) private var themeManager
    @State private var islandObscuredByNotch = false
    @State private var state: IslandState = .collapsed
    @State private var isHovering = false
    @State private var isHoveringPill = false
    @State private var jellyTrigger = false
    @State private var jellySettled = false
    @State private var expandedByHover = false
    @State private var expandedAt: Date = .distantPast
    @State private var showContent = false
    @State private var jumpMouseLocation: CGPoint?
    @State private var hoverTimer: Timer?
    @State private var lastCollapseAt: Date = .distantPast
    @State private var expandPending = false
    @State private var collapseAnimating = false
    @State private var collapseGeneration = 0
    @State private var previousMouseY: CGFloat = 0
    @State private var jellyGeneration: UInt = 0
    @State private var magneticOffset: CGSize = .zero
    @State private var lastScrollExpandAt: Date = .distantPast
    @State private var expandedAutoHideWorkItem: DispatchWorkItem?
    @State private var lastExpandedInteractionAt: Date = .distantPast
    @State private var lastExpandedInteractionMarkAt: Date = .distantPast
    /// Last known expanded `shapeHeight` (black panel), used to interpolate notch corner radii with `shapeHeight` during spring (avoids boolean snap).
    @State private var cachedExpandedShapeHeight: CGFloat = 220
    @State var activityLogExpanded = false
    @State private var notificationTokens: [NSObjectProtocol] = []
    @AppStorage("disableAnimations") private var disableAnimations = false
    @AppStorage("reduceMotion") private var reduceMotion = false
    @AppStorage("animationIntensity") private var animationIntensity = IslandAnimationIntensity.defaultValue.rawValue
    @AppStorage("jellyIntensity") private var jellyIntensity = IslandJellyIntensity.defaultValue.rawValue
    @AppStorage("autoCollapseDelay") private var autoCollapseDelay = 3.0
    /// Seconds after last interaction while expanded before auto-collapsing; 0 disables.
    @AppStorage("expandedInactivityAutoHideDelay") private var expandedInactivityAutoHideDelay = 10.0
    /// Seconds pointer must stay outside before collapse (hover-expand or empty panel).
    @AppStorage("hoverExitCollapseDelay") private var hoverExitCollapseDelay = 0.5
    @AppStorage("hoverToExpandPanel") private var hoverToExpandPanel = false
    @AppStorage("smartSuppression") private var smartSuppression = true
    @AppStorage("autoHideWhenNoActiveSessions") private var autoHideWhenNoActiveSessions = false
    @AppStorage("panelWidth") private var panelWidth = 420.0
    @AppStorage("panelMaxHeight") private var panelMaxHeight = 480.0
    @AppStorage("showActivityTicker") private var showActivityTicker = true
    @AppStorage("tickerContentMode") private var tickerContentMode = CollapsedTickerContentMode.defaultValue.rawValue
    @AppStorage("tickerSpeed") private var tickerSpeed = 25.0
    var onSizeChange: ((CGFloat, CGFloat, Bool) -> Void)?

    // MARK: - IslandSizeCalculator delegates

    private static let magneticMaxOffset: CGFloat = 8
    private static let magneticRange: CGFloat = 80
    private static let hoverPollingInterval: TimeInterval = 1.0 / 60.0

    private var collapsedShapeHeight: CGFloat { IslandSizeCalculator.collapsedShapeHeight }
    private let tickerLineHeight: CGFloat = 18
    private var showCollapsedTicker: Bool { showActivityTicker && !isExpanded }
    private var collapsedOuterHeight: CGFloat {
        collapsedShapeHeight + (showCollapsedTicker ? tickerLineHeight + 4 : 0)
    }

    private var isExpanded: Bool { state != .collapsed }

    private var contentWidth: CGFloat {
        isExpanded ? expandedWidth : pillWidth
    }

    private var contentHeight: CGFloat {
        isExpanded ? expandedHeight : collapsedOuterHeight
    }

    private var expandedWidth: CGFloat {
        IslandSizeCalculator.expandedWidth(for: state, panelWidth: panelWidth)
    }

    private var expandedHeight: CGFloat {
        IslandSizeCalculator.expandedHeight(
            for: state,
            visibleSessionCount: manager.visibleSessions.count,
            panelMaxHeight: panelMaxHeight,
            activityLogExpanded: activityLogExpanded
        )
    }

    private var shapeWidth: CGFloat {
        isExpanded ? expandedWidth : pillWidth
    }

    private var shapeHeight: CGFloat {
        isExpanded ? expandedHeight : collapsedOuterHeight
    }

    private var pillFillColor: Color { IslandStyle.surface(for: themeManager.resolvedScheme) }

    private var pillStrokeOpacity: CGFloat { IslandStyle.strokeOpacity(for: themeManager.resolvedScheme) }

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

    struct HoverJellyScale: Equatable {
        let xPop: CGFloat
        let xSettle: CGFloat
        let yPop: CGFloat
        let ySettle: CGFloat
    }

    private var resolvedAnimationIntensity: IslandAnimationIntensity {
        Self.resolvedAnimationIntensity(rawValue: animationIntensity, reduceMotion: reduceMotion)
    }

    private var resolvedJellyIntensity: IslandJellyIntensity {
        Self.resolvedJellyIntensity(rawValue: jellyIntensity)
    }

    private var hoverJellyScale: HoverJellyScale {
        Self.hoverJellyScale(for: resolvedJellyIntensity)
    }

    private var expandSpring: Animation {
        Self.expandSpring(for: resolvedAnimationIntensity)
    }

    private var collapseSpring: Animation {
        Self.collapseSpring(for: resolvedAnimationIntensity)
    }

    private var contentFade: Animation {
        Self.contentFade(for: resolvedAnimationIntensity)
    }

    private var resolvedTickerContentMode: CollapsedTickerContentMode {
        Self.resolvedTickerContentMode(rawValue: tickerContentMode)
    }

    struct TransitionTiming: Equatable {
        let expandStartDelay: TimeInterval
        let contentRevealDelay: TimeInterval
        let collapseCompletionDelay: TimeInterval
    }

    static func resolvedAnimationIntensity(rawValue: String, reduceMotion: Bool) -> IslandAnimationIntensity {
        IslandAnimationIntensity.resolve(rawValue: rawValue, reduceMotion: reduceMotion)
    }

    static func resolvedJellyIntensity(rawValue: String) -> IslandJellyIntensity {
        IslandJellyIntensity.resolve(rawValue: rawValue)
    }

    static func resolvedTickerContentMode(rawValue: String) -> CollapsedTickerContentMode {
        CollapsedTickerContentMode.resolve(rawValue: rawValue)
    }

    static func hoverJellyScale(for intensity: IslandJellyIntensity) -> HoverJellyScale {
        switch intensity {
        case .low:
            return .init(xPop: 0.97, xSettle: 0.99, yPop: 1.10, ySettle: 1.03)
        case .medium:
            return .init(xPop: 0.94, xSettle: 0.98, yPop: 1.25, ySettle: 1.08)
        case .high:
            return .init(xPop: 0.90, xSettle: 0.96, yPop: 1.40, ySettle: 1.12)
        }
    }

    static func shouldTriggerHoverJelly(
        isPointerInside: Bool,
        isExpanded: Bool,
        collapseAnimating: Bool,
        previousMouseY: CGFloat,
        currentMouseY: CGFloat
    ) -> Bool {
        isPointerInside && !isExpanded && !collapseAnimating && previousMouseY < currentMouseY
    }

    static func magneticOffset(
        mouseLocation: CGPoint,
        windowFrame: CGRect,
        collapsedShapeHeight: CGFloat,
        isExpanded: Bool,
        collapseAnimating: Bool
    ) -> CGSize {
        guard !isExpanded, !collapseAnimating else { return .zero }

        let pillCenterX = windowFrame.midX
        let pillCenterY = windowFrame.minY + collapsedShapeHeight / 2
        let dx = mouseLocation.x - pillCenterX
        let dy = mouseLocation.y - pillCenterY
        let distance = sqrt(dx * dx + dy * dy)

        guard distance < magneticRange, distance > 1 else {
            return .zero
        }

        let strength = 1.0 - distance / magneticRange
        let offsetX = dx * strength * 0.15
        let clamped = max(-magneticMaxOffset, min(magneticMaxOffset, offsetX))
        return CGSize(width: clamped, height: 0)
    }

    static func transitionTiming(
        disableAnimations: Bool,
        intensity: IslandAnimationIntensity = .medium
    ) -> TransitionTiming {
        guard !disableAnimations else {
            return TransitionTiming(expandStartDelay: 0, contentRevealDelay: 0, collapseCompletionDelay: 0)
        }

        switch intensity {
        case .low:
            return TransitionTiming(expandStartDelay: 0.02, contentRevealDelay: 0.08, collapseCompletionDelay: 0.28)
        case .medium:
            return TransitionTiming(expandStartDelay: 0.05, contentRevealDelay: 0.12, collapseCompletionDelay: 0.45)
        case .high:
            return TransitionTiming(expandStartDelay: 0.07, contentRevealDelay: 0.16, collapseCompletionDelay: 0.55)
        }
    }

    private var transitionTiming: TransitionTiming {
        Self.transitionTiming(disableAnimations: disableAnimations, intensity: resolvedAnimationIntensity)
    }

    private static func expandSpring(for intensity: IslandAnimationIntensity) -> Animation {
        switch intensity {
        case .low:
            return .spring(response: 0.28, dampingFraction: 0.92)
        case .medium:
            return .spring(response: 0.4, dampingFraction: 0.82)
        case .high:
            return .spring(response: 0.5, dampingFraction: 0.74)
        }
    }

    private static func collapseSpring(for intensity: IslandAnimationIntensity) -> Animation {
        switch intensity {
        case .low:
            return .spring(response: 0.24, dampingFraction: 0.9)
        case .medium:
            return .spring(response: 0.35, dampingFraction: 0.8)
        case .high:
            return .spring(response: 0.44, dampingFraction: 0.72)
        }
    }

    private static func contentFade(for intensity: IslandAnimationIntensity) -> Animation {
        switch intensity {
        case .low:
            return .easeInOut(duration: 0.14)
        case .medium:
            return .easeInOut(duration: 0.2)
        case .high:
            return .easeInOut(duration: 0.28)
        }
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

    static func activityTickerText(for session: AgentSession?) -> String {
        guard let session else { return L10n.noActivity }

        let prefix = session.agentType.shortName

        if let tool = session.currentTool, !tool.isEmpty {
            return "\(prefix) · \(L10n.toolRunning(tool))"
        }

        if let lastEvent = session.events.last {
            if lastEvent.isComplete {
                return "\(prefix) · \(lastEvent.displayName): \(lastEvent.summary)"
            }
            return "\(prefix) · \(L10n.toolRunning(lastEvent.displayName))"
        }

        if !session.statusText.isEmpty {
            return "\(prefix) · \(session.statusText)"
        }

        return "\(prefix) · \(session.status.displayName)"
    }

    static func projectTickerText(for session: AgentSession?) -> String {
        guard let session else { return L10n.noActivity }
        return "\(session.agentType.shortName) · \(session.workspaceName)"
    }

    static func collapsedTickerText(
        for session: AgentSession?,
        mode: CollapsedTickerContentMode,
        now: Date = Date()
    ) -> String {
        switch mode {
        case .activity:
            return activityTickerText(for: session)
        case .project:
            return projectTickerText(for: session)
        case .automatic:
            let rotationIndex = Int(now.timeIntervalSince1970 / CollapsedTickerContentMode.rotationInterval) % 2
            if rotationIndex == 0 {
                return activityTickerText(for: session)
            }
            return projectTickerText(for: session)
        }
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
                color: IslandStyle.shadowColor(for: themeManager.resolvedScheme)
                    .opacity(IslandStyle.shadowOpacity(for: themeManager.resolvedScheme) + 0.02 * notchShapeOpenProgress),
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
                .strokeBorder(
                    IslandStyle.strokeColor(for: themeManager.resolvedScheme)
                        .opacity(pillStrokeOpacity + (isHoveringPill ? 0.15 : 0)),
                    lineWidth: 0.5
                )
            }
            .scaleEffect(
                x: jellyTrigger ? (jellySettled ? hoverJellyScale.xSettle : hoverJellyScale.xPop) : 1.0,
                y: jellyTrigger ? (jellySettled ? hoverJellyScale.ySettle : hoverJellyScale.yPop) : 1.0
            )
            .frame(width: shapeWidth, height: shapeHeight)

            expandedContent
                .frame(width: expandedWidth > 0 ? expandedWidth : panelWidth,
                       height: isExpanded ? expandedHeight : 0, alignment: .top)
                .clipped()
                .opacity(showContent ? 1 : 0)
                .allowsHitTesting(showContent)
                .zIndex(1)

            ZStack(alignment: .top) {
                CollapsedPillView(obscuredByNotch: islandObscuredByNotch, isExpanded: isExpanded) {
                    expand(to: .expanded)
                }
                .frame(width: shapeWidth, height: collapsedShapeHeight)

                if showCollapsedTicker {
                    collapsedTickerView
                }
            }
            .frame(width: shapeWidth, height: collapsedOuterHeight)
            .offset(magneticOffset)
            .opacity(showContent ? 0 : 1)
            .allowsHitTesting(!showContent)
            .zIndex(0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .clipped()
        .contentShape(Rectangle())
        .contextMenu {
            Button {
                audio.isMuted.toggle()
            } label: {
                Label(audio.isMuted ? L10n.unmute : L10n.soundMute,
                      systemImage: audio.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
            }
            Divider()
            Button(L10n.prefsEllipsis) {
                openSettingsWindow()
            }
            if isExpanded {
                Divider()
                Button(L10n.dismissAll) {
                    for s in manager.visibleSessions {
                        manager.dismissSession(s)
                    }
                }
            }
            Divider()
            Button(L10n.quitApp) {
                NSApp.terminate(nil)
            }
        }
        .accessibilityIdentifier(TestAccessibility.islandRoot)
        .preferredColorScheme(themeManager.resolvedScheme)
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
            Self.handleIslandStateChange(newState, manager: manager)
        }
        .onChange(of: expandedInactivityAutoHideDelay) { _, _ in
            if isExpanded {
                markExpandedInteraction()
            }
        }
        .onChange(of: manager.activeSessions.count) { _, _ in
            reportSize()
        }
        .onChange(of: showActivityTicker) { _, _ in
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
                    if let window = NSApp.windows.first(where: { $0 is NotchWindow }) as? NotchWindow,
                       !window.isHiddenByIslandSwitch {
                        window.orderFrontRegardless()
                    }
                }
            }
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
        .onReceive(NotificationCenter.default.publisher(for: .xislandScrollDown)) { _ in
            let now = Date()
            let cooldown: TimeInterval = 0.5
            guard !isExpanded,
                  !collapseAnimating,
                  now.timeIntervalSince(lastScrollExpandAt) > cooldown
            else {
                return
            }

            lastScrollExpandAt = now
            expand(to: .expanded)
        }
        .onDisappear {
            stopHoverPolling()
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
            }
        }
    }

    @ViewBuilder
    private var collapsedTickerView: some View {
        if resolvedTickerContentMode == .automatic {
            TimelineView(.periodic(from: .now, by: CollapsedTickerContentMode.rotationInterval)) { context in
                tickerMarquee(
                    text: Self.collapsedTickerText(
                        for: manager.latestMessagedVisibleSession,
                        mode: resolvedTickerContentMode,
                        now: context.date
                    )
                )
            }
        } else {
            tickerMarquee(
                text: Self.collapsedTickerText(
                    for: manager.latestMessagedVisibleSession,
                    mode: resolvedTickerContentMode
                )
            )
        }
    }

    private func tickerMarquee(text: String) -> some View {
        MarqueeText(
            text: text,
            font: .system(size: 10, weight: .medium),
            availableWidth: shapeWidth - 28,
            speed: tickerSpeed
        )
        .foregroundStyle(IslandStyle.tertiaryText(for: themeManager.resolvedScheme))
        .frame(width: shapeWidth, height: tickerLineHeight)
        .offset(y: collapsedShapeHeight - 8)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private func expand(to newState: IslandState) {
        guard !expandPending else { return }
        collapseGeneration += 1
        collapseAnimating = false
        expandPending = true
        clearHoverJellyState(animated: false)

        // 同步状态到窗口层
        if let window = NSApp.windows.first(where: { $0 is NotchWindow }) as? NotchWindow {
            window.islandState = newState
        }

        let timing = transitionTiming
        let target = targetSize(for: newState)
        if case .expanded = newState {
            cachedExpandedShapeHeight = IslandSizeCalculator.expandedPanelShapeHeight(
                visibleSessionCount: manager.visibleSessions.count,
                panelMaxHeight: panelMaxHeight
            )
        }
        onSizeChange?(target.width, target.height, true)
        let runExpansion = {
            if disableAnimations {
                self.isHovering = false
                self.state = newState
                self.showContent = true
            } else {
                withAnimation(expandSpring) {
                    self.isHovering = false
                    self.state = newState
                }
                withAnimation(contentFade.delay(timing.contentRevealDelay)) {
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
        clearHoverJellyState(animated: false)
        if disableAnimations {
            showContent = false
            state = .collapsed
        } else {
            withAnimation(collapseSpring) {
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
                    window.islandState = self.state
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
        IslandSizeCalculator.targetSize(
            for: state,
            visibleSessionCount: manager.visibleSessions.count,
            panelWidth: panelWidth,
            panelMaxHeight: panelMaxHeight
        )
    }

    /// Toolbar row in `expandedHeader` (~10+10 vertical padding + ~28 controls).
    private static let expandedPanelHeaderHeight: CGFloat = IslandSizeCalculator.expandedPanelHeaderHeight
    /// Space between session list / cards and the bottom rounded edge of the expanded panel.
    private static let expandedPanelBottomInset: CGFloat = IslandSizeCalculator.expandedPanelBottomInset
    /// Spans slightly past the camera housing; kept compact (competitor-style bar).
    private static let collapsedPillWidthNotched: CGFloat = 276
    /// Bottom-only rounding when docked under the notch (top edge flush with screen).
    private var pillWidth: CGFloat {
        IslandSizeCalculator.pillWidth(
            islandObscuredByNotch: islandObscuredByNotch,
            visibleSessionCount: manager.visibleSessions.count
        )
    }

    @ViewBuilder
    private var expandedContent: some View {
        VStack(spacing: 0) {
            expandedHeader

            switch state {
            case .expanded, .permission, .question, .planReview:
                // 待处理任务（question/permission/planReview）已在 SessionListView 顶部内联显示
                SessionListView(onJump: {
                    // 跳转后保持面板打开——鼠标仍在面板上，auto-collapse 会在鼠标移出时自然触发
                })

                if activityLogExpanded {
                    activityLogContent
                }

            case .collapsed:
                EmptyView()
            }

            if case .expanded = state, !quotaTracker.quotas.isEmpty {
                quotaPills
            }
        }
        .padding(.bottom, IslandSizeCalculator.expandedPanelBottomInset)
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
                                .foregroundStyle(IslandStyle.secondaryText)
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
                    Image(systemName: audio.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(audio.isMuted
                            ? IslandStyle.tertiaryText(for: themeManager.resolvedScheme)
                            : IslandStyle.secondaryText)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(audio.isMuted ? L10n.unmute : L10n.soundMute)

            Button {
                markExpandedInteraction()
                openSettingsWindow()
            } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(IslandStyle.secondaryText)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.prefsEllipsis)
            }

            Spacer()

            Group {
                if let session = interactionSession {
                    Text(session.displayTitle)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(IslandStyle.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                } else {
                    Text("\(manager.activeSessions.count)\(L10n.activeSessions)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(IslandStyle.tertiaryText(for: themeManager.resolvedScheme))
                }
            }

            Button {
                markExpandedInteraction()
                expandedByHover = false
                collapse()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(IslandStyle.tertiaryText(for: themeManager.resolvedScheme))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.dismissAll)
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
        let delay = expandedInactivityAutoHideDelay
        guard delay > 0 else { return }

        let workItem = DispatchWorkItem {
            guard self.isExpanded else { return }
            let elapsed = Date().timeIntervalSince(self.lastExpandedInteractionAt)
            guard elapsed >= delay else {
                self.scheduleExpandedAutoHide()
                return
            }
            self.expandedByHover = false
            self.collapse()
        }
        expandedAutoHideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func startHoverPolling() {
        stopHoverPolling()
        hoverTimer = Timer.scheduledTimer(withTimeInterval: Self.hoverPollingInterval, repeats: true) { _ in
            pollMousePosition()
        }
    }

    private func stopHoverPolling() {
        hoverTimer?.invalidate()
        hoverTimer = nil
    }

    private func pollMousePosition() {
        guard let window = NSApp.windows.first(where: { $0 is NotchWindow }) as? NotchWindow else { return }
        guard !window.isDragging else { return }

        if !window.isHiddenByIslandSwitch,
           !window.isVisible,
           (manager.hasInteraction || !manager.visibleSessions.isEmpty) {
            window.orderFrontRegardless()
        }

        let obscured = window.isObscuredByPhysicalNotch()
        if obscured != islandObscuredByNotch {
            islandObscuredByNotch = obscured
            reportSize()
        }

        let mouse = NSEvent.mouseLocation
        var hitFrame = window.frame
        // 展开时用更大的命中区域覆盖整个面板+药丸区域，防止鼠标在面板与药丸之间移动时误触发收起
        if isExpanded {
            // 从展开面板底部向下扩展 20px（给鼠标移出时留余量），向上覆盖到药丸区域。
            // 不使用 visibleFrame 裁剪高度——药丸在菜单栏区域内（origin.y > visibleFrame.maxY），
            // visibleFrame 裁剪会把 hitFrame 压缩到 ~1px，与收起状态的问题相同。
            hitFrame.origin.y -= 20
            hitFrame.size.height = expandedHeight + 40
            // 仅裁剪左右（不裁剪顶部/底部），确保命中区域覆盖药丸
            if let screen = window.screen?.visibleFrame {
                hitFrame.origin.x = max(hitFrame.origin.x, screen.minX)
                hitFrame.size.width = min(hitFrame.maxX, screen.maxX) - hitFrame.origin.x
            }
        } else {
            // 收起状态下 hit frame 垂直扩展到屏幕顶部，覆盖药丸区域。
            // 药丸面板绘制在菜单栏内，鼠标移到药丸上都应能触发展开。
            // 不使用 visibleFrame——它不含菜单栏，裁剪会将 hitFrame 压缩到 ~1px。
            // +1 补偿 NSRect.contains 上界排他（y < maxY）：鼠标恰好在 screenTop 时不被排除。
            if let screen = window.screen?.frame {
                let screenTop = screen.maxY
                hitFrame.size.height += max(0, screenTop - hitFrame.maxY) + 1
            }
        }
        var inside = hitFrame.contains(mouse)

        // collapse 动画期间（state 已是 collapsed 但 window.frame 尚未缩回），
        // 强制 inside = false，确保 isHovering 能被及时清除，避免 0.75s 状态不一致。
        if collapseAnimating { inside = false }

        if Self.shouldTriggerHoverJelly(
            isPointerInside: inside,
            isExpanded: isExpanded,
            collapseAnimating: collapseAnimating,
            previousMouseY: previousMouseY,
            currentMouseY: mouse.y
        ) {
            if !isHoveringPill, !disableAnimations {
                isHoveringPill = true
                jellySettled = false
                jellyGeneration += 1
                let generation = jellyGeneration
                withAnimation(.spring(response: 0.5, dampingFraction: 0.3)) {
                    jellyTrigger = true
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [self] in
                    guard generation == self.jellyGeneration else { return }
                    withAnimation(.spring(response: 0.45, dampingFraction: 0.4)) {
                        self.jellySettled = true
                    }
                }
            }
        } else if !inside || isExpanded || collapseAnimating {
            clearHoverJellyState()
        }

        previousMouseY = mouse.y

        let targetMagneticOffset = Self.magneticOffset(
            mouseLocation: mouse,
            windowFrame: window.frame,
            collapsedShapeHeight: collapsedShapeHeight,
            isExpanded: isExpanded,
            collapseAnimating: collapseAnimating
        )
        if disableAnimations {
            magneticOffset = .zero
        } else if abs(targetMagneticOffset.width - magneticOffset.width) > 0.5 {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                magneticOffset = targetMagneticOffset
            }
        } else if targetMagneticOffset == .zero && magneticOffset != .zero {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.65)) {
                magneticOffset = .zero
            }
        }

        if inside && !isExpanded {
            guard Date().timeIntervalSince(lastCollapseAt) > 0.65 else { return }
            if let savedPos = jumpMouseLocation {
                let dx = mouse.x - savedPos.x
                let dy = mouse.y - savedPos.y
                if dx * dx + dy * dy < 9 { return }
                jumpMouseLocation = nil
            }
            if !manager.visibleSessions.isEmpty {
                if !hoverToExpandPanel { return }
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
            hoverExitDelay: hoverExitCollapseDelay,
            elapsedSinceExpand: Date().timeIntervalSince(expandedAt)
        ) {
            collapse()
            expandedByHover = false
        }
    }

    private func clearHoverJellyState(animated: Bool = true) {
        guard isHoveringPill || jellyTrigger || jellySettled || magneticOffset != .zero else { return }

        isHoveringPill = false
        jellyGeneration += 1

        if !animated || disableAnimations {
            jellyTrigger = false
            jellySettled = false
            magneticOffset = .zero
            return
        }

        withAnimation(.easeOut(duration: 0.2)) {
            jellyTrigger = false
            jellySettled = false
            magneticOffset = .zero
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

    private var sortedActivityEvents: [(session: AgentSession, event: ToolEvent)] {
        manager.sessions
            .flatMap { session in
                session.events.map { (session: session, event: $0) }
            }
            .sorted { $0.event.timestamp > $1.event.timestamp }
    }

    private var activityLogContent: some View {
        let allEvents = sortedActivityEvents.prefix(30)

        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                HStack(spacing: 4) {
                    Image(systemName: "list.bullet.rectangle")
                        .font(.system(size: 10))
                        .foregroundStyle(IslandStyle.secondaryText)
                    Text(L10n.activityLog)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(IslandStyle.primaryText)
                }
                Spacer()
                Text("⌘O")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(IslandStyle.tertiaryText(for: themeManager.resolvedScheme))
            }

            if allEvents.isEmpty {
                Text(L10n.noActivity)
                    .font(.system(size: 11))
                    .foregroundStyle(IslandStyle.tertiaryText(for: themeManager.resolvedScheme))
                    .padding(.top, 4)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(allEvents), id: \.event.id) { item in
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(item.session.agentType.color.opacity(0.6))
                                    .frame(width: 4, height: 4)
                                Image(systemName: item.event.isComplete ? "checkmark.circle.fill" : "circle.dashed")
                                    .font(.system(size: 8))
                                    .foregroundStyle(item.event.isComplete ? .green.opacity(0.5) : IslandStyle.tertiaryText(for: themeManager.resolvedScheme))
                                    .symbolEffect(.bounce, value: item.event.isComplete)
                                Text(item.session.agentType.shortName)
                                    .font(.system(size: 9, weight: .medium))
                                    .foregroundStyle(item.session.agentType.color.opacity(0.7))
                                Text(item.event.displayName)
                                    .font(.system(size: 9))
                                    .foregroundStyle(IslandStyle.secondaryText)
                                Text(item.event.summary)
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundStyle(IslandStyle.tertiaryText(for: themeManager.resolvedScheme))
                                    .lineLimit(1)
                                Spacer()
                                Text(item.event.timestamp, style: .time)
                                    .font(.system(size: 8, design: .monospaced))
                                    .foregroundStyle(IslandStyle.tertiaryText(for: themeManager.resolvedScheme))
                            }
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(
                                item.event.isComplete
                                    ? Color.accentColor.opacity(0.15)
                                    : Color.clear
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                            .modifier(ToolCompletionEffect(
                                isComplete: item.event.isComplete,
                                reduceMotion: reduceMotion
                            ))
                            .modifier(ActivityLogGlowTrail(
                                isActive: !item.event.isComplete,
                                reduceMotion: reduceMotion
                            ))
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(maxHeight: 100)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(IslandStyle.insetFill(for: themeManager.resolvedScheme))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private func toggleActivityLog() {
        activityLogExpanded.toggle()
        reportSize()
    }
}
