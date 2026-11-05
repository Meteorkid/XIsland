import AppKit
import Darwin
import Observation
import SwiftUI

extension Notification.Name {
    static let xislandShowAboutPane = Notification.Name("XIslandShowAboutPane")
    static let xislandShowLicensePane = Notification.Name("XIslandShowLicensePane")
    static let xislandScrollDown = Notification.Name("xislandScrollDown")
    static let xislandCollapse = Notification.Name("xislandCollapse")
    static let xislandToggleActivityLog = Notification.Name("xislandToggleActivityLog")
    static let xislandExportSession = Notification.Name("xislandExportSession")
    static let xislandToggleSearch = Notification.Name("xislandToggleSearch")
    static let xislandTaskAttention = Notification.Name("xislandTaskAttention")
}

/// 跨进程通知前缀：请求目标灵动岛隐藏自身
/// 完整通知名格式：island.switch.hide.{targetAppName}
private let hideNotificationPrefix = "island.switch.hide."

enum PreferencesRouting {
    static let pendingPaneSelectionKey = "XIsland.Preferences.PendingPaneSelection"
    static let aboutPaneValue = "about"
    static let licensePaneValue = "license"
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    typealias StartupAction = @MainActor (AppDelegate) -> Void

    struct LaunchHooks {
        let performInitialStartup: StartupAction
        let performProductionGlobalStartup: StartupAction
        var performLicensedStartup: StartupAction = { _ in }
        var performLicenseLockdown: StartupAction = { _ in }

        static let live = Self(
            performInitialStartup: { appDelegate in
                appDelegate.performInitialStartup()
            },
            performProductionGlobalStartup: { appDelegate in
                appDelegate.performProductionGlobalStartup()
            },
            performLicensedStartup: { appDelegate in
                appDelegate.performLicensedStartup()
            },
            performLicenseLockdown: { appDelegate in
                appDelegate.performLicenseLockdown()
            }
        )
    }

    static private(set) var shared: AppDelegate!
    /// Set when this process lost the single-instance lock and is about to exit; skip normal startup.
    private static var exitingAsDuplicateInstance = false
    private static var singleInstanceLockFD: Int32 = -1

    let sessionManager: SessionManager
    let audioEngine = AudioEngine()
    let updateManager = UpdateManager()
    let quotaTracker: QuotaTracker
    let persistenceManager = SessionPersistenceManager(usesBackgroundWrites: true)
    let themeManager = ThemeManager()
    let integrationSetupManager: IntegrationSetupManager
    let softwareLicense: SoftwareLicenseController?
    private(set) var licensedRuntimeRunning = false
    private var allowsIsolatedLicenseFixture: Bool {
        (testConfiguration.isEnabled || AppPreferences.allowsAcceptanceMode)
            && softwareLicense == nil
            && AppPreferences.allowsLicenseFixture
    }
    private var allowsFeatureActions: Bool { licensedRuntimeRunning || allowsIsolatedLicenseFixture }
    private var socketServer: SocketServer?
    private var hookRepairTimer: Timer?
    private var historyRetentionMaintenance: HistoryRetentionMaintenance?
    private var integrationRefreshTask: Task<Void, Never>?
    private var integrationReminderTask: Task<Void, Never>?
    private var integrationWindow: NSWindow?
    private let integrationClientLauncher = IntegrationClientLauncher()
    private var integrationWindowObserver: NSObjectProtocol?
    private var integrationActivationObserver: NSObjectProtocol?
    private var recheckIntegrationOnActivation = false
    private var approvalGraphMCPPromptPresented = false
    private var isTerminating = false
    private var terminationTask: Task<Void, Never>?
    private enum UpdateTerminationState { case idle, preparing, prepared, committed }
    private var updateTerminationState: UpdateTerminationState = .idle
    var notchWindow: NotchWindow?
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var checkForUpdatesMenuItem: NSMenuItem?
    private var installUpdateMenuItem: NSMenuItem?
    private var diagnosticsWriter: AppDiagnosticsWriter?
    private let testConfiguration: AppTestConfiguration
    private let launchHooks: LaunchHooks
    private var scrollMonitor: Any?
    private var islandHideObserver: NSObjectProtocol?
    private var defaultsObserver: NSObjectProtocol?
    private var linkedIslandPreviewService: LinkedIslandPreviewService?
    private var clearSwitchingAppsWorkItem: DispatchWorkItem?
    private var pendingIslandShowURL: URL?
    private var lastInboundMotionUptime: TimeInterval = -.infinity
    private var hasExplicitIslandVisibilityRequest = false
    private lazy var taskAttentionPresenter = TaskAttentionPresenter(environment: .init(
        isEnabled: { TaskAttentionSettings.isEnabled() },
        isCurrent: { [weak self] in self?.sessionManager.isCurrentTaskAttention($0) == true },
        schedule: { delay, action in
            let work = DispatchWorkItem { MainActor.assumeIsolated { action() } }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
            return { work.cancel() }
        },
        present: { [weak self] in self?.presentTaskAttention($0) }
    ))

    override convenience init() {
        self.init(testConfiguration: AppTestConfiguration.current())
    }

    init(
        testConfiguration: AppTestConfiguration = AppTestConfiguration.current(),
        launchHooks: LaunchHooks = .live,
        softwareLicense: SoftwareLicenseController? = nil
    ) {
        self.testConfiguration = testConfiguration
        self.launchHooks = launchHooks
        self.sessionManager = SessionManager(testConfiguration: testConfiguration)
        self.quotaTracker = QuotaTracker(testConfiguration: testConfiguration, startImmediately: false)
        self.integrationSetupManager = IntegrationSetupManager(environment: testConfiguration.isEnabled ? .isolated : nil)
        let usesLicenseFixture = testConfiguration.isEnabled
            || AppPreferences.isIsolated
            || AppPreferences.allowsAcceptanceMode
        self.softwareLicense = softwareLicense ?? (usesLicenseFixture
            ? nil : SoftwareLicenseController.live())
        super.init()
        sessionManager.onTaskAttention = { [weak self] event in
            self?.taskAttentionPresenter.enqueue(event)
        }
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        guard !testConfiguration.allowsMultipleInstances else { return }

        if !Self.acquireSingleInstanceLock() {
            Self.exitingAsDuplicateInstance = true
            Self.activateOtherInstancesOfThisApp()
            NSApp.terminate(nil)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !Self.exitingAsDuplicateInstance else { return }
        do {
            try testConfiguration.validateIsolation()
            if let runtimeURL = testConfiguration.runtimeURL {
                try FileManager.default.createDirectory(at: runtimeURL, withIntermediateDirectories: true)
            }
        } catch {
            preconditionFailure("Invalid test isolation: \(error.localizedDescription)")
        }
        Self.shared = self
        NSApp.setActivationPolicy(.accessory)

        AutoCollapseSettings.migrate(AppPreferences.defaults, domainName: AppPreferences.persistentDomainName)
        AppPreferences.defaults.register(defaults: [
            "showOnAllSpaces": true,
            AutoCollapseSettings.enabledKey: true,
            AutoCollapseSettings.delayKey: AutoCollapseSettings.defaultDelay,
            "scrollDownToExpandPanel": true,
            "smartSuppression": true,
            "autoHideWhenNoActiveSessions": false,
            "compactBadgesInExpandedView": true,
            "displayTimestamp": true,
            "completedLingerDuration": 120.0,
            "showActivityTicker": true,
            "showCollapsedAgentIcon": true,
            "collapsedRecentTaskLimit": CollapsedTaskSelection.defaultLimit,
            "showCollapsedSessionCount": true,
            "showCollapsedQuota": true,
            "tickerSpeed": 25.0,
            "tickerContentMode": CollapsedTickerContentMode.defaultValue.rawValue,
            "animationIntensity": IslandAnimationIntensity.defaultValue.rawValue,
            "jellyIntensity": IslandJellyIntensity.defaultValue.rawValue,
            "taskAttentionEnabled": true,
        ])
        IslandIntegrationSettings.registerDefaults()
        // 锁屏、睡眠与唤醒驱动的能耗档位。启动即订阅，避免错过首个唤醒事件。
        EnergyGovernor.shared.start()
        configureCompanion()
        ASuiteSettings.registerDefaults()
        configureASuite()
        testConfiguration.applyDefaults()
        do {
            try configureTesting()
        } catch {
            preconditionFailure("Failed to load app test fixture: \(error)")
        }

        launchHooks.performInitialStartup(self)
        softwareLicense?.onAccessChange = { [weak self] allowed in self?.applyLicenseAccess(allowed) }
        applyLicenseAccess(softwareLicense?.allowsAccess ?? allowsIsolatedLicenseFixture)
        softwareLicense?.start()
        if !licensedRuntimeRunning, !AppPreferences.isIsolated { openSoftwareLicense() }

        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                ASuiteSettings.apply()
                self?.notchWindow?.applySpaceBehavior()
            }
        }

