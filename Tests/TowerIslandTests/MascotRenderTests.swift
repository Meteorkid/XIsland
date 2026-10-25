import AppKit
import SwiftUI
import XCTest
@testable import XIsland

@MainActor
final class MascotRenderTests: XCTestCase {
    func testRenderClientFamiliesTasksAndStaticStates() throws {
        guard ProcessInfo.processInfo.environment["X_ISLAND_RENDER_MASCOTS"] == "1" else {
            throw XCTSkip("显式启用吉祥物造型与静态状态渲染")
        }
        XCTAssertTrue(AppPreferences.isIsolated)
        _ = NSApplication.shared
        let defaults = AppPreferences.defaults
        let keys = ["reduceMotion", "disableAnimations", "appLanguage", "appearanceMode"]
        let original = keys.map { defaults.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, original) {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        defaults.set(true, forKey: "reduceMotion")
        defaults.set(true, forKey: "disableAnimations")
        defaults.set("zh", forKey: "appLanguage")
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["X_ISLAND_MASCOT_RENDER_DIR"]
                            ?? "/tmp/xisland-mascot-render", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for scheme in [ColorScheme.dark, .light] {
            let gallery = galleryView.environment(\.colorScheme, scheme).defaultAppStorage(defaults)
            try render(gallery, size: NSSize(width: 940, height: 1000), scheme: scheme,
                       to: directory.appendingPathComponent("mascot-gallery-\(scheme).png"))
        }
        try render(MascotGuideView().defaultAppStorage(defaults).environment(\.colorScheme, .dark),
                   size: NSSize(width: 610, height: 660), scheme: .dark,
                   to: directory.appendingPathComponent("mascot-settings-guide.png"))
        defaults.set("dark", forKey: "appearanceMode")
        let manager = SessionManager(), theme = ThemeManager()
        let session = AgentSession(id: "mascot-card-completed", agentType: .codex,
                                   workingDirectory: "/tmp/xisland", prompt: "检查并修复登录流程")
        session.status = .completed; session.completedAt = Date(); session.completionNeedsReview = true
        session.agentResponse = "修复与验证已完成，等待查看结果。"
        manager.sessions = [session]
        try render(SessionCardView(session: session).environment(manager).environment(theme)
                       .defaultAppStorage(defaults).background(Color.black),
                   size: NSSize(width: 380, height: 190), scheme: .dark,
                   to: directory.appendingPathComponent("completed-task-card.png"))
        XCTAssertTrue(session.completionNeedsReview, "只显示卡片不能确认结果已查看")
        let preview = HStack(spacing: 12) {
            ForEach(0..<3, id: \.self) { index in
                AgentIcon(agentType: .codex, size: 22, status: [.active, .waitingAnswer, .completed][index],
                          taskIdentity: MascotTaskIdentity(ordinal: index + 1, paletteIndex: index),
                          completionNeedsReview: index == 2)
            }
        }.padding(12).background(Color.black, in: RoundedRectangle(cornerRadius: 22))
        try render(preview.defaultAppStorage(defaults).environment(\.colorScheme, .dark),
                   size: NSSize(width: 160, height: 54), scheme: .dark,
                   to: directory.appendingPathComponent("codex-three-tasks.png"))

    }

    func testTaskAndUnreadLabelsKeepStateSemantics() {
        let identity = MascotTaskIdentity(ordinal: 3, paletteIndex: 2)
        let completed = AgentIcon(agentType: .codex, status: .completed, taskIdentity: identity, completionNeedsReview: true)
        XCTAssertEqual(completed.accessibilityDescription,
                       "\(AgentType.codex.displayName) · \(L10n.mascotTask(3)) · \(L10n.completedNeedsReview)")
        for status in [SessionStatus.idle, .completionUnconfirmed, .observationUnavailable] {
            let icon = AgentIcon(agentType: .codex, status: status, taskIdentity: identity, completionNeedsReview: true)
            XCTAssertTrue(icon.accessibilityDescription.contains(status.displayName))
            XCTAssertFalse(icon.accessibilityDescription.contains(L10n.completedNeedsReview))
        }
    }

    private var galleryView: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("软件造型 × 任务配色 × 状态表情").font(.system(size: 23, weight: .bold))
            Text("每格：32 pt 角色 / 20 pt 小图标 / 20 pt 单色轮廓；均已关闭动画")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 4), spacing: 14) {
                ForEach(AgentType.allCases) { agent in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 14) {
                            AgentIcon(agentType: agent, size: 32)
                            AgentIcon(agentType: agent, size: 20)
                            AgentMascotShape(family: .forAgent(agent)).fill(Color.primary).frame(width: 20, height: 20)
                        }
                        Text(agent.displayName + (agent.isSupported ? "" : " · 预留"))
                            .font(.system(size: 11, weight: .medium)).lineLimit(1)
                    }.frame(height: 58)
                }
            }
            Divider()
            Text("同一 Codex 系列：不同聊天 / 任务使用固定配色").font(.system(size: 14, weight: .semibold))
            HStack(spacing: 22) {
                ForEach(0..<12, id: \.self) { index in
                    AgentIcon(agentType: .codex, size: 30, status: .active,
                              taskIdentity: MascotTaskIdentity(ordinal: index + 1, paletteIndex: index))
                }
            }
            Divider()
            Text("同一任务的不同状态：主体颜色不变，标记不依赖动画").font(.system(size: 14, weight: .semibold))
            let states: [(SessionStatus, Bool)] = [(.active, false), (.thinking, false), (.compacting, false),
                (.waitingPermission, false), (.waitingAnswer, false), (.waitingPlanReview, false),
                (.error, false), (.completed, true), (.completed, false), (.idle, false),
                (.completionUnconfirmed, false), (.observationUnavailable, false)]
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 3), spacing: 16) {
                ForEach(states.indices, id: \.self) { index in
                    let state = states[index]
                    HStack(spacing: 10) {
                        AgentIcon(agentType: .codex, size: 24, status: state.0,
                                  taskIdentity: MascotTaskIdentity(ordinal: 1, paletteIndex: 0), completionNeedsReview: state.1)
                        Text(state.1 ? L10n.completedNeedsReview : state.0.displayName).font(.system(size: 12))
                    }
                }
            }
        }
        .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.background)
    }

    private func render<V: View>(_ view: V, size: NSSize, scheme: ColorScheme, to url: URL) throws {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        host.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
    }
}
