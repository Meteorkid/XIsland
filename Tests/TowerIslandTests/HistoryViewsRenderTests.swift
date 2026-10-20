import AppKit
import SwiftUI
import SwiftData
import XCTest
@testable import XIsland

@MainActor
final class HistoryViewsRenderTests: XCTestCase {
    func testHistoryPaginationSearchAndFailureViews() async throws {
        guard let directory = ProcessInfo.processInfo.environment["X_ISLAND_RENDER_HISTORY_DIR"] else {
            throw XCTSkip("显式启用历史页面渲染")
        }
        XCTAssertTrue(AppPreferences.isIsolated)
        guard AppPreferences.isIsolated else { return }
        _ = NSApplication.shared
        let defaults = AppPreferences.defaults
        let keys = ["appLanguage", "historyRetentionDays", "appearanceMode"]
        let old = keys.map { defaults.object(forKey: $0) }
        let appearance = NSApp.appearance
        defer {
            NSApp.appearance = appearance
            for (key, value) in zip(keys, old) {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        defaults.set(Int.max, forKey: "historyRetentionDays")
        defaults.set("light", forKey: "appearanceMode")
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let manager = SessionPersistenceManager()
        let schema = Schema([StoredSession.self, StoredToolEvent.self, StoredChatMessage.self, StoredKimiCodeApprovalOrphan.self])
        manager.modelContainer = try ModelContainer(for: schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        for (index, agent) in [AgentType.codex, .claudeCode, .codeBuddy].enumerated() {
            let session = AgentSession(id: "fixture-\(index)", agentType: agent,
                workingDirectory: "/tmp/项目", prompt: "测试完整历史与分页 · Validate complete history")
            session.status = .completed
            session.completedAt = Date()
            session.tokenUsage.totalTokens = 100
            session.tokenUsage.estimatedCostUSD = 0.05
            XCTAssertTrue(manager.save(session: session))
        }
        let unavailable = SessionPersistenceManager()
        let audio = AudioEngine(), sessionManager = SessionManager(), update = UpdateManager(), theme = ThemeManager()
        for appearanceName in ["light", "dark"] {
            defaults.set(appearanceName, forKey: "appearanceMode")
            NSApp.appearance = NSAppearance(named: appearanceName == "dark" ? .darkAqua : .aqua)
            for language in ["zh", "en"] {
                defaults.set(language, forKey: "appLanguage")
                for mode in ["page", "no-match", "read-error"] {
                    let store = mode == "read-error" ? unavailable : manager
                    let browser = HistoryBrowserState(pageSize: 2)
                    browser.reload(from: store)
                    if mode == "page" { browser.nextPage(in: store) }
                    if mode == "no-match" { browser.search("missing-result", in: store) }
                    let view = PreferencesView(initialPane: "history", historyBrowser: browser)
                        .environment(store).environment(audio).environment(sessionManager).environment(update).environment(theme)
                        .defaultAppStorage(defaults)
                    try await render(view, dark: appearanceName == "dark", to: output.appendingPathComponent("\(appearanceName)-\(language)-\(mode).png"), ready: { browser.hasLoaded && !browser.isLoading })
                }
                for (mode, store) in [("statistics", manager), ("statistics-error", unavailable)] {
                    var state = HistoryStatistics.LoadState()
                    state.reload(from: store, timeRange: .all)
                    let view = StatisticsView(initialState: state, timeRange: .all)
                        .environment(store).environment(theme).padding(24)
                    try await render(view, dark: appearanceName == "dark", to: output.appendingPathComponent("\(appearanceName)-\(language)-\(mode).png"))
                }
            }
        }
    }

    private func render<V: View>(_ view: V, dark: Bool, to url: URL, ready: () -> Bool = { true }) async throws {
        let host = NSHostingView(rootView: view.frame(width: 760, height: 520).background(Color(nsColor: .windowBackgroundColor)).preferredColorScheme(dark ? .dark : .light))
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host.frame = NSRect(x: 0, y: 0, width: 760, height: 520)
        host.layoutSubtreeIfNeeded()
        // 挂载会触发真实异步读取；先让任务启动，再等待页面完成，避免把加载态当成结果页。
        try await Task.sleep(for: .milliseconds(150))
        let deadline = ContinuousClock.now + .seconds(5)
        while !ready(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(ready(), "历史页面未完成异步读取")
        host.layoutSubtreeIfNeeded()
        let image = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: image)
        XCTAssertGreaterThan(image.pixelsWide, 700)
        XCTAssertGreaterThan(image.pixelsHigh, 500)
        try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: url)
    }
}
