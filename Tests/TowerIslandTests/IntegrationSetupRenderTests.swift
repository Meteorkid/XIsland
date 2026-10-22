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
        let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["X_ISLAND_RENDER_INTEGRATION_SETUP_DIR"]
                         ?? "/tmp/xisland-integration-setup-render", isDirectory: true)
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
            let configuration = IntegrationSetupRow(agent: .cursor, phase: .needsConfiguration,
                detail: chinese ? "可自动完成配置，随后在 Cursor 中开始任务。" : "Setup can be completed automatically. Then start a task in Cursor.",
                canConfigure: true, lastSeen: nil)
            let waiting = IntegrationSetupRow(agent: .geminiCli, phase: .waitingForActivity,
                detail: chinese ? "配置已准备，开始一条任务即可验证。" : "Setup is ready. Start a task to verify the connection.",
                canConfigure: true, lastSeen: nil)
            let disabled = IntegrationSetupRow(agent: .cursor, phase: .disabled,
                detail: chinese ? "此来源已关闭。" : "This connection is disabled.",
                canConfigure: true, lastSeen: nil)

            try render([authorization, connected, missing], language: language, scheme: .light,
                       to: output.appendingPathComponent("\(language)-authorization.png"))
            try render([authorization, connected, missing], language: language, scheme: .dark,
                       to: output.appendingPathComponent("\(language)-authorization-dark.png"))
            try render([authorization], language: language, scheme: .light,
                       failure: .init(agent: .codex, kind: .applicationMissing),
                       to: output.appendingPathComponent("\(language)-application-missing.png"))
            try render([authorization], language: language, scheme: .dark,
                       failure: .init(agent: .codex, kind: .launchFailed),
                       to: output.appendingPathComponent("\(language)-launch-failed-dark.png"))
            for (name, scheme) in [("light", ColorScheme.light), ("dark", ColorScheme.dark)] {
                let notice = CodexAuthorizationNotice { XCTFail("渲染不应打开授权窗口") }
                    .padding(16)
                    .frame(width: 580, alignment: .leading)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .preferredColorScheme(scheme)
                try snapshot(notice, scheme: scheme, size: NSSize(width: 580, height: 150),
                             to: output.appendingPathComponent("\(language)-authorization-notice-\(name).png"))
            }
            try render([connected], language: language, scheme: .dark,
                       to: output.appendingPathComponent("\(language)-connected-dark.png"))
            try render([manual, missing], language: language, scheme: .light,
                       to: output.appendingPathComponent("\(language)-manual.png"))
            try render([missing], language: language, scheme: .light,
                       to: output.appendingPathComponent("\(language)-not-installed.png"))
            try render([workBuddy, kiro], language: language, scheme: .light,
                       to: output.appendingPathComponent("\(language)-manual-files.png"))
            try render([connected, waiting, authorization, configuration], language: language, scheme: .light,
                       to: output.appendingPathComponent("\(language)-mixed.png"))
            try render([authorization, workBuddy], language: language, scheme: .light,
                       to: output.appendingPathComponent("\(language)-pending.png"))
            try render([], language: language, scheme: .light,
                       to: output.appendingPathComponent("\(language)-none.png"))
            try render([waiting], language: language, scheme: .light,
                       to: output.appendingPathComponent("\(language)-waiting.png"))
            try render([connected], language: language, scheme: .light,
                       to: output.appendingPathComponent("\(language)-connected.png"))
            try render([disabled], language: language, scheme: .light,
                       to: output.appendingPathComponent("\(language)-disabled.png"))
        }
    }

    private func render(_ rows: [IntegrationSetupRow], language: String, scheme: ColorScheme,
                        failure: IntegrationClientLauncher.Failure? = nil, to url: URL) throws {
        let view = IntegrationSetupView(rows: rows, isRefreshing: false,
            onConfigure: { _ in XCTFail("渲染不应配置真实软件") },
            onOpenClient: { _ in XCTFail("渲染不应打开真实客户端") },
            onOpenGuide: { _ in XCTFail("渲染不应打开外部链接") },
            onRefresh: { XCTFail("渲染不应读取真实接入状态") },
            onLater: { XCTFail("渲染不应写入提醒状态") },
            onPrepareFiles: { _ in XCTFail("渲染不应生成真实接入文件或打开 Finder") },
            onPrepareAll: { XCTFail("渲染不应批量配置真实软件") },
            clientLaunchFailure: failure)
            .environment(\.locale, Locale(identifier: language))
            .preferredColorScheme(scheme)
            .defaultAppStorage(AppPreferences.defaults)
        try snapshot(view, scheme: scheme, size: NSSize(width: 680, height: 640), to: url)
    }

    private func snapshot<V: View>(_ view: V, scheme: ColorScheme, size: NSSize, to url: URL) throws {
        let host = NSHostingView(rootView: view)
        host.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        XCTAssertGreaterThanOrEqual(bitmap.pixelsWide, Int(size.width))
        XCTAssertGreaterThanOrEqual(bitmap.pixelsHigh, Int(size.height))
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
    }
}