        // 监听跨进程通知：对方应用请求本应用隐藏
        // 通知名格式：island.switch.hide.{targetAppName}
        if !testConfiguration.isEnabled, let appName = AppSwitcher.shared.currentAppName {
            let hideNotification = "\(hideNotificationPrefix)\(appName)"
            islandHideObserver = DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name(hideNotification),
                object: nil,
                queue: .main
            ) { [weak self] note in
                let peer = note.userInfo?["source"] as? String
                let shownAt = note.userInfo?["shownAt"] as? TimeInterval
                let motion: IslandSwitchMotion?
                do { motion = try IslandSwitchMotion.decode(userInfo: note.userInfo) }
                catch { return }
                Task { @MainActor [weak self] in
                    self?.hideIslandForSwitch(from: peer, shownAt: shownAt, motion: motion)
                }
            }
        }

        let initialIslandState = NotchContentView.initialIslandState(for: sessionManager)
        sessionManager.currentIslandState = initialIslandState
        refreshDiagnostics(
            islandState: NotchContentView.diagnosticsIslandState(
                for: sessionManager,
                currentState: initialIslandState
            )
        )

        if testConfiguration.opensPreferencesOnLaunch {
            openPreferences()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        requestTermination { sender.reply(toApplicationShouldTerminate: $0) }
    }

    func requestTermination(reply: @escaping @MainActor (Bool) -> Void) -> NSApplication.TerminateReply {
        if Self.exitingAsDuplicateInstance { return .terminateNow }
        switch updateTerminationState {
        case .preparing, .prepared: return .terminateCancel
        case .committed: return .terminateNow
        case .idle: break
        }
        guard terminationTask == nil else { return .terminateLater }
        stopForTermination()
        terminationTask = Task { [weak self] in
            guard let self else { reply(false); return }
            let saved = await sessionManager.drainPersistenceOperations()
            if !saved {
                resumeAfterCancelledTermination()
                let alert = NSAlert()
                alert.messageText = L10n.isChinese ? "历史尚未保存，已取消退出" : "History was not saved. Quit cancelled."
                alert.informativeText = persistenceManager.lastSaveError
                    ?? (L10n.isChinese ? "请恢复可写存储后重试，未保存会话仍保留在窗口中。" : "Restore writable storage and retry. Unsaved sessions remain available.")
                alert.addButton(withTitle: L10n.isChinese ? "好" : "OK")
                if let window = settingsWindow ?? notchWindow { alert.beginSheetModal(for: window, completionHandler: { _ in }) }
            }
            terminationTask = nil
            reply(saved)
        }
        return .terminateLater
    }

    /// helper 启动前先排空已接受的保存；普通退出不能抢在 helper 前结束进程。
    func prepareForUpdateTermination() async -> Bool {
        guard !isTerminating, terminationTask == nil, updateTerminationState == .idle else { return false }
        updateTerminationState = .preparing
        stopForTermination()
        let saved = await sessionManager.drainPersistenceOperations()
        guard saved, !Task.isCancelled else {
            updateTerminationState = .idle
            resumeAfterCancelledTermination()
            return false
        }
        updateTerminationState = .prepared
        return true
    }

    func cancelUpdateTermination() {
        guard updateTerminationState == .prepared else { return }
        updateTerminationState = .idle
        resumeAfterCancelledTermination()
    }

    /// 仅 helper 已启动后调用；与 NSApp.terminate 同一主线程回合同步执行。
    func commitUpdateTermination() -> Bool {
        guard updateTerminationState == .prepared else { return false }
        updateTerminationState = .committed
        return true
    }

    private func stopForTermination() {
        socketServer?.stop()
        historyRetentionMaintenance?.stop()
        sessionManager.stopAcceptingPersistenceOperations()
    }

    private func resumeAfterCancelledTermination() {
        guard allowsFeatureActions else { return }
        sessionManager.resumeAcceptingPersistenceOperations()
        if !testConfiguration.isEnabled { startSocketServer(); historyRetentionMaintenance?.startInBackground() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        ASuiteEventRouter.shared.stop()
        softwareLicense?.stop()
        quotaTracker.suspendPolling()
        taskAttentionPresenter.cancel()
        linkedIslandPreviewService?.stop()
        linkedIslandPreviewService = nil
        isTerminating = true
        socketServer?.stop()
        hookRepairTimer?.invalidate()
        historyRetentionMaintenance?.stop()
        integrationRefreshTask?.cancel()
        integrationReminderTask?.cancel()
        integrationSetupManager.shutdown()
        if let observer = integrationWindowObserver { NotificationCenter.default.removeObserver(observer) }
        if let observer = integrationActivationObserver { NotificationCenter.default.removeObserver(observer) }
        if let observer = islandHideObserver {
            DistributedNotificationCenter.default().removeObserver(observer)
            islandHideObserver = nil
        }
        if let observer = defaultsObserver {
            NotificationCenter.default.removeObserver(observer)
            defaultsObserver = nil
        }
        if let monitor = scrollMonitor {
            NSEvent.removeMonitor(monitor)
            scrollMonitor = nil
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            guard url.scheme == AppSwitcher.shared.currentURLScheme else { continue }
            handleIslandCommand(url)
        }
    }

    private func handleIslandCommand(_ url: URL) {
        guard let targetName = url.host,
              targetName == AppSwitcher.shared.currentAppName,
              url.path == "/show" else { return }
        let motion: IslandSwitchMotion?
        do { motion = try IslandSwitchMotion.decode(url: url) }
        catch { return }
        guard let attentionAdmission = IslandAttentionEpoch.admission(for: url, motion: motion) else { return }
        if let motion {
            guard motion.isTimely(at: ProcessInfo.processInfo.systemUptime),
                  motion.issuedUptime > lastInboundMotionUptime else { return }
            if notchWindow == nil, let pendingIslandShowURL,
               let pending = try? IslandSwitchMotion.decode(url: pendingIslandShowURL),
               pending.issuedUptime >= motion.issuedUptime { return }
        }
        hasExplicitIslandVisibilityRequest = true
        guard allowsFeatureActions else { pendingIslandShowURL = url; return }
        guard let window = notchWindow else { pendingIslandShowURL = url; return }
        pendingIslandShowURL = nil
        if let motion { lastInboundMotionUptime = motion.issuedUptime }
        AppSwitcher.shared.cancelSwitch()
        clearSwitchingAppsWorkItem?.cancel()
        window.beginInboundHandoff(motion: motion) { [weak self, weak window] generation in
            guard let self, let window else { return }
            guard IslandAttentionEpoch.isCurrent(attentionAdmission) else {
                if window.isCurrentHandoff(generation) { window.hideWindowForIslandSwitch(animated: false) }
                return
            }
            // 两进程使用同一系统 uptime 起点；内容准备完成后再发送已显示回执。
            let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                || AppPreferences.defaults.bool(forKey: "reduceMotion") || AppPreferences.defaults.bool(forKey: "disableAnimations")
            let readyMotion = motion?.arriving(at: window.switchGeometry)
                .starting(at: ProcessInfo.processInfo.systemUptime + 0.05,
                                              reduceMotion: reduceMotion)
            window.showPreparedHandoff(generation: generation, motion: readyMotion)
            self.scheduleClearSwitchingApps(window: window, delay: 1.5)
            self.requestOtherIslandsToHide(motion: readyMotion)
        }
    }

    func hideIslandForSwitch(from peer: String? = nil, shownAt: TimeInterval? = nil,
                             using switcher: AppSwitcher? = nil, motion: IslandSwitchMotion? = nil) {
        let switcher = switcher ?? .shared
        // 对端未运行时，迟到的让位请求不能把岛隐藏掉——没有接管者，用户会找不到窗口。
        guard switcher.isOtherAppRunning() else {
            NSLog("[XIsland] ignore hide request: no peer island is running")
            return
        }
        guard let window = notchWindow,
              switcher.acceptPeerHideRequest(from: peer, shownAt: shownAt,
                  after: window.lastExplicitShowTime, motion: motion) else { return }
        hasExplicitIslandVisibilityRequest = true
        clearSwitchingAppsWorkItem?.cancel()
        window.hideWindowForIslandSwitch(motion: switcher.acceptedPeerMotion)
    }

    private func scheduleClearSwitchingApps(window: NotchWindow, delay: TimeInterval) {
        clearSwitchingAppsWorkItem?.cancel()
        let handoffGeneration = window.handoffState.generation
        let work = DispatchWorkItem { [weak self, weak window] in
            guard let window, handoffGeneration == window.handoffState.generation else { return }
            self?.clearSwitchingProtection(window: window)
        }
        clearSwitchingAppsWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func clearSwitchingProtection(window: NotchWindow, using switcher: AppSwitcher? = nil) {
        guard !(switcher ?? .shared).isSwitchInProgress,
              window.handoffState.pendingPreparation == nil,
              !window.handoffState.isPresentingInbound,
              !window.handoffState.isFadingOut else { return }
        window.isSwitchingApps = false
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        installApplicationMenuItems()
        softwareLicense?.revalidate()
    }

    private func setupLinkedIslandPreviewService() {
        let service = LinkedIslandPreviewService(app: .xisland) { [weak self] in
            self?.captureLinkedIslandPreview()
        }
        linkedIslandPreviewService = service
        service.start()
    }

    private func captureLinkedIslandPreview() -> IslandPreviewSnapshot? {
        guard let window = notchWindow, Self.canCaptureLinkedIslandPreview(window),
              let content = window.contentView, content.window === window,
              let background = IslandSlideAnimator.background(in: content), background.window === window,
              window.switchGeometry != nil else { return nil }
        content.layoutSubtreeIfNeeded()
        guard Self.canCaptureLinkedIslandPreview(window), let outline = window.switchGeometry else { return nil }
        do {
            let snapshot = try LinkedIslandPreviewCanvas.capture(view: content, outline: outline)
            guard Self.canCaptureLinkedIslandPreview(window), window.switchGeometry == outline else { return nil }
            return snapshot
        } catch is LinkedIslandPreviewCanvas.CaptureError {
            // 当前视图不适合捕获，私有连接返回 unavailable，提交仍走原 /show。
            return nil
        } catch {
            NSLog("Linked island preview capture failed (%@)", String(reflecting: type(of: error)))
            return nil
        }
    }

    private static func canCaptureLinkedIslandPreview(_ window: NotchWindow) -> Bool {
        !window.isVisible && window.islandState == .collapsed && window.isCollapsedPreviewReady
            && !window.isInteractiveSwitchPreviewActive && !window.isSwitchingApps
            && !window.isHandoffLayoutLocked && !window.isPreviewingIslandSwitch && !window.isDragging
            && !window.swipeRecognizer.isActive && window.handoffState.pendingPreparation == nil
            && window.handoffState.pendingPresentation == nil
    }

    private func setupNotchWindow() {
        let window = NotchWindow()
        let hostView = FirstMouseHostingView(
            rootView: NotchContentView(onSizeChange: { [weak window] w, h, display in
                window?.resizeToFit(contentWidth: w, contentHeight: h, display: display)
            }, windowProvider: { [weak window] in window })
            .environment(sessionManager)
            .environment(audioEngine)
            .environment(updateManager)
            .environment(quotaTracker)
            .environment(persistenceManager)
            .environment(themeManager)
            .defaultAppStorage(AppPreferences.defaults)
        )
        hostView.frame = window.contentView!.bounds
        hostView.autoresizingMask = [.width, .height]
        if #available(macOS 13.0, *) {
            hostView.sizingOptions = []
        }
        window.contentView?.addSubview(hostView)
        notchWindow = window
        window.allowsAutomaticScreenChange = { [weak self] in self?.sessionManager.protectsInteraction != true }
        themeManager.onSchemeChange = { [weak self] in
            guard let self, let w = self.notchWindow else { return }
            self.updateWindowAppearance(w)
        }
        updateWindowAppearance(window)
        themeManager.startObservingSystemAppearance()

        window.keyEquivalentHandler = { [weak self] event in
            guard let self = self else { return false }
            let flags = event.modifierFlags
            let chars = event.charactersIgnoringModifiers?.lowercased()
            let isCommand = flags.contains(.command)

            if isCommand, let chars = chars {
                switch chars {
                case "y", "n", "1", "2", "3":
                    return self.sessionManager.handleInteractionShortcut(chars)
                case "o":
                    NotificationCenter.default.post(name: .xislandToggleActivityLog, object: nil)
                    return true
                case "e" where flags.contains(.shift):
                    NotificationCenter.default.post(name: .xislandExportSession, object: nil)
                    return true
                case "f":
                    NotificationCenter.default.post(name: .xislandToggleSearch, object: nil)
                    return true
                case "t":
                    self.themeManager.toggleMode()
                    return true
                case "[":
                    self.navigateSession(direction: -1)
                    return true
                case "]":
                    self.navigateSession(direction: 1)
                    return true
                default:
                    break
                }
            }

            // Escape 收起展开的面板
            if chars == "\u{1b}" {
                if self.sessionManager.collapseFocusedInteractionDetail() { return true }
                NotificationCenter.default.post(name: .xislandCollapse, object: nil)
                return true
            }

            return false
        }
    }

    /// 在可见会话列表中按方向导航（direction: -1 = 上一个, +1 = 下一个），支持循环。
    private func navigateSession(direction: Int) {
        let visible = sessionManager.visibleSessions
        guard !visible.isEmpty else { return }

        if let currentId = sessionManager.selectedSessionId,
           let idx = visible.firstIndex(where: { $0.id == currentId }) {
            let next = (idx + direction + visible.count) % visible.count
            sessionManager.selectedSessionId = visible[next].id
        } else {
            sessionManager.selectedSessionId = visible[direction > 0 ? 0 : visible.count - 1].id
        }
    }

    private func setupScrollMonitor() {
        scrollMonitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            MainActor.assumeIsolated { self?.handleScrollEvent(event) }
        }
    }

    private func handleScrollEvent(_ event: NSEvent) {
        guard let window = notchWindow else { return }
        let mouseLocation = NSEvent.mouseLocation

        if window.handleIslandSwipe(event) { return }
        guard !window.isSwitchingApps, event.momentumPhase.isEmpty else { return }

        guard NotchWindow.shouldTriggerScrollExpand(
            isEnabled: AppPreferences.defaults.bool(forKey: "scrollDownToExpandPanel"),
            isVisible: window.isVisible,
            isCollapsed: window.islandState == .collapsed,
            isPrecise: event.hasPreciseScrollingDeltas,
            deltaY: event.scrollingDeltaY,
            windowFrame: window.frame,
            screenFrame: window.screen?.frame,
            mouseLocation: mouseLocation
        ) else {
            return
        }

        NotificationCenter.default.post(name: .xislandScrollDown, object: nil)
    }

    private func setupMenuBarItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "sparkle", accessibilityDescription: "X Island")
            button.action = #selector(toggleNotch)
            button.target = self
        }

        let menu = NSMenu()
        // 必须显式设置 target：AppDelegate 不在 responder chain 上，
        // target 为 nil 时这些菜单项点了不会有任何反应。
        let showItem = NSMenuItem(title: "Show Island", action: #selector(showNotch), keyEquivalent: "s")
        showItem.target = self
        menu.addItem(showItem)
        let setupItem = NSMenuItem(title: integrationSetupTitle, action: #selector(showIntegrationSetup as () -> Void), keyEquivalent: "")
        setupItem.target = self
        menu.addItem(setupItem)
        let licenseItem = NSMenuItem(title: L10n.isChinese ? "软件授权…" : "Software License…", action: #selector(openSoftwareLicense), keyEquivalent: "")
        licenseItem.target = self
        menu.addItem(licenseItem)
        menu.addItem(NSMenuItem.separator())
        let checkForUpdatesItem = NSMenuItem(
            title: "Check for Updates...",
            action: #selector(checkForUpdatesFromMenu),
            keyEquivalent: ""
        )
        let installUpdateItem = NSMenuItem(
            title: "Install Update...",
            action: #selector(installUpdateFromMenu),
            keyEquivalent: ""
        )
        installUpdateItem.isHidden = true
        checkForUpdatesItem.target = self
        installUpdateItem.target = self
        menu.addItem(checkForUpdatesItem)
        menu.addItem(installUpdateItem)
        let preferencesItem = NSMenuItem(title: L10n.settings + "…", action: #selector(openPreferences), keyEquivalent: ",")
        preferencesItem.target = self
        menu.addItem(preferencesItem)
        menu.addItem(NSMenuItem.separator())
        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        statusItem?.menu = menu
        checkForUpdatesMenuItem = checkForUpdatesItem
        installUpdateMenuItem = installUpdateItem
        refreshUpdateMenuState()
    }

    private func startSocketServer() {
        guard licensedRuntimeRunning else { return }
        socketServer?.stop()
        socketServer = SocketServer(sessionManager: sessionManager)
        socketServer?.onMCPHandshake = { [weak self] agent in
            self?.integrationSetupManager.recordMCPHandshake(from: agent)
        }
        socketServer?.start()
    }

    private func performInitialStartup() {
        sessionManager.audioEngine = audioEngine
        persistenceManager.setupContainer(storeURL: testConfiguration.storageURL)
        sessionManager.persistenceManager = persistenceManager
        setupMenuBarItem()
        DispatchQueue.main.async { [weak self] in self?.installApplicationMenuItems() }
        observeUpdateState()
        if !testConfiguration.isEnabled { updateManager.startAutoCheck() }
    }

    /// 菜单、授权与历史导出始终可用；监控服务只在有效租约期间启动。
    /// 接通伴端广播。
    ///
    /// 刻意保持"默认关闭"：广播会把会话标题与项目名送到同一 Wi-Fi 下的设备，
    /// 属于隐私暴露，必须由用户在设置里显式开启。这里只接线，不改开关。
    private func configureCompanion() {
        let publisher = CompanionPublisher.shared
        publisher.onRequestState = { [weak self] in self?.sessionManager.sessions ?? [] }
        publisher.onCommand = { [weak self] command in
            guard let self else { return }
            _ = self.sessionManager.handleCompanionCommand(command)
            // 命令处理会改变会话状态（等待态被消费），立即回推让伴端看到结果。
            self.sessionManager.publishToCompanion()
        }
        CompanionSettings.registerDefaults()
        CompanionSettings.apply()
    }

    /// A 类自动化的启动接线：把系统级动作翻译成既有业务操作。
    private func configureASuite() {
        let router = ASuiteEventRouter.shared
        router.onNotificationDecision = { [weak self] action, sessionId, requestId in
            self?.handleASuiteDecision(action, sessionId: sessionId, requestId: requestId)
        }
        router.onReapSessionIDs = { [weak self] ids in
            // 延后到当前事件分发结束：reap → publishToCompanion → sessionsDidChange 若同步重入，
            // 外层会继续用 reap 前的快照评估防休眠与隐藏，得到过期结论。
            Task { @MainActor [weak self] in
                self?.sessionManager.reapStaleInteractionSessions(ids)
            }
        }
        router.start()
    }

    private func handleASuiteDecision(_ action: SystemNotificationAction,
                                      sessionId: String,
                                      requestId: String?) {
        guard let session = sessionManager.sessions.first(where: { $0.id == sessionId }) else { return }
        switch action {
        case .allow, .deny:
            // 三重校验：设置显式允许 + 通知带 requestID + 请求仍存在且 ID 精确匹配。
            // 过期或被消费的请求一律忽略，绝不隐式批准。
            guard AppPreferences.defaults.bool(forKey: ASuiteSettings.notificationsAllowDecisionsKey),
                  let requestId,
                  let pending = session.pendingPermission,
                  pending.id.uuidString == requestId else { return }
            if action == .allow {
                sessionManager.approvePermission(session: session, requestID: pending.id)
            } else {
                sessionManager.denyPermission(session: session, requestID: pending.id)
            }
            SystemNotificationCenter.shared.removeDelivered(sessionId: sessionId, requestId: requestId)
        case .review:
            NSApp.activate(ignoringOtherApps: true)
            showIsland(preferMouseScreen: false, hidePeers: true)
        }
    }

    func applyLicenseAccess(_ allowed: Bool) {
        guard !isTerminating, allowed != licensedRuntimeRunning else { return }
        licensedRuntimeRunning = allowed
        if allowed {
            sessionManager.resumeAcceptingPersistenceOperations()
            integrationSetupManager.resumeAfterLicenseActivation()
            launchHooks.performLicensedStartup(self)
            // 授权恢复后重新接管系统资源：lockdown 时 router 已 stop。
            configureASuite()
            if testConfiguration.runsProductionGlobalStartupSideEffects {
                launchHooks.performProductionGlobalStartup(self)
            }
            if let pendingIslandShowURL { handleIslandCommand(pendingIslandShowURL) }
        } else {
            launchHooks.performLicenseLockdown(self)
            if !AppPreferences.isIsolated { openSoftwareLicense() }
        }
    }

    private func performLicensedStartup() {
        if notchWindow == nil { setupNotchWindow() }
        if testConfiguration.isEnabled {
            // fixture窗口不监听全局输入、不隐藏其他岛体，也不访问真实Agent配置。
            audioEngine.isMuted = true
            notchWindow?.showWindow()
            if CommandLine.arguments.contains("--ui-test-socket") {
                // 测试配置已校验短临时路径；只启用隔离服务，不执行生产自动配置。
                startSocketServer()
            }
        } else {
            setupScrollMonitor()
            scheduleInitialVisibilityResolution()
        }
        if !testConfiguration.isEnabled {
            quotaTracker.resumePolling()
            setupLinkedIslandPreviewService()
            sessionManager.startCleanupTimer()
            // 生产启动和后续周期都执行保留期策略；隔离测试不访问用户历史。
            if !AppPreferences.isIsolated {
                let maintenance = HistoryRetentionMaintenance(manager: persistenceManager, defaults: AppPreferences.defaults)
                historyRetentionMaintenance = maintenance
                maintenance.startInBackground()
            }
        }
    }

    private func performLicenseLockdown() {
        // 授权过期后必须停掉所有系统级资源：热键、通知 delegate、防休眠断言。
        // 否则用户既关不掉它们，也看不到设置页（设置页在未授权时被禁用）。
        ASuiteEventRouter.shared.stop()
        taskAttentionPresenter.cancel()
        clearSwitchingAppsWorkItem?.cancel()
        pendingIslandShowURL = nil
        hasExplicitIslandVisibilityRequest = false
        socketServer?.stop()
        socketServer = nil
        sessionManager.suspendForLicense()
        quotaTracker.suspendPolling()
        historyRetentionMaintenance?.stop()
        hookRepairTimer?.invalidate()
        hookRepairTimer = nil
        integrationRefreshTask?.cancel()
        integrationRefreshTask = nil
        integrationReminderTask?.cancel()
        integrationReminderTask = nil
        integrationSetupManager.shutdown()
        integrationWindow?.close()
        linkedIslandPreviewService?.stop()
        linkedIslandPreviewService = nil
        if let observer = integrationActivationObserver {
            NotificationCenter.default.removeObserver(observer)
            integrationActivationObserver = nil
        }
        if let monitor = scrollMonitor {
            NSEvent.removeMonitor(monitor)
            scrollMonitor = nil
        }
        AppSwitcher.shared.cancelSwitch()
        notchWindow?.close()
        notchWindow = nil
    }

    private func performProductionGlobalStartup() {
        guard licensedRuntimeRunning else { return }
        sessionManager.onIntegrationActivity = { [weak self] agent in
            self?.integrationSetupManager.recordActivity(from: agent)
        }
        integrationSetupManager.onNeedsAttention = { [weak self] in
            self?.scheduleIntegrationReminder()
        }
        startSocketServer()
        integrationRefreshTask = Task { [weak self] in
            await self?.integrationSetupManager.refresh(prepareAutomatically: true)
        }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            if ApprovalContextMapSettings.isEnabled() {
                self?.requestApprovalGraphMCPConfiguration()
            } else {
                await ZeroConfigManager.setApprovalGraphMCPEnabled(false)
            }
        }
        hookRepairTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !self.isTerminating, self.licensedRuntimeRunning else { return }
                self.integrationRefreshTask = Task { [weak self] in
                    await self?.integrationSetupManager.refresh(prepareAutomatically: true)
                }
            }
        }
        integrationActivationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: NSApp, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !self.isTerminating, self.licensedRuntimeRunning,
                      self.recheckIntegrationOnActivation || self.integrationWindow?.isVisible == true else { return }
                self.recheckIntegrationOnActivation = false
                await self.integrationSetupManager.refresh()
            }
        }
    }

    /// First-run consent for the optional local MCP registration. Configuration
    /// files are never changed before this review prompt is accepted.
    func requestApprovalGraphMCPConfiguration(force: Bool = false) {
        guard licensedRuntimeRunning, !AppPreferences.isIsolated,
              ApprovalContextMapSettings.isEnabled(), !approvalGraphMCPPromptPresented else { return }
        approvalGraphMCPPromptPresented = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.approvalGraphMCPPromptPresented = false }
            let home = FileManager.default.homeDirectoryForCurrentUser
            let entries = await IntegrationSetupDiscovery.scan()
            let installed = Set(entries.filter(\.installed).map(\.agent))
            let clients = MCPConfigurationManager.presentClientAgents(homeDirectory: home)
                .filter(installed.contains)
            guard !clients.isEmpty else { return }
            let bridge = home.appendingPathComponent(".xisland/bin/di-bridge").path
            let granted = clients.filter {
                MCPConfigurationManager.isConsentGranted(for: $0, bridgePath: bridge)
            }
            if !granted.isEmpty {
                self.presentMCPConfigurationFailures(
                    await self.configureApprovalGraphMCP(clients: granted, bridge: bridge, home: home)
                )
            }
            let pending = force ? clients : clients.filter {
                MCPConfigurationManager.consentDecision(for: $0, bridgePath: bridge) == nil
            }
            guard !pending.isEmpty else { return }

            let chinese = L10n.effectiveLanguage.hasPrefix("zh")
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = chinese ? "启用审批任务图 MCP？" : "Enable approval graph MCP?"
            let commands = pending.compactMap { agent -> String? in
                guard let path = MCPConfigurationManager.configurationPath(for: agent, homeDirectory: home) else {
                    return nil
                }
                return "\(agent.displayName): \(bridge) mcp-server --agent \(agent.rawValue)\n\(path)"
            }.joined(separator: "\n\n")
            alert.informativeText = chinese
                ? "X Island 将在以下客户端中添加本地 MCP：\n\n\(commands)\n\n它只能读取和提交本地任务图，不能批准命令、回答问题或修改文件。写入后请重启客户端，并在首次调用时确认客户端自己的信任提示。"
                : "X Island will add a local MCP server to these clients:\n\n\(commands)\n\nIt can only read and submit local task graphs. It cannot approve commands, answer questions, or modify files. Restart each client and confirm its own trust prompt on first use."
            alert.addButton(withTitle: chinese ? "配置并允许" : "Configure and Allow")
            alert.addButton(withTitle: chinese ? "保持未启用" : "Keep Disabled")
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn {
                MCPConfigurationManager.recordConsent(true, for: pending, bridgePath: bridge)
                self.presentMCPConfigurationFailures(
                    await self.configureApprovalGraphMCP(clients: pending, bridge: bridge, home: home)
                )
            } else {
                MCPConfigurationManager.recordConsent(false, for: pending, bridgePath: bridge)
            }
        }
    }

    private struct MCPConfigurationFailure: Sendable {
        let agent: AgentType
        let message: String
    }

    private func configureApprovalGraphMCP(clients: [AgentType], bridge: String,
                                           home: URL) async -> [MCPConfigurationFailure] {
        let failures: [MCPConfigurationFailure]
        do {
            failures = try await IntegrationSetupIO.run { () -> [MCPConfigurationFailure] in
                var failures: [MCPConfigurationFailure] = []
                ZeroConfigManager.syncCommandLineTools()
                for agent in clients {
                    guard !Task.isCancelled, ZeroConfigManager.isAutoConfigEnabled(for: agent) else { continue }
                    do {
                        _ = try MCPConfigurationManager.configure(agent, bridgePath: bridge, homeDirectory: home)
                    } catch {
                        failures.append(MCPConfigurationFailure(
                            agent: agent, message: error.localizedDescription
                        ))
                    }
                }
                return failures
            }
        } catch {
            failures = clients.map { MCPConfigurationFailure(
                agent: $0, message: error.localizedDescription
            ) }
        }
        await integrationSetupManager.refresh(prepareAutomatically: true)
        return failures
    }

    private func presentMCPConfigurationFailures(_ failures: [MCPConfigurationFailure]) {
        guard !failures.isEmpty else { return }
        let chinese = L10n.effectiveLanguage.hasPrefix("zh")
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = chinese ? "部分 MCP 配置未完成" : "Some MCP configurations were not completed"
        alert.informativeText = failures
            .map { "\($0.agent.displayName): \($0.message)" }
            .joined(separator: "\n")
        alert.addButton(withTitle: chinese ? "好" : "OK")
        alert.runModal()
    }

    func configureTesting() throws {
        guard testConfiguration.isEnabled else { return }

        if let diagnosticsPath = testConfiguration.diagnosticsPath {
            diagnosticsWriter = AppDiagnosticsWriter(outputURL: URL(fileURLWithPath: diagnosticsPath))
        }

        try AppTestFixtureLoader.load(
            configuration: testConfiguration,
            into: sessionManager,
            updateManager: updateManager
        )
    }

    private func installApplicationMenuItems() {
        guard let mainMenu = NSApp.mainMenu,
              let appMenuItem = mainMenu.items.first,
              let appSubmenu = appMenuItem.submenu
        else {
            return
        }

        let settingsIndex = routeSettingsMenuItem(in: appSubmenu) ?? min(1, appSubmenu.items.count)
        if appSubmenu.items.contains(where: { $0.action == #selector(checkForUpdatesFromMenu) }) {
            return
        }

        let checkForUpdatesItem = NSMenuItem(
            title: "Check for Updates...",
            action: #selector(checkForUpdatesFromMenu),
            keyEquivalent: ""
        )
        checkForUpdatesItem.target = self
        appSubmenu.insertItem(checkForUpdatesItem, at: settingsIndex)
        appSubmenu.insertItem(NSMenuItem.separator(), at: settingsIndex + 1)

        // 快捷键菜单项
        let shortcuts = [
            (title: L10n.shortcutToggleTheme, key: "t", modifiers: NSEvent.ModifierFlags.command),
            (title: L10n.shortcutSearch, key: "f", modifiers: NSEvent.ModifierFlags.command),
            (title: L10n.shortcutExport, key: "e", modifiers: [.command, .shift]),
            (title: L10n.shortcutPrevious, key: "[", modifiers: NSEvent.ModifierFlags.command),
            (title: L10n.shortcutNext, key: "]", modifiers: NSEvent.ModifierFlags.command),
        ]
        for shortcut in shortcuts {
            let item = NSMenuItem(title: shortcut.title, action: nil, keyEquivalent: shortcut.key)
            item.keyEquivalentModifierMask = shortcut.modifiers
            appSubmenu.insertItem(item, at: appSubmenu.items.count)
        }
    }

    @discardableResult
    func routeSettingsMenuItem(in menu: NSMenu) -> Int? {
        guard let index = menu.items.firstIndex(where: {
            $0.action == #selector(openPreferences)
                || ($0.keyEquivalent == "," && $0.keyEquivalentModifierMask == .command)
        }) else { return nil }
        menu.items[index].target = self
        menu.items[index].action = #selector(openPreferences)
        return index
    }

    @objc private func toggleNotch() {
        guard allowsFeatureActions else { openSoftwareLicense(); return }
        if let w = notchWindow {
            if w.isVisible {
                AppSwitcher.shared.cancelSwitch()
                w.orderOut(nil)
            } else {
                showIsland(preferMouseScreen: false, hidePeers: true)
            }
        }
    }

    @objc private func showNotch() {
        showIsland(preferMouseScreen: false, hidePeers: true)
    }

    private func scheduleInitialVisibilityResolution() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.resolveInitialIslandVisibility()
        }
    }

    private func resolveInitialIslandVisibility() {
        guard !hasExplicitIslandVisibilityRequest, !AppSwitcher.shared.isSwitchInProgress else { return }
        guard let currentIsland = AppSwitcher.shared.currentIsland else {
            showIsland(preferMouseScreen: false, hidePeers: false)
            return
        }

        let otherInstalled = AppSwitcher.shared.otherIslandNames.contains { AppSwitcher.shared.isIslandInstalled(named: $0) }
        let preferredIsland = IslandIntegrationSettings.preferredStartupIsland(
            currentApp: currentIsland,
            otherAppInstalled: otherInstalled
        )
        let preferredVisible = AppSwitcher.shared.isIslandVisible(named: preferredIsland.rawValue)
        let shouldShow = IslandIntegrationSettings.shouldShowOnLaunch(
            currentApp: currentIsland,
            preferredApp: preferredIsland,
            preferredAppVisible: preferredVisible
        )

        guard shouldShow else { return }

        showIsland(preferMouseScreen: false, hidePeers: preferredIsland == currentIsland)
    }

    private func showIsland(preferMouseScreen: Bool, hidePeers: Bool) {
        guard allowsFeatureActions else { openSoftwareLicense(); return }
        guard let window = notchWindow else { return }
        hasExplicitIslandVisibilityRequest = true
        AppSwitcher.shared.cancelSwitch()

        if preferMouseScreen {
            window.showAtMouseScreen()
        } else {
            window.showWindow()
        }

        guard hidePeers else { return }
        requestOtherIslandsToHide()
    }

    /// 提醒只争取岛的显示权，不激活应用或替用户打开/确认任务详情。
    func presentTaskAttention(_ event: TaskAttentionEvent) {
        guard !isTerminating, allowsFeatureActions, TaskAttentionSettings.isEnabled(),
              sessionManager.isCurrentTaskAttention(event), let window = notchWindow else { return }
        hasExplicitIslandVisibilityRequest = true
        pendingIslandShowURL = nil
        clearSwitchingAppsWorkItem?.cancel()
        IslandAttentionEpoch.advance()
        AppSwitcher.shared.cancelSwitch()
        window.protectsTaskAttention = true
        if NSApp.isHidden, !testConfiguration.isEnabled { NSApp.unhideWithoutActivation() }
        window.showAtActiveScreen(pinUntilCollapse: event.kind != .completion || sessionManager.hasInteraction)
        requestOtherIslandsToHide()
        NotificationCenter.default.post(name: .xislandTaskAttention, object: window,
                                        userInfo: ["event": event])

        // WindowServer 可见性可能滞后一帧；仅在仍拥有这次显示意图时重发让位通知。
        let shownAt = window.lastExplicitShowTime
        for delay in [0.1, 0.35] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak window] in
                guard let self, let window, !self.isTerminating, window.isVisible,
                      window.lastExplicitShowTime == shownAt, !window.isSwitchingApps,
                      !AppSwitcher.shared.isSwitchInProgress else { return }
                self.requestOtherIslandsToHide()
            }
        }
    }

    private func requestOtherIslandsToHide(motion: IslandSwitchMotion? = nil) {
        for otherIslandName in AppSwitcher.shared.otherIslandNames {
            let hideNotification = "\(hideNotificationPrefix)\(otherIslandName)"
            postHideNotification(hideNotification, motion: motion)
        }
    }

    private var integrationSetupTitle: String {
        L10n.effectiveLanguage.hasPrefix("zh") ? "软件接入与授权…" : "App Connections…"
    }

    private func scheduleIntegrationReminder() {
        guard !isTerminating, !testConfiguration.isEnabled, integrationWindow?.isVisible != true,
              integrationReminderTask == nil else { return }
        integrationReminderTask = Task { [weak self] in
            defer { self?.integrationReminderTask = nil }
            // 不盖住用户正在处理的真实审批；不因正在忙而丢掉首次提醒。
            while let self, !Task.isCancelled, self.integrationSetupManager.hasUnpresentedReminder {
                let hasInteraction = self.sessionManager.sessions.contains {
                    $0.pendingPermission != nil || $0.pendingQuestion != nil || $0.pendingPlanReview != nil
                }
                if !hasInteraction {
                    self.showIntegrationSetup()
                    return
                }
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    @objc func showIntegrationSetup() {
        showIntegrationSetup(focusing: nil)
    }

    func showIntegrationSetup(focusing agent: AgentType?) {
        guard allowsFeatureActions else { openSoftwareLicense(); return }
        let request = agent.map { IntegrationSetupFocusRequest(agent: $0) }
        if let window = integrationWindow, window.isVisible {
            if let request {
                let view = integrationSetupHost(focusRequest: request)
                if let host = window.contentView as? NSHostingView<IntegrationSetupHost> {
                    host.rootView = view
                } else {
                    window.contentView = NSHostingView(rootView: view)
                }
            }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 680, height: 640),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = L10n.effectiveLanguage.hasPrefix("zh") ? "X Island · 软件接入与授权" : "X Island · App Connections"
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        integrationClientLauncher.reset()
        panel.contentView = NSHostingView(rootView: integrationSetupHost(focusRequest: request))
        panel.center()
        integrationWindow = panel
        integrationSetupManager.markPresented()
        if !testConfiguration.isEnabled { integrationSetupManager.beginMonitoring() }
        if let observer = integrationWindowObserver { NotificationCenter.default.removeObserver(observer) }
        integrationWindowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: panel, queue: .main
        ) { [weak self, weak panel] _ in
            Task { @MainActor [weak self, weak panel] in
                guard let self, let panel, self.integrationWindow === panel else { return }
                self.integrationSetupManager.endMonitoring()
                self.integrationSetupManager.markPresented()
                self.integrationClientLauncher.reset()
                self.integrationWindow = nil
            }
        }
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func integrationSetupHost(focusRequest: IntegrationSetupFocusRequest?) -> IntegrationSetupHost {
        IntegrationSetupHost(
            manager: integrationSetupManager,
            onOpenClient: { [weak self] in self?.openIntegrationClient($0) },
            onOpenGuide: { [weak self] agent in
                guard self?.testConfiguration.isEnabled == false else { return }
                if let url = IntegrationSetupDescriptor.descriptor(for: agent).setupURL { NSWorkspace.shared.open(url) }
            },
            onLater: { [weak self] in self?.integrationWindow?.close() },
            onPrepareFiles: { [weak self] agent in
                Task { @MainActor [weak self] in
                    guard let self, !self.testConfiguration.isEnabled,
                          let url = await self.integrationSetupManager.prepareFiles(for: agent),
                          !Task.isCancelled else { return }
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }, focusRequest: focusRequest, clientLauncher: integrationClientLauncher)
    }

    private func openIntegrationClient(_ agent: AgentType) {
        guard !testConfiguration.isEnabled else { return }
        let url = integrationSetupManager.appURL(for: agent)
        Task { @MainActor [weak self] in
            guard let self, !self.isTerminating else { return }
            if await self.integrationClientLauncher.open(agent, at: url) {
                self.recheckIntegrationOnActivation = true
            }
        }
    }

    @objc func checkForUpdatesFromMenu() {
        AppPreferences.defaults.set(
            PreferencesRouting.aboutPaneValue,
            forKey: PreferencesRouting.pendingPaneSelectionKey
        )
        openPreferences()
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .xislandShowAboutPane, object: nil)
        }
        Task { @MainActor in
            await updateManager.checkForUpdates()
        }
    }

    @objc private func installUpdateFromMenu() {
        Task { @MainActor in
            await updateManager.installUpdate()
        }
    }

    /// 恢复旧系统窗口不应盖住首次接入引导；明确菜单操作直接走 openPreferences。
    func routeSettingsScene() {
        guard allowsFeatureActions else { openSoftwareLicense(); return }
        guard !integrationSetupManager.rows.isEmpty, !integrationSetupManager.isRefreshing,
              !integrationSetupManager.hasUnpresentedReminder, integrationWindow?.isVisible != true else { return }
        openPreferences()
    }

    @objc func openPreferences() {
        installApplicationMenuItems()

        if let w = settingsWindow, w.isVisible {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let previousPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.regular)

        let w = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        w.isFloatingPanel = true
        w.hidesOnDeactivate = false
        w.title = "X Island Settings"
        w.identifier = NSUserInterfaceItemIdentifier("xisland.preferences")
        if let screen = notchWindow?.screen ?? NSScreen.main {
            let sf = screen.visibleFrame
            let x = sf.origin.x + (sf.width - 760) / 2
            let y = sf.origin.y + (sf.height - 520) / 2
            w.setFrameOrigin(NSPoint(x: x, y: y))
        } else {
            w.center()
        }
        w.isReleasedWhenClosed = false
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        w.contentView = NSHostingView(
            rootView: PreferencesView()
                .environment(sessionManager)
                .environment(audioEngine)
                .environment(updateManager)
                .environment(quotaTracker)
                .environment(persistenceManager)
                .environment(themeManager)
                .environment(\.softwareLicenseController, softwareLicense)
            .defaultAppStorage(AppPreferences.defaults)
        )

        settingsWindow = w
        w.level = .statusBar + 2
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: w,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                NSApp.setActivationPolicy(previousPolicy)
                self?.settingsWindow = nil
            }
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    @objc func openSoftwareLicense() {
        AppPreferences.defaults.set(PreferencesRouting.licensePaneValue, forKey: PreferencesRouting.pendingPaneSelectionKey)
        openPreferences()
        NotificationCenter.default.post(name: .xislandShowLicensePane, object: nil)
    }

    /// Apply the resolved color scheme to the notch window.
    func updateWindowAppearance(_ window: NSWindow) {
        let scheme = themeManager.resolvedScheme
        window.appearance = scheme == .dark
            ? NSAppearance(named: .darkAqua)
            : NSAppearance(named: .aqua)
    }

    /// Returns false if another instance is already running (exclusive lock held).
    private static func acquireSingleInstanceLock() -> Bool {
        let dir = (NSHomeDirectory() as NSString).appendingPathComponent(".xisland")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = (dir as NSString).appendingPathComponent("instance.lock")
        let fd = open(path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { return true }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            close(fd)
            return false
        }
        singleInstanceLockFD = fd
        return true
    }

    private static func activateOtherInstancesOfThisApp() {
        guard let bid = Bundle.main.bundleIdentifier else { return }
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bid)
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        for app in others {
            app.activate(options: [.activateAllWindows])
        }
    }

    private func observeUpdateState() {
        withObservationTracking {
            _ = updateManager.state
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.refreshUpdateMenuState()
                self?.refreshDiagnostics(islandState: self?.sessionManager.diagnosticsIslandState ?? "collapsed")
                self?.observeUpdateState()
            }
        }

        withObservationTracking {
            _ = updateManager.latestRelease
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.refreshUpdateMenuState()
                self?.refreshDiagnostics(islandState: self?.sessionManager.diagnosticsIslandState ?? "collapsed")
                self?.observeUpdateState()
            }
        }
    }

    func refreshDiagnostics(islandState: String) {
        guard testConfiguration.isEnabled, let diagnosticsWriter else { return }

        let snapshot = AppDiagnosticsSnapshot.make(
            sessionManager: sessionManager,
            updateManager: updateManager,
            islandState: islandState,
            preferencesVisible: settingsWindow?.isVisible == true
        )

        do {
            try diagnosticsWriter.write(snapshot)
        } catch {
            NSLog("Failed to write app diagnostics: \(error)")
        }
    }

    func refreshDiagnostics(islandState: IslandState) {
        refreshDiagnostics(islandState: islandState.diagnosticsValue)
    }

    private func refreshUpdateMenuState() {
        let imageName: String

        switch updateManager.state {
        case .updateAvailable(let version):
            checkForUpdatesMenuItem?.title = "Update Available: \(version)"
            checkForUpdatesMenuItem?.isEnabled = true
            // 只有存在 DMG 资产时才显示安装菜单
            let hasDMG = updateManager.latestRelease?.dmgURL != nil
            installUpdateMenuItem?.title = hasDMG ? "Install \(version)..." : "Download \(version)..."
            installUpdateMenuItem?.isHidden = false
            installUpdateMenuItem?.isEnabled = hasDMG
            imageName = "arrow.down.circle.fill"
        case .checking:
            checkForUpdatesMenuItem?.title = "Checking for Updates..."
            checkForUpdatesMenuItem?.isEnabled = false
            installUpdateMenuItem?.isHidden = true
            imageName = "arrow.triangle.2.circlepath.circle"
        case .installing(let stage):
            checkForUpdatesMenuItem?.title = "Installing Update (\(stage))..."
            checkForUpdatesMenuItem?.isEnabled = false
            installUpdateMenuItem?.isHidden = true
            imageName = "arrow.down.circle.fill"
        case .upToDate:
            checkForUpdatesMenuItem?.title = "Up to Date"
            checkForUpdatesMenuItem?.isEnabled = true
            installUpdateMenuItem?.isHidden = true
            imageName = "sparkle"
        case .failed:
            checkForUpdatesMenuItem?.title = "Check for Updates..."
            checkForUpdatesMenuItem?.isEnabled = true
            installUpdateMenuItem?.isHidden = updateManager.latestRelease?.dmgURL == nil
            installUpdateMenuItem?.title = "Install Update..."
            installUpdateMenuItem?.isEnabled = updateManager.latestRelease?.dmgURL != nil
            imageName = "exclamationmark.circle"
        case .idle:
            checkForUpdatesMenuItem?.title = "Check for Updates..."
            checkForUpdatesMenuItem?.isEnabled = true
            if let version = updateManager.latestRelease?.normalizedVersion,
               updateManager.latestRelease?.dmgURL != nil,
               UpdateManager.isRemoteVersionNewer(version, than: updateManager.currentVersion) {
                installUpdateMenuItem?.title = "Install \(version)..."
                installUpdateMenuItem?.isHidden = false
                installUpdateMenuItem?.isEnabled = true
                imageName = "arrow.down.circle.fill"
            } else {
                installUpdateMenuItem?.isHidden = true
                imageName = "sparkle"
            }
        }

        statusItem?.button?.image = NSImage(
            systemSymbolName: imageName,
            accessibilityDescription: "X Island"
        )
    }

    private func postHideNotification(_ name: String, motion: IslandSwitchMotion? = nil) {
        guard !testConfiguration.isEnabled, !AppPreferences.isIsolated,
              notchWindow?.isVisible == true else { return }
        var info: [String: Any] = ["source": AppSwitcher.shared.currentAppName ?? "",
                                   "shownAt": notchWindow?.lastExplicitShowTime ?? 0]
        motion?.userInfo.forEach { info[$0.key] = $0.value }
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name(name),
            object: nil,
            userInfo: info,
            deliverImmediately: true
        )
    }
}

final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
