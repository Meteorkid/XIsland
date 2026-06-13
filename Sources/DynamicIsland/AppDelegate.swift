import AppKit
import Darwin
import Observation
import SwiftUI

extension Notification.Name {
    static let xislandShowAboutPane = Notification.Name("XIslandShowAboutPane")
    static let xislandCollapse = Notification.Name("xislandCollapse")
    static let xislandToggleActivityLog = Notification.Name("xislandToggleActivityLog")
    static let xislandExportSession = Notification.Name("xislandExportSession")
    static let xislandToggleSearch = Notification.Name("xislandToggleSearch")
}

enum PreferencesRouting {
    static let pendingPaneSelectionKey = "XIsland.Preferences.PendingPaneSelection"
    static let aboutPaneValue = "about"
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    typealias StartupAction = @MainActor (AppDelegate) -> Void

    struct LaunchHooks {
        let performInitialStartup: StartupAction
        let performProductionGlobalStartup: StartupAction

        static let live = Self(
            performInitialStartup: { appDelegate in
                appDelegate.performInitialStartup()
            },
            performProductionGlobalStartup: { appDelegate in
                appDelegate.performProductionGlobalStartup()
            }
        )
    }

    static private(set) var shared: AppDelegate!
    /// Set when this process lost the single-instance lock and is about to exit; skip normal startup.
    private static var exitingAsDuplicateInstance = false
    private static var singleInstanceLockFD: Int32 = -1

    let sessionManager = SessionManager()
    let audioEngine = AudioEngine()
    let updateManager = UpdateManager()
    let quotaTracker = QuotaTracker()
    let persistenceManager = SessionPersistenceManager()
    let themeManager = ThemeManager()
    private var socketServer: SocketServer?
    private var hookRepairTimer: Timer?
    private var notchWindow: NotchWindow?
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var checkForUpdatesMenuItem: NSMenuItem?
    private var installUpdateMenuItem: NSMenuItem?
    private var diagnosticsWriter: AppDiagnosticsWriter?
    private let testConfiguration: AppTestConfiguration
    private let launchHooks: LaunchHooks

    override init() {
        self.testConfiguration = AppTestConfiguration.current()
        self.launchHooks = .live
        super.init()
    }

