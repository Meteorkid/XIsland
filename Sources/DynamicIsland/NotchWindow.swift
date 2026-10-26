import AppKit
import Combine
import QuartzCore

extension Notification.Name {
    static let xislandDidPresentWindow = Notification.Name("xislandDidPresentWindow")
    static let xislandDidFinishHandoff = Notification.Name("xislandDidFinishHandoff")
    static let xislandDidFinishInteractivePreview = Notification.Name("xislandDidFinishInteractivePreview")
    static let xislandHandoffLayoutDidUnlock = Notification.Name("xislandHandoffLayoutDidUnlock")
}

final class NotchWindow: NSPanel {
    var allowsAutomaticScreenChange: () -> Bool = { true }
    static let maxExpandedWidth: CGFloat = 520
    static let maxExpandedHeight: CGFloat = 600

    private static let expandedPadding: CGFloat = 8
    /// 最小点击高度，使用 IslandSizeCalculator 的用户设置高度
    private static var collapsedHitHeight: CGFloat { IslandSizeCalculator.collapsedShapeHeight }
    /// 双指下滑展开的最小滚动距离，过滤触控板惯性残余
    static let scrollExpandMinDelta: CGFloat = 2

    /// 窗口向上延伸的像素数，使屏幕顶端在窗口内部而非边缘。
    /// 避免 setFrame 偏差或抗锯齿导致顶部出现 1px 缝隙；内容顶部 padding 会覆盖此越界量，可见区无空隙。
    static let windowTopExtension: CGFloat = 6

    static func scrollExpandHitFrame(windowFrame: CGRect, screenFrame: CGRect?) -> CGRect {
        guard let screenFrame else { return windowFrame }

        let screenTop = screenFrame.origin.y + screenFrame.height
        return NSRect(
            x: windowFrame.minX,
            y: windowFrame.minY,
            width: windowFrame.width,
            height: max(windowFrame.height, screenTop - windowFrame.minY)
        )
    }

    static func shouldTriggerScrollExpand(
        isEnabled: Bool,
        isVisible: Bool,
        isCollapsed: Bool,
        isPrecise: Bool,
        deltaY: CGFloat,
        windowFrame: CGRect,
        screenFrame: CGRect?,
        mouseLocation: CGPoint
    ) -> Bool {
        guard isEnabled, isVisible, isCollapsed, isPrecise, deltaY > scrollExpandMinDelta else {
            return false
        }

        return scrollExpandHitFrame(windowFrame: windowFrame, screenFrame: screenFrame)
            .contains(mouseLocation)
    }

