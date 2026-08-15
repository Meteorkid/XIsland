import AppKit
import Combine
import QuartzCore

final class NotchWindow: NSPanel {
    static let maxExpandedWidth: CGFloat = 520
    static let maxExpandedHeight: CGFloat = 600

    private static let expandedPadding: CGFloat = 8
    /// 最小点击高度，使用 IslandSizeCalculator 的用户设置高度
    private static var collapsedHitHeight: CGFloat { IslandSizeCalculator.collapsedShapeHeight }
    /// 双指下滑展开的最小滚动距离，过滤触控板惯性残余
    static let scrollExpandMinDelta: CGFloat = 2

    static func islandTopOffset(for _: NSScreen) -> CGFloat { 0 }

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

    /// 横滑切换手势识别器
    let swipeRecognizer = SwipeGestureRecognizer()
    /// 灵动岛当前状态（由 NotchContentView 同步）
    var islandState: IslandState = .collapsed
    /// 正在切换应用时临时禁用 activeSpaceDidChange 的自动显示
    var isSwitchingApps = false
    /// 已让位给另一个灵动岛，收到显式显示命令前禁止自动显示
    var isHiddenByIslandSwitch = false

    init() {
        let screen = Self.bestScreen()
        let width: CGFloat = 220
        let height = IslandSizeCalculator.collapsedShapeHeight
        let x = screen.frame.origin.x + (screen.frame.width - width) / 2
        let y = screen.frame.origin.y + screen.frame.height - Self.islandTopOffset(for: screen) - height

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
        // 锚定期间不跟随鼠标，否则审批面板展开后会被拽回鼠标所在屏
        guard pinnedScreenID == nil else { return }
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
        let screenTop = screen.frame.origin.y + screen.frame.height - Self.islandTopOffset(for: screen)
        // 窗口向上延伸 windowTopExtension，使屏幕顶端在窗口内部
        let y = screenTop - currentFrame.height + Self.windowTopExtension
        setFrameDirect(NSRect(x: x, y: y, width: currentFrame.width, height: currentFrame.height), display: true)
    }

    func applySpaceBehavior() {
        let allSpaces = UserDefaults.standard.bool(forKey: "showOnAllSpaces")
        if allSpaces {
            collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        } else {
            collectionBehavior = [.fullScreenAuxiliary, .stationary]
        }
    }

