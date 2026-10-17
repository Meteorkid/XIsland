import AppKit
import SwiftUI
import XCTest
@testable import XIsland

@MainActor
final class IntegrationSetupRenderTests: XCTestCase {
    func testRenderIntegrationSetupStates() throws {
        guard ProcessInfo.processInfo.environment["X_ISLAND_RENDER_INTEGRATION_SETUP"] == "1" else {
            throw XCTSkip("显式启用隔离的软件接入界面快照")
        }
        guard AppPreferences.isIsolated else {
            XCTFail("接入界面渲染必须使用隔离的应用偏好")
            return
        }

        let defaults = AppPreferences.defaults
        let previousLanguage = defaults.object(forKey: "appLanguage")
        defer {
            if let previousLanguage { defaults.set(previousLanguage, forKey: "appLanguage") }
            else { defaults.removeObject(forKey: "appLanguage") }
        }
        _ = NSApplication.shared
        let output = URL(fileURLWithPath: "/tmp/xisland-integration-setup-render", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        for language in ["zh", "en"] {
            defaults.set(language, forKey: "appLanguage")
            let chinese = language == "zh"
            let authorization = IntegrationSetupRow(agent: .codex, phase: .needsAuthorization,
                detail: chinese ? "配置已准备，尚未获得本次钩子的信任。" : "Configuration is ready. The current hooks still need your trust.",
                canConfigure: true, lastSeen: nil)
            let connected = IntegrationSetupRow(agent: .claudeCode, phase: .connected,
                detail: chinese ? "已收到当前配置的活动，接入已完成。" : "Activity received from the current configuration. Connection complete.",
                canConfigure: true, lastSeen: Date(timeIntervalSince1970: 1_792_180_800))
            let manual = IntegrationSetupRow(agent: .zed, phase: .needsSetup,
                detail: chinese ? "按说明连接外部 ACP Agent。可显示活动，权限仍在编辑器中处理。" : "Follow the guide to connect an external ACP agent. Activity is shown here; permissions stay in the editor.",
                canConfigure: false, lastSeen: nil)
            let missing = IntegrationSetupRow(agent: .cursor, phase: .notInstalled,
                detail: chinese ? "安装或打开 Cursor 后重新检查。" : "Install or open Cursor, then check again.",
                canConfigure: true, lastSeen: nil)
            let workBuddy = IntegrationSetupRow(agent: .workBuddy, phase: .needsSetup,
                detail: chinese ? "接入文件已准备。请在 WorkBuddy 添加导出的插件，审阅并启用。" : "Setup files are ready. Add the exported plugin in WorkBuddy, then review and enable it.",
                canConfigure: false, lastSeen: nil)
            let kiro = IntegrationSetupRow(agent: .kiro, phase: .needsSetup,
                detail: chinese ? "接入文件已准备。按步骤放置 Kiro V3 hooks 文件，在客户端核对后开始任务。" : "Setup files are ready. Place the Kiro V3 hooks file as described, check it in the client, then start a task.",
                canConfigure: false, lastSeen: nil)

            try render([authorization, connected, missing], language: language, scheme: .light,
                       to: output.appendingPathComponent("\(language)-authorization.png"))
            try render([connected], language: language, scheme: .dark,
                       to: output.appendingPathComponent("\(language)-connected-dark.png"))
            try render([manual, missing], language: language, scheme: .light,
                       to: output.appendingPathComponent("\(language)-manual.png"))
            try render([missing], language: language, scheme: .light,
                       to: output.appendingPathComponent("\(language)-not-installed.png"))
            try render([workBuddy, kiro], language: language, scheme: .light,
                       to: output.appendingPathComponent("\(language)-manual-files.png"))
        }
    }

    private func render(_ rows: [IntegrationSetupRow], language: String, scheme: ColorScheme, to url: URL) throws {
        let view = IntegrationSetupView(rows: rows, isRefreshing: false,
            onConfigure: { _ in XCTFail("渲染不应配置真实软件") },
            onOpenClient: { _ in XCTFail("渲染不应打开真实客户端") },
            onOpenGuide: { _ in XCTFail("渲染不应打开外部链接") },
            onRefresh: { XCTFail("渲染不应读取真实接入状态") },
            onLater: { XCTFail("渲染不应写入提醒状态") },
            onPrepareFiles: { _ in XCTFail("渲染不应生成真实接入文件或打开 Finder") })
            .environment(\.locale, Locale(identifier: language))
            .preferredColorScheme(scheme)
            .defaultAppStorage(AppPreferences.defaults)
        let host = NSHostingView(rootView: view)
        host.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        host.frame = NSRect(x: 0, y: 0, width: 680, height: 640)
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        XCTAssertGreaterThanOrEqual(bitmap.pixelsWide, 680)
        XCTAssertGreaterThanOrEqual(bitmap.pixelsHigh, 640)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
    }
}