    /// True when the island sits in the built-in display’s top-center notch band (camera housing occludes content).
    func isObscuredByPhysicalNotch() -> Bool {
        guard let screen = self.screen else { return false }
        if #available(macOS 14.0, *) {
            guard screen.safeAreaInsets.top > 0 else { return false }
        } else {
            return false
        }
        let sf = screen.frame
        let wf = frame
        let topAligned = abs(wf.maxY - sf.maxY) < 4
        let inCenterBand = abs(wf.midX - sf.midX) < sf.width * 0.22
        return topAligned && inCenterBand
    }

    var customX: CGFloat?
    var keyEquivalentHandler: ((NSEvent) -> Bool)?
    private(set) var isDragging = false
    private var dragTracking = false
    private var dragStartWindowX: CGFloat = 0
    private var dragStartMouseX: CGFloat = 0
    private var mouseTrackingTimer: Timer?
    private var lastActiveScreenID: CGDirectDisplayID?
    /// 缓存 bestScreen() 结果，避免 setFrame 高频调用时重复遍历所有屏幕。
    private var cachedBestScreen: NSScreen?
    /// 审批期间锚定的屏幕。非 nil 时所有重排都以该屏为基准，
    /// 否则 resizeToFit / setFrame / 鼠标跟随定时器会各自按鼠标所在屏重算，把面板拉回错误的屏幕。
    private var pinnedScreenID: CGDirectDisplayID?
    private let defaults: UserDefaults
    private let markVisible: @MainActor () -> Void
    private let onExplicitShow: @MainActor () -> Void
    private let fullscreenProbe: (@Sendable () async -> Bool)?
    struct HandoffEnvironment {
        var reduceMotion: () -> Bool
        var orderFront: (NotchWindow) -> Void
        var orderOut: (NotchWindow) -> Void
        /// 原生隐藏返回后的观测点，视觉复位尚未发生。
        var didHide: ((NotchWindow) -> Void)? = nil
    }
    private let handoffEnvironment: HandoffEnvironment
    private(set) var handoffState = IslandHandoffState()
    var isHandoffLayoutLocked: Bool { handoffState.isPresentingInbound || handoffState.isFadingOut || isInteractiveSwitchPreviewActive }
    private var handoffPreparationHandler: (@MainActor (UInt64) -> Void)?
    private var handoffPrepared: (@MainActor (UInt64) -> Void)?
    private lazy var slideAnimator = IslandSlideAnimator(viewProvider: { [weak self] in self?.contentView })
    var switchGeometry: IslandSwitchGeometry? { IslandSlideAnimator.geometry(in: contentView) }
    private(set) var inboundSwitchMotion: IslandSwitchMotion?
    private(set) var isPreviewingIslandSwitch = false
    var isCollapsedPreviewReady = false
    /// 新到达提醒暂时优先于全屏隐藏；查看/处理、关闭提醒或主动切走后释放。
    var protectsTaskAttention = false {
        didSet { if oldValue != protectsTaskAttention { visibilityGeneration &+= 1 } }
    }

    @discardableResult
    func releaseTaskAttentionProtection() -> Task<Void, Never>? {
        guard protectsTaskAttention else { return nil }
        protectsTaskAttention = false
        // 主动隐藏路径不走这里，避免解除保护时反而把已经让位的窗口显示回来。
        guard isVisible, !isHiddenByIslandSwitch else { return nil }
        return refreshFullscreenVisibility()
    }
    private(set) var isInteractiveSwitchPreviewActive = false
    private var linkedPreviewController: LinkedIslandPreviewController?
    private var linkedOriginalContentAlpha: CGFloat?
    private var visibilityGeneration: UInt64 = 0
    private(set) var lastExplicitShowTime: TimeInterval = 0

    /// 横滑切换手势识别器
    let swipeRecognizer = SwipeGestureRecognizer()
    private var swipeOwnershipGate = IslandSwipeOwnershipGate()
    /// 灵动岛当前状态（由 NotchContentView 同步）
    var islandState: IslandState = .collapsed {
        didSet {
            if islandState != .collapsed { cancelIslandSwitchPreview(animated: false) }
        }
    }
    /// 正在切换应用时临时禁用 activeSpaceDidChange 的自动显示
    var isSwitchingApps = false {
        didSet {
            if oldValue != isSwitchingApps { visibilityGeneration &+= 1 }
        }
    }
    /// 已让位给另一个灵动岛，收到显式显示命令前禁止自动显示
    var isHiddenByIslandSwitch = false {
        didSet {
            if oldValue != isHiddenByIslandSwitch { visibilityGeneration &+= 1 }
        }
    }

    init(
        defaults: UserDefaults = AppPreferences.defaults,
        markVisible: @escaping @MainActor () -> Void = {
            if let currentIsland = AppSwitcher.shared.currentIsland {
                IslandIntegrationSettings.markVisible(currentIsland)
            }
        },
        onExplicitShow: @escaping @MainActor () -> Void = { AppSwitcher.shared.cancelSwitch() },
        fullscreenProbe: (@Sendable () async -> Bool)? = nil,
        handoffEnvironment: HandoffEnvironment? = nil
    ) {
        self.defaults = defaults
        self.markVisible = markVisible
        self.onExplicitShow = onExplicitShow
        self.fullscreenProbe = fullscreenProbe
        self.handoffEnvironment = handoffEnvironment ?? HandoffEnvironment(
            reduceMotion: {
                defaults.bool(forKey: "reduceMotion") || defaults.bool(forKey: "disableAnimations")
                    || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            },
            orderFront: { $0.orderFrontRegardless() },
            orderOut: { $0.orderOut(nil) }
        )
        let screen = Self.bestScreen()
        let width: CGFloat = 220
        let height = IslandSizeCalculator.collapsedShapeHeight
        let x = screen.frame.origin.x + (screen.frame.width - width) / 2
        let y = screen.frame.maxY - height

        super.init(
            contentRect: NSRect(x: x, y: y, width: width, height: height),
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .statusBar + 1
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = false
        isMovableByWindowBackground = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        animationBehavior = .none
        isReleasedWhenClosed = false
        // Avoid AppKit frame-restore paths that can throw during setFrame (seen in crash reports).
        isRestorable = false
        setFrameAutosaveName("")

        applySpaceBehavior()

        contentView = FlippedView(frame: .zero)
        contentView?.wantsLayer = true
        contentView?.layer?.backgroundColor = .clear

        NotificationCenter.default.addObserver(
            self, selector: #selector(screenDidChange),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )

        NotificationCenter.default.addObserver(self, selector: #selector(stopInteractivePreviewForContextChange),
            name: NSApplication.didHideNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(stopInteractivePreviewForContextChange),
            name: NSWorkspace.willSleepNotification, object: nil)

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(activeSpaceDidChange),
            name: NSWorkspace.activeSpaceDidChangeNotification, object: nil
        )

        // Track mouse movement between screens (throttled to 2 Hz)
        mouseTrackingTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.followMouseIfScreenChanged()
        }
    }

    private func followMouseIfScreenChanged() {
        guard !isInteractiveSwitchPreviewActive else { return }
        // 锚定期间不跟随鼠标，否则审批面板展开后会被拽回鼠标所在屏
        guard pinnedScreenID == nil, allowsAutomaticScreenChange() else { return }
        let mouseLocation = NSEvent.mouseLocation
        guard let mouseScreen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }),
              let screenID = mouseScreen.deviceDescription[NSDeviceDescriptionKey(rawValue: "NSScreenNumber")] as? CGDirectDisplayID
        else { return }

        if screenID != lastActiveScreenID {
            lastActiveScreenID = screenID
            cachedBestScreen = mouseScreen
            // Only reposition if not being dragged
            guard !dragTracking else { return }
            repositionOnScreen(mouseScreen)
        }
    }

    private func pauseMouseTracking() {
        mouseTrackingTimer?.invalidate()
        mouseTrackingTimer = nil
    }

    private func resumeMouseTracking() {
        guard mouseTrackingTimer == nil else { return }
        mouseTrackingTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.followMouseIfScreenChanged()
        }
    }

    private func repositionOnScreen(_ screen: NSScreen) {
        let currentFrame = frame
        let x: CGFloat
        if let cx = customX, cx.isFinite {
            let ratio = screen.frame.width / (self.screen?.frame.width ?? screen.frame.width)
            x = max(screen.frame.origin.x,
                    min(cx * ratio - currentFrame.width / 2,
                        screen.frame.origin.x + screen.frame.width - currentFrame.width))
        } else {
            x = screen.frame.origin.x + (screen.frame.width - currentFrame.width) / 2
        }
        let screenTop = screen.frame.maxY
        // 窗口向上延伸 windowTopExtension，使屏幕顶端在窗口内部
        let y = screenTop - currentFrame.height + Self.windowTopExtension
        setFrameDirect(NSRect(x: x, y: y, width: currentFrame.width, height: currentFrame.height), display: true)
    }

    func applySpaceBehavior() {
        let allSpaces = defaults.bool(forKey: "showOnAllSpaces")
        if allSpaces {
            collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        } else {
            collectionBehavior = [.fullScreenAuxiliary, .stationary]
        }
    }

    @objc private func activeSpaceDidChange(_ note: Notification) {
        refreshFullscreenVisibility()
    }

    @discardableResult
    func refreshFullscreenVisibility() -> Task<Void, Never>? {
        // 新检查与显式显示都会淘汰此前的结果，包括标志已恢复原值的情况。
        visibilityGeneration &+= 1
        let generation = visibilityGeneration
        // 切换应用期间不自动显示窗口
        guard !isSwitchingApps, !isHiddenByIslandSwitch, !protectsTaskAttention else { return nil }

        let hideInFullscreen = defaults.bool(forKey: "hideInFullscreen")
        guard hideInFullscreen else {
            // 不再自动显示窗口——窗口只在明确命令时显示
            return nil
        }
        let fullscreenProbe = fullscreenProbe
        return Task { [weak self] in
            let inFullscreen: Bool
            if let fullscreenProbe {
                inFullscreen = await fullscreenProbe()
            } else {
                // Phase 1: snapshot MainActor-isolated state before leaving the main thread
                let screen = NSScreen.main
                let windowSnapshots: [(screen: NSScreen?, styleMask: NSWindow.StyleMask)] =
                    NSApplication.shared.windows.map { ($0.screen, $0.styleMask) }
                let frontApp = NSWorkspace.shared.frontmostApplication
                // Phase 2: slow CGWindowList work off the main thread
                inFullscreen = await Task.detached(priority: .userInitiated) {
                    screen.map {
                        Self.isScreenInFullscreenOffMain($0, windowSnapshots: windowSnapshots, frontApp: frontApp)
                    } ?? false
                }.value
            }
            guard let self else { return }
            guard self.visibilityGeneration == generation,
                  self.defaults.bool(forKey: "hideInFullscreen"),
                  !self.isSwitchingApps, !self.isHiddenByIslandSwitch, !self.protectsTaskAttention else { return }
            if inFullscreen {
                self.pauseMouseTracking()
                self.orderOut(nil)
            } else {
                self.resumeMouseTracking()
                self.orderFrontRegardless()
            }
        }
    }

    private nonisolated static func isScreenInFullscreenOffMain(
        _ screen: NSScreen,
        windowSnapshots: [(screen: NSScreen?, styleMask: NSWindow.StyleMask)],
        frontApp: NSRunningApplication?
    ) -> Bool {
        // Check AppKit windows using snapshots (no MainActor access needed)
        for (winScreen, styleMask) in windowSnapshots {
            if styleMask.contains(.fullScreen) && winScreen == screen {
                return true
            }
        }
        // Slow CGWindowList check for third-party fullscreen windows
        if let frontApp,
           frontApp.bundleIdentifier != Bundle.main.bundleIdentifier {
            let opts = CGWindowListOption([.optionOnScreenOnly, .excludeDesktopElements])
            guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else {
                return false
            }
            for info in list {
                if let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                   pid == frontApp.processIdentifier,
                   let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
                   let w = bounds["Width"], let h = bounds["Height"],
                   w >= screen.frame.width && h >= screen.frame.height {
                    return true
                }
            }
        }
        return false
    }

    func resizeToFit(contentWidth: CGFloat, contentHeight: CGFloat, display: Bool = true) {
        let screen = layoutScreen()
        let normalizedContentHeight = max(contentHeight, Self.collapsedHitHeight)
        let padding = Self.padding(forContentHeight: normalizedContentHeight)
        let w = contentWidth + padding * 2
        // 向上延伸窗口，使屏幕顶端在窗口内部
        let h = normalizedContentHeight + padding + Self.windowTopExtension
        let x: CGFloat
        if let cx = customX, cx.isFinite {
            x = max(screen.frame.origin.x,
                    min(cx - w / 2, screen.frame.origin.x + screen.frame.width - w))
        } else {
            x = screen.frame.origin.x + (screen.frame.width - w) / 2
        }
        let screenTop = screen.frame.maxY
        let yComputed = screenTop - h + Self.windowTopExtension
        let rect = Self.safeFrame(NSRect(x: x, y: yComputed, width: w, height: h), screen: screen)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        setFrameDirect(rect, display: display)
        CATransaction.commit()
    }

    func resizeToFitCollapse(contentWidth: CGFloat, contentHeight: CGFloat) {
        let screen = layoutScreen()
        let targetW = max(1, contentWidth.isFinite ? contentWidth : 180)
        // 向上延伸窗口
        let targetH = max(contentHeight, Self.collapsedHitHeight) + Self.windowTopExtension
        let targetX: CGFloat
        if let cx = customX, cx.isFinite {
            targetX = max(screen.frame.origin.x,
                          min(cx - targetW / 2, screen.frame.origin.x + screen.frame.width - targetW))
        } else {
            targetX = screen.frame.origin.x + (screen.frame.width - targetW) / 2
        }
        let screenTop = screen.frame.maxY
        let targetY = screenTop - targetH + Self.windowTopExtension

        isDragging = false
        dragTracking = false

        let target = Self.safeFrame(
            NSRect(x: targetX, y: targetY, width: targetW, height: targetH),
            screen: screen
        )
        // No NSAnimationContext: grouping has been observed to rethrow through runAnimationGroup when
        // AppKit mutates window frame (crash: NSMutableDictionary initWithContentsOfFile: in _reallySetFrame:).
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        setFrameDirect(target, display: true)
        CATransaction.commit()

        // 收起后解除锚定：先在锚定屏完成收起动画，之后恢复跟随鼠标
        pinnedScreenID = nil
    }

    /// Ensures window frames never propagate NaN/Inf into AppKit (can abort inside `_reallySetFrame:`).
    private static func safeFrame(_ rect: NSRect, screen: NSScreen) -> NSRect {
        let sf = screen.frame
        let minW: CGFloat = 1
        let minH = collapsedHitHeight
        var w = rect.width
        var h = rect.height
        var x = rect.origin.x
        var y = rect.origin.y
        if !w.isFinite || w < minW { w = minW }
        if !h.isFinite || h < minH { h = minH }
        if !x.isFinite { x = sf.midX - w / 2 }
        if !y.isFinite { y = sf.maxY - h }
        w = min(w, max(minW, sf.width))
        h = min(h, max(minH, sf.height))
        x = max(sf.minX, min(x, sf.maxX - w))
        // 允许窗口向上延伸 windowTopExtension 像素（超出屏幕顶端）
        y = max(sf.minY, min(y, sf.maxY - h + Self.windowTopExtension))
        return NSRect(x: x, y: y, width: w, height: h)
    }

    /// Returns the screen that currently contains the mouse cursor.
    /// Falls back to built-in, then first screen.
    static func bestScreen() -> NSScreen {
        let mouseLocation = NSEvent.mouseLocation
        if let mouseScreen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) {
            return mouseScreen
        }
        if let builtIn = NSScreen.screens.first(where: {
            $0.deviceDescription[NSDeviceDescriptionKey(rawValue: "NSScreenNumber")]
                as? CGDirectDisplayID == CGMainDisplayID()
        }) {
            return builtIn
        }
        return NSScreen.screens.first ?? NSScreen()
    }

    /// 主窗口的最小边长，用于过滤工具条、HUD 等小窗口。
    private static let minMainWindowSide: CGFloat = 100

    /// 返回当前"正在显示的主界面"所在的屏幕。
    /// 多显示器/多桌面时，鼠标未必落在用户当前工作的显示器上，
    /// 因此优先取前台应用主窗口所在屏幕，其次 NSScreen.main，最后才是鼠标所在屏幕（bestScreen）。
    @MainActor
    static func activeScreen() -> NSScreen {
        let screens = NSScreen.screens
        if let front = NSWorkspace.shared.frontmostApplication,
           front.bundleIdentifier != Bundle.main.bundleIdentifier,
           let primaryFrame = primaryScreenFrame(screens),
           let windowRect = largestWindowRect(ofPID: front.processIdentifier) {
            let appKitRect = convertToAppKit(cgRect: windowRect, primaryFrame: primaryFrame)
            if let index = indexOfScreen(bestOverlapping: appKitRect, in: screens.map(\.frame)) {
                return screens[index]
            }
        }
        if let main = NSScreen.main { return main }
        return bestScreen()
    }

    /// 返回指定进程在屏幕上面积最大的普通窗口，坐标为 Quartz 全局坐标（原点在主屏左上、y 向下）。
    /// 只取 layer 0 的普通窗口，避免前台应用的浮动面板、工具窗参与"最大面积"选举。
    private static func largestWindowRect(ofPID pid: pid_t) -> CGRect? {
        let opts = CGWindowListOption([.optionOnScreenOnly, .excludeDesktopElements])
        guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        var best: CGRect?
        var bestArea: CGFloat = 0
        for info in list {
            guard (info[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  (info[kCGWindowLayer as String] as? Int) == 0,
                  let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = bounds["X"],
                  let y = bounds["Y"],
                  let w = bounds["Width"],
                  let h = bounds["Height"],
                  x.isFinite, y.isFinite,
                  w >= minMainWindowSide, h >= minMainWindowSide else { continue }
            let area = w * h
            if area > bestArea {
                bestArea = area
                best = CGRect(x: x, y: y, width: w, height: h)
            }
        }
        return best
    }

    /// AppKit 坐标系原点 (0,0) 所在的屏幕 frame，即 Quartz 坐标的参照屏。
    private static func primaryScreenFrame(_ screens: [NSScreen]) -> CGRect? {
        (screens.first { $0.frame.origin == .zero } ?? screens.first)?.frame
    }

    /// 把 Quartz 全局坐标矩形（原点在主屏左上、y 向下）翻转为 AppKit 坐标（原点在主屏左下、y 向上）。
    /// 两套坐标系直接混用时，显示器上下排布会导致任何屏都判不中，静默退化到主屏。
    static func convertToAppKit(cgRect: CGRect, primaryFrame: CGRect) -> CGRect {
        CGRect(
            x: cgRect.origin.x,
            y: primaryFrame.maxY - cgRect.maxY,
            width: cgRect.width,
            height: cgRect.height
        )
    }

    /// 返回与 rect 重叠面积最大的屏幕下标；全部无重叠时返回 nil。
    /// 用重叠面积而非中心点判定，窗口跨屏或中心落在屏幕间隙时也能选中正确的屏幕。
    static func indexOfScreen(bestOverlapping rect: CGRect, in frames: [CGRect]) -> Int? {
        var bestIndex: Int?
        var bestArea: CGFloat = 0
        for (index, frame) in frames.enumerated() {
            let overlap = frame.intersection(rect)
            guard !overlap.isNull else { continue }
            let area = overlap.width * overlap.height
            if area > bestArea {
                bestArea = area
                bestIndex = index
            }
        }
        return bestIndex
    }

    private static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        screen.deviceDescription[NSDeviceDescriptionKey(rawValue: "NSScreenNumber")] as? CGDirectDisplayID
    }

    private static func screen(withID id: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { displayID(of: $0) == id }
    }

    /// 所有重排的统一基准屏：审批期间用锚定屏，其余时候用鼠标所在屏。
    /// 锚定屏已断开时清除锚定，避免窗口卡在不存在的显示器上。
    private func layoutScreen() -> NSScreen {
        if let pinnedScreenID {
            if let pinned = Self.screen(withID: pinnedScreenID) {
                return pinned
            }
            self.pinnedScreenID = nil
        }
        return cachedOrRefreshScreen()
    }

    /// 返回缓存的 bestScreen，仅在鼠标跨越屏幕边界时刷新。
    /// 用于 setFrame/setFrameDirect 中避免高频遍历。
    private func cachedOrRefreshScreen() -> NSScreen {
        let mouseLocation = NSEvent.mouseLocation
        let mouseScreen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) })
        if let mouseScreen {
            let screenID = mouseScreen.deviceDescription[NSDeviceDescriptionKey(rawValue: "NSScreenNumber")] as? CGDirectDisplayID
            if screenID == lastActiveScreenID, let cached = cachedBestScreen {
                return cached
            }
            lastActiveScreenID = screenID
            cachedBestScreen = mouseScreen
            return mouseScreen
        }
        // Mouse not on any screen (rare); fallback
        return cachedBestScreen ?? Self.bestScreen()
    }

    /// True when this screen has a physical notch (camera housing).
    static func screenHasPhysicalNotch(_ screen: NSScreen) -> Bool {
        if #available(macOS 14.0, *) {
            return screen.safeAreaInsets.top > 0
        }
        return false
    }

    @objc private func screenDidChange(_ note: Notification) {
        stopInteractivePreviewForContextChange(note)
        let screen = layoutScreen()
        let x: CGFloat
        if let cx = customX {
            x = max(screen.frame.origin.x,
                    min(cx - frame.width / 2, screen.frame.origin.x + screen.frame.width - frame.width))
        } else {
            x = screen.frame.origin.x + (screen.frame.width - frame.width) / 2
        }
        let screenTop = screen.frame.maxY
        // 窗口向上延伸
        let y = screenTop - frame.height + Self.windowTopExtension
        setFrameDirect(NSRect(x: x, y: y, width: frame.width, height: frame.height), display: true)
    }

    private static func padding(forContentHeight contentHeight: CGFloat) -> CGFloat {
        contentHeight <= collapsedHitHeight + 0.5 ? 0 : expandedPadding
    }

    // MARK: - Horizontal drag via sendEvent

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            dragStartMouseX = NSEvent.mouseLocation.x
            dragStartWindowX = frame.origin.x
            dragTracking = true
            isDragging = false
            super.sendEvent(event)

        case .leftMouseDragged where dragTracking:
            let currentX = NSEvent.mouseLocation.x
            let dx = currentX - dragStartMouseX
            if !isDragging && abs(dx) > 4 {
                isDragging = true
            }
            if isDragging {
                let screen = cachedOrRefreshScreen()
                let newX = max(screen.frame.origin.x,
                               min(dragStartWindowX + dx,
                                   screen.frame.origin.x + screen.frame.width - frame.width))
                // 窗口向上延伸
                let topY = screen.frame.maxY - frame.height + Self.windowTopExtension
                setFrameDirect(NSRect(x: newX, y: topY, width: frame.width, height: frame.height))
            } else {
                super.sendEvent(event)
            }

        case .leftMouseUp where dragTracking:
            dragTracking = false
            if isDragging {
                customX = frame.origin.x + frame.width / 2
                isDragging = false
            } else {
                super.sendEvent(event)
            }

        case .scrollWheel:
            if handleIslandSwipe(event) { return }

            if !isSwitchingApps, event.momentumPhase.isEmpty, Self.shouldTriggerScrollExpand(
                isEnabled: AppPreferences.defaults.bool(forKey: "scrollDownToExpandPanel"),
                isVisible: true,
                isCollapsed: islandState == .collapsed,
                isPrecise: event.hasPreciseScrollingDeltas,
                deltaY: event.scrollingDeltaY,
                windowFrame: frame,
                screenFrame: screen?.frame,
                mouseLocation: NSEvent.mouseLocation
            ) {
                NotificationCenter.default.post(name: .xislandScrollDown, object: nil)
                return
            }

            super.sendEvent(event)

        default:
            super.sendEvent(event)
        }
    }

    /// 在鼠标所在屏幕显示窗口（URL Scheme 唤醒时调用）
    func showAtMouseScreen() {
        cancelHandoffPresentation()
        presentAtMouseScreen()
    }

    private func presentAtMouseScreen(reposition: Bool = true) {
        alphaValue = 1
        lastExplicitShowTime = Date().timeIntervalSince1970
        onExplicitShow()
        visibilityGeneration &+= 1
        isHiddenByIslandSwitch = false
        markVisible()
        // 明确要求在鼠标所在屏显示，解除审批期间的锚定
        if reposition {
            pinnedScreenID = nil
            repositionOnScreen(layoutScreen())
        }
        presentWindow()
    }

    /// 在当前"正在显示的主界面"所在屏幕显示并置顶（审批/问答/计划评审时使用）。
    /// 与 showAtMouseScreen 不同，不依赖鼠标位置，避免多显示器时展开到错误的屏幕。
    func showAtActiveScreen() {
        showAtActiveScreen(pinUntilCollapse: true)
    }

    func showAtActiveScreen(pinUntilCollapse: Bool) {
        cancelHandoffPresentation()
        lastExplicitShowTime = Date().timeIntervalSince1970
        onExplicitShow()
        visibilityGeneration &+= 1
        isHiddenByIslandSwitch = false
        markVisible()
        // 先锚定再重排：锚定后 layoutScreen() 一律返回该屏，
        // 后续的 resizeToFit / setFrame / 鼠标跟随都不会再把面板拉回鼠标所在屏
        let target = Self.activeScreen()
        pinnedScreenID = Self.displayID(of: target)
        repositionOnScreen(target)
        presentWindow()
        if !pinUntilCollapse { pinnedScreenID = nil }
    }

    func showWindow() {
        cancelHandoffPresentation()
        lastExplicitShowTime = Date().timeIntervalSince1970
        onExplicitShow()
        visibilityGeneration &+= 1
        isHiddenByIslandSwitch = false
        markVisible()
        presentWindow()
    }

    private func presentWindow() {
        handoffEnvironment.orderFront(self)
        // 窗口一直可见时也必须恢复内容与轮询，不能依赖 AppKit 的可见性边沿。
        NotificationCenter.default.post(name: .xislandDidPresentWindow, object: self)
    }

    @discardableResult
    func beginInboundHandoff(motion: IslandSwitchMotion? = nil,
                             onPrepared: @escaping @MainActor (UInt64) -> Void) -> UInt64 {
        linkedPreviewController?.reset()
        isPreviewingIslandSwitch = false
        inboundSwitchMotion = motion
        let generation = handoffState.beginInbound()
        handoffPrepared = onPrepared
        visibilityGeneration &+= 1
        isHiddenByIslandSwitch = false
        isSwitchingApps = true
        swipeRecognizer.suppressUntilNextGesture()
        swipeOwnershipGate.reset()
        handoffPreparationHandler?(generation)
        // 冷启动时窗口尚未显示，先建立 SwiftUI 树以安装准备处理器。
        contentView?.layoutSubtreeIfNeeded()
        return generation
    }

    func installHandoffPreparationHandler(_ handler: @escaping @MainActor (UInt64) -> Void) {
        handoffPreparationHandler = handler
        if let generation = handoffState.pendingPreparation { handler(generation) }
    }

    func removeHandoffPreparationHandler() { handoffPreparationHandler = nil }

    @discardableResult
    func completeInboundHandoffPreparation(generation: UInt64) -> Bool {
        guard handoffState.pendingPreparation == generation, isCurrentHandoff(generation) else { return false }
        // 最终位置与布局仍属于准备期；此时旧 frame 的 outside 不能解除悬停保护。
        pinnedScreenID = nil
        repositionOnScreen(layoutScreen())
        contentView?.layoutSubtreeIfNeeded()
        guard handoffState.consumePreparation(generation) else { return false }
        let prepared = handoffPrepared
        handoffPrepared = nil
        prepared?(generation)
        return true
    }

    func showPreparedHandoff(generation: UInt64, motion: IslandSwitchMotion? = nil) {
        guard handoffState.beginPresentation(generation) else { return }
        let motion = motion ?? inboundSwitchMotion
        slideAnimator.animateIncoming(motion: motion, reduceMotion: handoffEnvironment.reduceMotion()) { [weak self] in
            guard let self, self.handoffState.finishPresentation(generation) else { return }
            self.inboundSwitchMotion = nil
            self.isSwitchingApps = false
            NotificationCenter.default.post(name: .xislandHandoffLayoutDidUnlock, object: self)
            NotificationCenter.default.post(name: .xislandDidFinishHandoff, object: self)
        }
        presentAtMouseScreen(reposition: false)
    }

    func isCurrentHandoff(_ generation: UInt64) -> Bool { handoffState.generation == generation }

    func observeHandoffPointer(isInside: Bool) -> Bool {
        if isInteractiveSwitchPreviewActive { return true }
        if isPreviewingIslandSwitch || swipeRecognizer.isActive {
            if !isInside || !isVisible {
                cancelIslandSwitchPreview()
            } else if isPreviewingIslandSwitch, swipeRecognizer.isActive,
                      !swipeOwnershipGate.canContinuePreview(
                        now: ProcessInfo.processInfo.systemUptime,
                        probe: { isFrontmostIslandWindow() }
                      ) {
                cancelIslandSwitchPreview()
            }
        }
        return handoffState.observePointer(isInside: isInside)
    }

    func hideWindowForIslandSwitch(animated: Bool = true, motion: IslandSwitchMotion? = nil) {
        guard !isHiddenByIslandSwitch || handoffState.isFadingOut else { return }
        guard let generation = handoffState.beginFadeOut() else { return }
        swipeOwnershipGate.reset()
        handoffPrepared = nil
        inboundSwitchMotion = nil
        isPreviewingIslandSwitch = false
        visibilityGeneration &+= 1
        isHiddenByIslandSwitch = true
        isSwitchingApps = true
        slideAnimator.animateOutgoing(motion: motion, reduceMotion: !animated || handoffEnvironment.reduceMotion()) { [weak self] in
            self?.finishHandoffFade(generation: generation)
        }
    }

    func previewIslandSwitch(translation: CGFloat) {
        isPreviewingIslandSwitch = true
        slideAnimator.preview(translation: translation, width: frame.width, reduceMotion: handoffEnvironment.reduceMotion())
    }

    func cancelIslandSwitchPreview(animated: Bool = true) {
        if let linkedPreviewController, linkedPreviewController.phase != .idle {
            // 真实显示请求发出后只允许失败回滚；普通悬停/按键不能撤销已提交的对端。
            if linkedPreviewController.phase == .committing && isSwitchingApps { return }
            swipeRecognizer.reset()
            swipeOwnershipGate.reset()
            if animated { linkedPreviewController.cancel() }
            else { linkedPreviewController.reset(afterWindowHidden: !isVisible || NSApp.isHidden) }
            return
        }
        guard !isSwitchingApps else { return }
        swipeRecognizer.reset()
        swipeOwnershipGate.reset()
        guard isPreviewingIslandSwitch else { return }
        isPreviewingIslandSwitch = false
        slideAnimator.returnToRest(reduceMotion: !animated || handoffEnvironment.reduceMotion())
    }

    /// 本地与全局滚动共用资格判断，避免背后的岛消费同一次手势。
    func handleIslandSwipe(_ event: NSEvent) -> Bool {
        if let linkedPreviewController, linkedPreviewController.ownsGesture {
            if event.phase.contains(.began) {
                guard IslandIntegrationSettings.isSwipeSwitchEnabled, isVisible, !NSApp.isHidden,
                      islandState == .collapsed,
                      (linkedPreviewController.hitFrame ?? frame).contains(NSEvent.mouseLocation),
                      isFrontmostIslandWindow() else {
                    swipeRecognizer.reset()
                    linkedPreviewController.cancel()
                    return false
                }
                linkedPreviewController.beginGesture()
            }
            let result = swipeRecognizer.handleScroll(event: event)
            switch result {
            case .progress(let translation): linkedPreviewController.update(translation: translation)
            case .triggered(let direction): linkedPreviewController.commit(direction: direction)
            case .cancelled: linkedPreviewController.cancel()
            case .inProgress:
                if !swipeRecognizer.isActive || swipeRecognizer.hasLockedVerticalAxis {
                    linkedPreviewController.cancel()
                }
            }
            return true
        }
        guard IslandIntegrationSettings.isSwipeSwitchEnabled, !isSwitchingApps,
              IslandWindowOwnership.canHandleGlobalSwipe(
                isVisible: isVisible, isCollapsed: islandState == .collapsed,
                windowFrame: frame, mouseLocation: NSEvent.mouseLocation
              ) else {
            swipeRecognizer.reset()
            swipeOwnershipGate.reset()
            if !isSwitchingApps { cancelIslandSwitchPreview() }
            return false
        }
        guard swipeOwnershipGate.canHandleEvent(
            isNewGesture: event.phase.contains(.began),
            isGestureActive: swipeRecognizer.isActive,
            now: ProcessInfo.processInfo.systemUptime,
            probe: { isFrontmostIslandWindow() }
        ) else {
            cancelIslandSwitchPreview()
            return false
        }
        switch swipeRecognizer.handleScroll(event: event) {
        case .inProgress:
            if !swipeRecognizer.isActive { swipeOwnershipGate.reset() }
            return swipeRecognizer.consumesHorizontalScroll
        case .progress(let translation):
            if beginLinkedIslandPreview(translation: translation) { return true }
            // 不支持预览时保持真实窗口不动，松手后仍走安全显示交接。
            return true
        case .cancelled:
            cancelIslandSwitchPreview()
            return true
        case .triggered(let direction):
            swipeOwnershipGate.reset()
            guard AppSwitcher.shared.canSwitchToAnotherIsland else {
                cancelIslandSwitchPreview()
                return true
            }
            AppSwitcher.shared.switchToNextIsland(direction: direction)
            return true
        }
    }

    @objc private func stopInteractivePreviewForContextChange(_ note: Notification) {
        guard isInteractiveSwitchPreviewActive, linkedPreviewController?.phase != .committing else { return }
        swipeRecognizer.reset()
        swipeOwnershipGate.reset()
        linkedPreviewController?.reset(afterWindowHidden: !isVisible || NSApp.isHidden)
    }

    /// 测试按钮与真实手势共用同一画布，不能只验证旧的淡入淡出路径。
    func startLinkedIslandSwitch(direction: SwipeDirection) -> Bool {
        if let linkedPreviewController, linkedPreviewController.phase != .idle {
            if linkedPreviewController.phase == .returning || linkedPreviewController.phase == .finishing {
                linkedPreviewController.beginGesture()
            }
            linkedPreviewController.commit(direction: direction)
            return true
        }
        guard beginLinkedIslandPreview(translation: 0) else { return false }
        linkedPreviewController?.commit(direction: direction)
        return true
    }

    private func beginLinkedIslandPreview(translation: CGFloat) -> Bool {
        guard isVisible, islandState == .collapsed, isCollapsedPreviewReady,
              AppSwitcher.shared.canSwitchToAnotherIsland,
              !isSwitchingApps, !isDragging, !handoffEnvironment.reduceMotion(),
              let current = AppSwitcher.shared.currentIsland else { return false }
        if linkedPreviewController == nil { linkedPreviewController = makeLinkedPreviewController(current: current) }
        linkedPreviewController?.update(translation: translation)
        return true
    }

    private func makeLinkedPreviewController(current: IslandApp) -> LinkedIslandPreviewController {
        let peer: IslandApp = current == .xisland ? .xnook : .xisland
        return LinkedIslandPreviewController(environment: .init(
            requestTarget: { completion in
                guard LinkedIslandPreviewService.runningPeer(for: current)?.pid == ProcessInfo.processInfo.processIdentifier,
                      let target = LinkedIslandPreviewService.runningPeer(for: peer) else { return nil }
                do {
                    let pending = try LinkedIslandPreviewTransport.begin(expectedTarget: target) { result in
                        switch result {
                        case .success(let snapshot): completion(snapshot)
                        case .failure: completion(nil)
                        }
                    }
                    DistributedNotificationCenter.default().postNotificationName(
                        LinkedIslandPreviewService.notificationName(for: peer), object: nil,
                        userInfo: pending.request.userInfo, deliverImmediately: true)
                    return { pending.cancel() }
                } catch {
                    // 能力/连接不可用时，不产生预览；松手仍可使用原有安全切换。
                    return nil
                }
            },
            captureSource: { [weak self] in
                guard let self, self.isVisible, self.islandState == .collapsed,
                      self.isCollapsedPreviewReady, let view = self.contentView,
                      let outline = self.switchGeometry else { return nil }
                do { return try LinkedIslandPreviewCanvas.capture(view: view, outline: outline) }
                catch is LinkedIslandPreviewCanvas.CaptureError { return nil }
                catch {
                    NSLog("Linked source capture failed (%@)", String(reflecting: type(of: error)))
                    return nil
                }
            },
            makeCanvas: { source, target in LinkedIslandPreviewCanvas(source: source, target: target) },
            hideLiveContent: { [weak self] hidden in
                guard let self, let content = self.contentView else { return }
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                defer { CATransaction.commit() }
                if hidden {
                    if self.linkedOriginalContentAlpha == nil { self.linkedOriginalContentAlpha = content.alphaValue }
                    content.alphaValue = 0
                } else if let alpha = self.linkedOriginalContentAlpha {
                    content.alphaValue = alpha
                    self.linkedOriginalContentAlpha = nil
                }
            },
            blockInteraction: { [weak self] active in
                guard let self else { return }
                if active && !self.isInteractiveSwitchPreviewActive { self.handoffState.cancelPresentation() }
                self.isInteractiveSwitchPreviewActive = active
                self.isSwitchingApps = active
            },
            switchToPeer: { direction, alreadyAnimated in
                AppSwitcher.shared.switchToIsland(named: peer.rawValue,
                    direction: alreadyAnimated ? direction : nil, animationAlreadyPresented: alreadyAnimated)
            },
            peerIsVisible: { AppSwitcher.shared.isIslandVisible(named: peer.rawValue) },
            didFinish: { [weak self] in
                guard let self else { return }
                if self.linkedPreviewController?.ownsGesture != true {
                    self.swipeRecognizer.reset()
                    self.swipeOwnershipGate.reset()
                }
                NotificationCenter.default.post(name: .xislandHandoffLayoutDidUnlock, object: self)
                if self.isVisible && !NSApp.isHidden && !self.isHiddenByIslandSwitch {
                    NotificationCenter.default.post(name: .xislandDidFinishInteractivePreview, object: self)
                }
            },
            cancelCommit: { AppSwitcher.shared.cancelSwitch() },
            yieldToVisiblePeer: { [weak self] in self?.hideWindowForIslandSwitch(animated: false) },
            sourceContextIsValid: { [weak self] snapshot in
                guard let self, self.isVisible, !NSApp.isHidden, self.islandState == .collapsed,
                      let screen = self.screen,
                      (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32) == snapshot.outline.displayID,
                      screen.frame.contains(NSEvent.mouseLocation) else { return false }
                let visibleFrame = self.frame.intersection(screen.frame)
                let tolerance = 2 / snapshot.scale
                return abs(visibleFrame.minX - snapshot.frame.minX) <= tolerance
                    && abs(visibleFrame.minY - snapshot.frame.minY) <= tolerance
                    && abs(visibleFrame.width - snapshot.frame.width) <= tolerance
                    && abs(visibleFrame.height - snapshot.frame.height) <= tolerance
            }
        ))
    }

    /// 隐藏路径先淘汰事务，待原生窗口退出屏幕后再复位可见层。
    private func cancelHandoffPresentation(resetVisuals: Bool = true) {
        handoffState.cancelPresentation()
        handoffPrepared = nil
        inboundSwitchMotion = nil
        isPreviewingIslandSwitch = false
        swipeRecognizer.reset()
        swipeOwnershipGate.reset()
        if resetVisuals { resetHandoffVisuals() }
        isSwitchingApps = false
    }

    private func resetHandoffVisuals() {
        linkedPreviewController?.reset(afterWindowHidden: !isVisible)
        slideAnimator.reset()
        alphaValue = 1
    }

    private func finishHandoffFade(generation: UInt64) {
        guard handoffState.finishFadeOut(generation) else { return }
        handoffEnvironment.orderOut(self)
        slideAnimator.reset()
        alphaValue = 1
        isSwitchingApps = false
        NotificationCenter.default.post(name: .xislandHandoffLayoutDidUnlock, object: self)
    }

    func isFrontmostIslandWindow() -> Bool {
        IslandWindowOwnership.isFrontmostIslandWindow(
            self,
            bundleIdentifiers: ["com.meteorkid.xnook", "dev.xisland.app"]
        )
    }

    override func close() {
        cancelHandoffPresentation(resetVisuals: false)
        super.close()
        handoffEnvironment.didHide?(self)
        resetHandoffVisuals()
    }

    override func orderOut(_ sender: Any?) {
        protectsTaskAttention = false
        cancelHandoffPresentation(resetVisuals: false)
        super.orderOut(sender)
        handoffEnvironment.didHide?(self)
        resetHandoffVisuals()
    }

    func setFrameDirect(_ rect: NSRect, display: Bool = true) {
        let screen = layoutScreen()
        let normalized = Self.safeFrame(
            NSRect(
                x: rect.origin.x,
                y: rect.origin.y,
                width: rect.width,
                height: max(rect.height, Self.collapsedHitHeight)
            ),
            screen: screen
        )
        super.setFrame(normalized, display: display)
    }

    /// 把外部请求的 frame 归一化成「贴屏幕顶端、按 customX 或居中、经 safeFrame 钳制」的最终 frame。
    /// 两个 setFrame 重载此前各自维护一份完全相同的 21 行定位逻辑，改一处漏一处的风险高，故合并。
    /// 返回 nil 表示 frameRect 含 NaN/Inf，应直接忽略这次 setFrame。
    private func pinnedFrame(for frameRect: NSRect) -> NSRect? {
        guard frameRect.width.isFinite, frameRect.height.isFinite else { return nil }
        let clampedHeight = max(frameRect.height, Self.collapsedHitHeight)
        // 向上延伸窗口，使屏幕顶端在窗口内部
        let windowHeight = clampedHeight + Self.windowTopExtension
        let screen = layoutScreen()
        let topY = screen.frame.maxY - clampedHeight
        let x: CGFloat
        if isDragging || dragTracking {
            x = frame.origin.x
        } else if let cx = customX, cx.isFinite {
            x = max(screen.frame.origin.x,
                    min(cx - frameRect.width / 2,
                        screen.frame.origin.x + screen.frame.width - frameRect.width))
        } else {
            x = screen.frame.origin.x + (screen.frame.width - frameRect.width) / 2
        }
        return Self.safeFrame(
            NSRect(x: x, y: topY, width: frameRect.width, height: windowHeight),
            screen: screen
        )
    }

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        guard let pinned = pinnedFrame(for: frameRect) else { return }
        super.setFrame(pinned, display: flag)
    }

    override func setFrame(_ frameRect: NSRect, display displayFlag: Bool, animate animateFlag: Bool) {
        guard let pinned = pinnedFrame(for: frameRect) else { return }
        super.setFrame(pinned, display: displayFlag, animate: animateFlag)
    }

    deinit {
        mouseTrackingTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let handler = keyEquivalentHandler, handler(event) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

private class FlippedView: NSView {
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
