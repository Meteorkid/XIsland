import AppKit
import Combine
import QuartzCore

final class NotchWindow: NSPanel {
    static let maxExpandedWidth: CGFloat = 520
    static let maxExpandedHeight: CGFloat = 600

    private static let expandedPadding: CGFloat = 8
    private static let collapsedHitHeight: CGFloat = 32
    /// 双指下滑展开的最小滚动距离，过滤触控板惯性残余
    static let scrollExpandMinDelta: CGFloat = 2

    static func islandTopOffset(for _: NSScreen) -> CGFloat { 0 }

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
        let height: CGFloat = 50
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
        let y = screenTop - currentFrame.height
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
        let screen = Self.bestScreen()
        let normalizedContentHeight = max(contentHeight, Self.collapsedHitHeight)
        let padding = Self.padding(forContentHeight: normalizedContentHeight)
        let w = contentWidth + padding * 2
        let h = normalizedContentHeight + padding
        let x: CGFloat
        if let cx = customX, cx.isFinite {
            x = max(screen.frame.origin.x,
                    min(cx - w / 2, screen.frame.origin.x + screen.frame.width - w))
        } else {
            x = screen.frame.origin.x + (screen.frame.width - w) / 2
        }
        let screenTop = screen.frame.origin.y + screen.frame.height - Self.islandTopOffset(for: screen)
        let yComputed = screenTop - h
        let rect = Self.safeFrame(NSRect(x: x, y: yComputed, width: w, height: h), screen: screen)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        setFrameDirect(rect, display: display)
        CATransaction.commit()
    }

    func resizeToFitCollapse(contentWidth: CGFloat, contentHeight: CGFloat) {
        let screen = Self.bestScreen()
        let targetW = max(1, contentWidth.isFinite ? contentWidth : 180)
        let targetH = max(contentHeight, Self.collapsedHitHeight)
        let targetX: CGFloat
        if let cx = customX, cx.isFinite {
            targetX = max(screen.frame.origin.x,
                          min(cx - targetW / 2, screen.frame.origin.x + screen.frame.width - targetW))
        } else {
            targetX = screen.frame.origin.x + (screen.frame.width - targetW) / 2
        }
        let screenTop = screen.frame.origin.y + screen.frame.height - Self.islandTopOffset(for: screen)
        let targetY = screenTop - targetH

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
        y = max(sf.minY, min(y, sf.maxY - h))
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
        let screen = Self.bestScreen()
        let x: CGFloat
        if let cx = customX {
            x = max(screen.frame.origin.x,
                    min(cx - frame.width / 2, screen.frame.origin.x + screen.frame.width - frame.width))
        } else {
            x = screen.frame.origin.x + (screen.frame.width - frame.width) / 2
        }
        let screenTop = screen.frame.origin.y + screen.frame.height - Self.islandTopOffset(for: screen)
        let y = screenTop - frame.height
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
                let topY = screen.frame.origin.y + screen.frame.height - Self.islandTopOffset(for: screen) - frame.height
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
        let mouseLocation = NSEvent.mouseLocation
        guard let mouseScreen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) else {
            orderFrontRegardless()
            return
        }
        repositionOnScreen(mouseScreen)
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
        let screen = cachedOrRefreshScreen()
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
        let screen = cachedOrRefreshScreen()
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
            NSRect(x: x, y: topY, width: frameRect.width, height: clampedHeight),
            screen: screen
        )
        super.setFrame(pinned, display: flag)
    }

    override func setFrame(_ frameRect: NSRect, display displayFlag: Bool, animate animateFlag: Bool) {
        guard frameRect.width.isFinite, frameRect.height.isFinite else { return }
        let clampedHeight = max(frameRect.height, Self.collapsedHitHeight)
        let screen = cachedOrRefreshScreen()
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
            NSRect(x: x, y: topY, width: frameRect.width, height: clampedHeight),
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