    init(
        testConfiguration: AppTestConfiguration = AppTestConfiguration.current(),
        launchHooks: LaunchHooks = .live
    ) {
        self.testConfiguration = testConfiguration
        self.launchHooks = launchHooks
        super.init()
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
        Self.shared = self
        NSApp.setActivationPolicy(.accessory)

        UserDefaults.standard.register(defaults: [
            "showOnAllSpaces": true,
            "autoCollapseDelay": 3.0,
            "expandedInactivityAutoHideDelay": 10.0,
            "hoverExitCollapseDelay": 0.5,
            "smartSuppression": true,
            "autoHideWhenNoActiveSessions": false,
            "compactBadgesInExpandedView": true,
            "displayTimestamp": true,
            "completedLingerDuration": 120.0,
        ])
        testConfiguration.applyDefaults()
        do {
            try configureTesting()
        } catch {
            preconditionFailure("Failed to load app test fixture: \(error)")
        }

        launchHooks.performInitialStartup(self)

        if testConfiguration.runsProductionGlobalStartupSideEffects {
            launchHooks.performProductionGlobalStartup(self)
        }

        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.notchWindow?.applySpaceBehavior()
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

    func applicationWillTerminate(_ notification: Notification) {
        socketServer?.stop()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        installApplicationMenuItems()
    }

    private func setupNotchWindow() {
        let window = NotchWindow()
        let hostView = FirstMouseHostingView(
            rootView: NotchContentView(onSizeChange: { [weak window] w, h, display in
                window?.resizeToFit(contentWidth: w, contentHeight: h, display: display)
            })
            .environment(sessionManager)
            .environment(audioEngine)
            .environment(updateManager)
            .environment(quotaTracker)
            .environment(persistenceManager)
            .environment(themeManager)
        )
        hostView.frame = window.contentView!.bounds
        hostView.autoresizingMask = [.width, .height]
        if #available(macOS 13.0, *) {
            hostView.sizingOptions = []
        }
        window.contentView?.addSubview(hostView)
        notchWindow = window
        themeManager.onSchemeChange = { [weak self] in
            guard let self, let w = self.notchWindow else { return }
            self.updateWindowAppearance(w)
        }
        updateWindowAppearance(window)
        window.orderFrontRegardless()
        themeManager.startObservingSystemAppearance()

        window.keyEquivalentHandler = { [weak self] event in
            guard let self = self else { return false }
            let flags = event.modifierFlags
            let chars = event.charactersIgnoringModifiers?.lowercased()
            let isCommand = flags.contains(.command)

            if isCommand, let chars = chars {
                switch chars {
                case "y":
                    switch self.sessionManager.currentIslandState {
                    case .permission(let id):
                        if let session = self.sessionManager.sessions.first(where: { $0.id == id }) {
                            self.sessionManager.approvePermission(session: session)
                            NotificationCenter.default.post(name: .xislandCollapse, object: nil)
                            return true
                        }
                    case .planReview(let id):
                        if let session = self.sessionManager.sessions.first(where: { $0.id == id }) {
                            self.sessionManager.respondToPlan(session: session, approved: true, feedback: nil)
                            NotificationCenter.default.post(name: .xislandCollapse, object: nil)
                            return true
                        }
                    default:
                        break
                    }
                case "n":
                    switch self.sessionManager.currentIslandState {
                    case .permission(let id):
                        if let session = self.sessionManager.sessions.first(where: { $0.id == id }) {
                            self.sessionManager.denyPermission(session: session)
                            NotificationCenter.default.post(name: .xislandCollapse, object: nil)
                            return true
                        }
                    case .planReview(let id):
                        if let session = self.sessionManager.sessions.first(where: { $0.id == id }) {
                            self.sessionManager.respondToPlan(session: session, approved: false, feedback: nil)
                            NotificationCenter.default.post(name: .xislandCollapse, object: nil)
                            return true
                        }
                    default:
                        break
                    }
                case "1", "2", "3":
                    if case .question(let id) = self.sessionManager.currentIslandState,
                       let session = self.sessionManager.sessions.first(where: { $0.id == id }),
                       let question = session.pendingQuestion,
                       let digit = Int(chars),
                       digit >= 1, digit <= question.options.count {
                        let option = question.options[digit - 1]
                        self.sessionManager.answerQuestion(session: session, answer: option)
                        NotificationCenter.default.post(name: .xislandCollapse, object: nil)
                        return true
                    }
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
            if chars == "\u{1b}" && self.sessionManager.currentIslandState == .expanded {
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

    private func setupMenuBarItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "sparkle", accessibilityDescription: "X Island")
            button.action = #selector(toggleNotch)
            button.target = self
        }

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Show Island", action: #selector(showNotch), keyEquivalent: "s"))
        menu.addItem(NSMenuItem(title: "Configure Agents...", action: #selector(reconfigure), keyEquivalent: ""))
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
        menu.addItem(checkForUpdatesItem)
        menu.addItem(installUpdateItem)
        menu.addItem(NSMenuItem(title: "Preferences...", action: #selector(openPreferences), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
        statusItem?.menu = menu
        checkForUpdatesMenuItem = checkForUpdatesItem
        installUpdateMenuItem = installUpdateItem
        refreshUpdateMenuState()
    }

    private func startSocketServer() {
        socketServer = SocketServer(sessionManager: sessionManager)
        socketServer?.start()
    }

    private func performInitialStartup() {
        sessionManager.audioEngine = audioEngine
        persistenceManager.setupContainer()
        sessionManager.persistenceManager = persistenceManager
        setupNotchWindow()
        setupMenuBarItem()
        DispatchQueue.main.async { [weak self] in
            self?.installApplicationMenuItems()
        }
        observeUpdateState()
        sessionManager.startCleanupTimer()
    }

    private func performProductionGlobalStartup() {
        startSocketServer()
        ZeroConfigManager.configureAllAgents()

        hookRepairTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in
            ZeroConfigManager.repairHooksIfNeeded()
        }
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

        if appSubmenu.items.contains(where: { $0.action == #selector(checkForUpdatesFromMenu) }) {
            return
        }

        let settingsIndex = appSubmenu.items.firstIndex(where: { item in
            item.title.localizedCaseInsensitiveContains("settings")
        }) ?? 1
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

    @objc private func toggleNotch() {
        if let w = notchWindow {
            w.isVisible ? w.orderOut(nil) : w.orderFrontRegardless()
        }
    }

    @objc private func showNotch() {
        notchWindow?.orderFrontRegardless()
    }

    @objc private func reconfigure() {
        ZeroConfigManager.configureAllAgents()
    }

    @objc func checkForUpdatesFromMenu() {
        UserDefaults.standard.set(
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
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 480),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        w.isFloatingPanel = true
        w.hidesOnDeactivate = false
        w.title = "X Island Settings"
        if let screen = notchWindow?.screen ?? NSScreen.main {
            let sf = screen.visibleFrame
            let x = sf.origin.x + (sf.width - 680) / 2
            let y = sf.origin.y + (sf.height - 480) / 2
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
            installUpdateMenuItem?.title = "Install \(version)..."
            installUpdateMenuItem?.isHidden = false
            installUpdateMenuItem?.isEnabled = true
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
}

final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
