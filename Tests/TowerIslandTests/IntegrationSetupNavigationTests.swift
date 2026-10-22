import AppKit
import SwiftUI
import XCTest
@testable import XIsland

@MainActor
final class IntegrationSetupNavigationTests: XCTestCase {
    func testTargetedEntryScrollsPastOtherClientsAndCanRefocusExistingView() async throws {
        XCTAssertTrue(AppPreferences.isIsolated)
        _ = NSApplication.shared
        let pending = Array(AgentType.allCases.filter { $0.isSupported && $0 != .codex && $0 != .glm }.prefix(12))
            .map { row($0, .needsConfiguration) }
        let rows = pending + [row(.codex, .needsAuthorization)]
        let host = NSHostingView(rootView: makeView(rows))
        let window = mount(host)
        defer { window.close() }
        host.frame = NSRect(x: 0, y: 0, width: 680, height: 640)
        host.layoutSubtreeIfNeeded()
        let scroll = try XCTUnwrap(scrollViews(host).first)
        let initialY = scroll.contentView.bounds.minY

        host.rootView = makeView(rows, focus: IntegrationSetupFocusRequest(agent: .codex))
        await waitForScroll(scroll, awayFrom: initialY)
        XCTAssertGreaterThan(scroll.contentView.bounds.minY, initialY + 100)

        scroll.contentView.scroll(to: NSPoint(x: 0, y: initialY))
        scroll.reflectScrolledClipView(scroll.contentView)
        host.rootView = makeView(rows, focus: IntegrationSetupFocusRequest(agent: .codex))
        await waitForScroll(scroll, awayFrom: initialY)
        XCTAssertGreaterThan(scroll.contentView.bounds.minY, initialY + 100)
        try snapshot(host, name: "focused-pending")
    }

    func testTargetedEntryExpandsReadyAndInactiveGroupsAfterStateChanges() async throws {
        XCTAssertTrue(AppPreferences.isIsolated)
        _ = NSApplication.shared
        let pending = Array(AgentType.allCases.filter { $0.isSupported && $0 != .codex && $0 != .glm }.prefix(10))
            .map { row($0, .needsConfiguration) }
        for phase in [IntegrationSetupPhase.waitingForActivity, .connected, .disabled, .notInstalled] {
            let rows = pending + [row(.codex, phase)]
            let host = NSHostingView(rootView: makeView(rows))
            let window = mount(host)
            defer { window.close() }
            host.frame = NSRect(x: 0, y: 0, width: 680, height: 640)
            host.layoutSubtreeIfNeeded()
            let scroll = try XCTUnwrap(scrollViews(host).first)
            let initialY = scroll.contentView.bounds.minY
            host.rootView = makeView(rows, focus: IntegrationSetupFocusRequest(agent: .codex))
            await waitForScroll(scroll, awayFrom: initialY)
            XCTAssertGreaterThan(scroll.contentView.bounds.minY, initialY + 100, phase.rawValue)
            try snapshot(host, name: "focused-\(phase.rawValue)")
        }
    }

    private func row(_ agent: AgentType, _ phase: IntegrationSetupPhase) -> IntegrationSetupRow {
        IntegrationSetupRow(agent: agent, phase: phase, detail: "Isolated setup fixture", canConfigure: true, lastSeen: nil)
    }

    private func makeView(_ rows: [IntegrationSetupRow], focus: IntegrationSetupFocusRequest? = nil) -> IntegrationSetupView {
        IntegrationSetupView(rows: rows, isRefreshing: false,
            onConfigure: { _ in XCTFail("不能配置真实客户端") },
            onOpenClient: { _ in XCTFail("不能打开真实客户端") },
            onOpenGuide: { _ in XCTFail("不能打开浏览器") },
            onRefresh: {}, onLater: {}, focusRequest: focus)
    }

    private func scrollViews(_ view: NSView) -> [NSScrollView] {
        (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
    }

    private func mount(_ host: NSView) -> NSWindow {
        // .task 随窗口中的视图生命周期启动，离屏 bitmap host 不能验证定位任务。
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 680, height: 640),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        return window
    }

    private func waitForScroll(_ scroll: NSScrollView, awayFrom y: CGFloat) async {
        let deadline = ContinuousClock.now + .seconds(2)
        while scroll.contentView.bounds.minY <= y + 100, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func snapshot(_ host: NSView, name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["X_ISLAND_RENDER_INTEGRATION_SETUP_DIR"] else { return }
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: output.appendingPathComponent("\(name).png"))
    }
}