    @objc private func activeSpaceDidChange(_ note: Notification) {
        // 切换应用期间不自动显示窗口
        guard !isSwitchingApps, !isHiddenByIslandSwitch else { return }

        let hideInFullscreen = UserDefaults.standard.bool(forKey: "hideInFullscreen")
        guard hideInFullscreen else {
            // 不再自动显示窗口——窗口只在明确命令时显示
            return
        }
        // Phase 1: snapshot MainActor-isolated state before leaving the main thread
        let screen = NSScreen.main
        let windowSnapshots: [(screen: NSScreen?, styleMask: NSWindow.StyleMask)] =
            NSApplication.shared.windows.map { ($0.screen, $0.styleMask) }
        let frontApp = NSWorkspace.shared.frontmostApplication

        // Phase 2: slow CGWindowList work off the main thread
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let inFullscreen = screen.map {
                Self.isScreenInFullscreenOffMain($0, windowSnapshots: windowSnapshots, frontApp: frontApp)
            } ?? false
            await MainActor.run {
                guard !self.isSwitchingApps, !self.isHiddenByIslandSwitch else { return }
                if inFullscreen {
                    self.pauseMouseTracking()
                    self.orderOut(nil)
                } else {
                    self.resumeMouseTracking()
                    self.orderFrontRegardless()
                }
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
        let screenTop = screen.frame.origin.y + screen.frame.height - Self.islandTopOffset(for: screen)
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
        let screenTop = screen.frame.origin.y + screen.frame.height - Self.islandTopOffset(for: screen)
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
        let screen = layoutScreen()
        let x: CGFloat
        if let cx = customX {
            x = max(screen.frame.origin.x,
                    min(cx - frame.width / 2, screen.frame.origin.x + screen.frame.width - frame.width))
        } else {
            x = screen.frame.origin.x + (screen.frame.width - frame.width) / 2
        }
        let screenTop = screen.frame.origin.y + screen.frame.height - Self.islandTopOffset(for: screen)
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
                let topY = screen.frame.origin.y + screen.frame.height - Self.islandTopOffset(for: screen) - frame.height + Self.windowTopExtension
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
            // 横滑切换手势（仅收起状态响应）
            if islandState == .collapsed {
                let result = swipeRecognizer.handleScroll(event: event)
                if case .triggered(_) = result {
                    AppSwitcher.shared.switchToNextIsland()
                    return
                }
            }

            if Self.shouldTriggerScrollExpand(
                isEnabled: UserDefaults.standard.bool(forKey: "scrollDownToExpandPanel"),
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
        isHiddenByIslandSwitch = false
        if let currentIsland = AppSwitcher.shared.currentIsland {
            IslandIntegrationSettings.markVisible(currentIsland)
        }
        // 明确要求在鼠标所在屏显示，解除审批期间的锚定
        pinnedScreenID = nil
        let mouseLocation = NSEvent.mouseLocation
        guard let mouseScreen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) else {
            orderFrontRegardless()
            return
        }
        repositionOnScreen(mouseScreen)
        orderFrontRegardless()
    }

    /// 在当前"正在显示的主界面"所在屏幕显示并置顶（审批/问答/计划评审时使用）。
    /// 与 showAtMouseScreen 不同，不依赖鼠标位置，避免多显示器时展开到错误的屏幕。
    func showAtActiveScreen() {
        isHiddenByIslandSwitch = false
        if let currentIsland = AppSwitcher.shared.currentIsland {
            IslandIntegrationSettings.markVisible(currentIsland)
        }
        // 先锚定再重排：锚定后 layoutScreen() 一律返回该屏，
        // 后续的 resizeToFit / setFrame / 鼠标跟随都不会再把面板拉回鼠标所在屏
        let target = Self.activeScreen()
        pinnedScreenID = Self.displayID(of: target)
        repositionOnScreen(target)
        orderFrontRegardless()
    }

    func showWindow() {
        isHiddenByIslandSwitch = false
        if let currentIsland = AppSwitcher.shared.currentIsland {
            IslandIntegrationSettings.markVisible(currentIsland)
        }
        orderFrontRegardless()
    }

    func isFrontmostIslandWindow() -> Bool {
        IslandWindowOwnership.isFrontmostIslandWindow(
            self,
            bundleIdentifiers: ["com.meteorkid.xnook", "dev.xisland.app"]
        )
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

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        guard frameRect.width.isFinite, frameRect.height.isFinite else { return }
        let clampedHeight = max(frameRect.height, Self.collapsedHitHeight)
        // 向上延伸窗口，使屏幕顶端在窗口内部
        let windowHeight = clampedHeight + Self.windowTopExtension
        let screen = layoutScreen()
        let topY = screen.frame.origin.y + screen.frame.height - Self.islandTopOffset(for: screen) - clampedHeight
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
        let pinned = Self.safeFrame(
            NSRect(x: x, y: topY, width: frameRect.width, height: windowHeight),
            screen: screen
        )
        super.setFrame(pinned, display: flag)
    }

    override func setFrame(_ frameRect: NSRect, display displayFlag: Bool, animate animateFlag: Bool) {
        guard frameRect.width.isFinite, frameRect.height.isFinite else { return }
        let clampedHeight = max(frameRect.height, Self.collapsedHitHeight)
        // 向上延伸窗口，使屏幕顶端在窗口内部
        let windowHeight = clampedHeight + Self.windowTopExtension
        let screen = layoutScreen()
        let topY = screen.frame.origin.y + screen.frame.height - Self.islandTopOffset(for: screen) - clampedHeight
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
        let pinned = Self.safeFrame(
            NSRect(x: x, y: topY, width: frameRect.width, height: windowHeight),
            screen: screen
        )
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
