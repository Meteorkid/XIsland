import AppKit
import QuartzCore
import XCTest
@testable import XIsland

@MainActor
final class NotchWindowHideOrderingTests: XCTestCase {
    private struct HideObservation {
        let isVisible: Bool
        let alpha: CGFloat
        let contentOpacity: Float?
    }

    func testOrderOutHidesBeforeRestoringVisualsAndInvalidatesInbound() throws {
        var observations: [HideObservation] = []
        let window = makeWindow { observations.append(Self.observe($0)) }
        defer { window.close() }
        let foreground = installForeground(in: window)
        let generation = window.beginInboundHandoff { _ in }
        foreground.layer?.opacity = 0.25
        window.alphaValue = 0.35

        window.orderOut(nil)

        let atHide = try XCTUnwrap(observations.first)
        XCTAssertFalse(atHide.isVisible)
        XCTAssertEqual(atHide.alpha, 0.35, accuracy: 0.001, "原生窗口隐藏前不能恢复透明度")
        XCTAssertEqual(try XCTUnwrap(atHide.contentOpacity), 0.25, accuracy: 0.001)
        XCTAssertFalse(window.isCurrentHandoff(generation), "显式隐藏必须淘汰待完成的入站代数")
        XCTAssertNil(window.handoffState.pendingPreparation)
        XCTAssertEqual(window.alphaValue, 1)
        XCTAssertEqual(foreground.layer?.opacity, 1)
    }

    func testCloseHidesBeforeRestoringVisualsAndInvalidatesInbound() throws {
        var observations: [HideObservation] = []
        let window = makeWindow { observations.append(Self.observe($0)) }
        defer { window.close() }
        let foreground = installForeground(in: window)
        let generation = window.beginInboundHandoff { _ in }
        foreground.layer?.opacity = 0.25
        window.alphaValue = 0.35

        window.close()

        let atHide = try XCTUnwrap(observations.first)
        XCTAssertFalse(atHide.isVisible)
        XCTAssertEqual(atHide.alpha, 0.35, accuracy: 0.001, "关闭前不能把旧岛恢复成完整不透明状态")
        XCTAssertEqual(try XCTUnwrap(atHide.contentOpacity), 0.25, accuracy: 0.001)
        XCTAssertFalse(window.isCurrentHandoff(generation))
        XCTAssertNil(window.handoffState.pendingPreparation)
        XCTAssertEqual(window.alphaValue, 1)
        XCTAssertEqual(foreground.layer?.opacity, 1)
    }

    func testCommittedPreviewIgnoresOrdinaryCancellationUntilSwitchIsCancelled() throws {
        let window = makeWindow()
        defer { window.close() }
        let foreground = installForeground(in: window)
        window.previewIslandSwitch(translation: 45)
        let layer = try XCTUnwrap(foreground.layer)
        let previewTransform = layer.transform
        XCTAssertFalse(CATransform3DIsIdentity(previewTransform))
        XCTAssertTrue(window.isPreviewingIslandSwitch)
        window.isSwitchingApps = true

        window.cancelIslandSwitchPreview(animated: false)

        XCTAssertTrue(window.isPreviewingIslandSwitch, "ACK 到达前必须保留已提交的预览")
        XCTAssertTrue(CATransform3DEqualToTransform(layer.transform, previewTransform))
        window.isSwitchingApps = false
        window.cancelIslandSwitchPreview(animated: false)
        XCTAssertFalse(window.isPreviewingIslandSwitch)
        XCTAssertTrue(CATransform3DIsIdentity(layer.transform))
        XCTAssertEqual(layer.opacity, 1)
    }

    private func makeWindow(didHide: ((NotchWindow) -> Void)? = nil) -> NotchWindow {
        _ = NSApplication.shared
        let defaults = UserDefaults(suiteName: "NotchWindowHideOrderingTests.\(UUID().uuidString)")!
        return NotchWindow(defaults: defaults, markVisible: {}, onExplicitShow: {},
                           handoffEnvironment: .init(reduceMotion: { false }, orderFront: { _ in },
                                                     orderOut: { $0.orderOut(nil) }, didHide: didHide))
    }

    private func installForeground(in window: NotchWindow) -> NSView {
        let foreground = NSView(frame: window.contentView!.bounds)
        foreground.wantsLayer = true
        foreground.layer?.backgroundColor = NSColor.red.cgColor
        window.contentView?.addSubview(foreground)
        return foreground
    }

    private static func observe(_ window: NotchWindow) -> HideObservation {
        HideObservation(isVisible: window.isVisible, alpha: window.alphaValue,
                        contentOpacity: window.contentView?.subviews.first?.layer?.opacity)
    }
}
