import AppKit
import Observation
import QuartzCore
import SwiftUI
import XCTest
@testable import XIsland

@MainActor
final class IslandSwitchSurfaceTests: XCTestCase {
    func testDifferentAspectRatiosShareCanvasAndTravelInBothDirections() throws {
        let pairs: [(CGSize, CGSize)] = [
            (CGSize(width: 340, height: 82), CGSize(width: 180, height: 32)),
            (CGSize(width: 180, height: 32), CGSize(width: 340, height: 82)),
            (CGSize(width: 340, height: 32), CGSize(width: 180, height: 82)),
            (CGSize(width: 180, height: 82), CGSize(width: 340, height: 32)),
        ]
        for (sourceSize, targetSize) in pairs {
            let source = try geometry(topCenter: CGPoint(x: -1050, y: 940), size: sourceSize)
            let target = try geometry(topCenter: CGPoint(x: -1010, y: 940), size: targetSize)
            let forward = try XCTUnwrap(IslandSwitchSurfacePlan(motion: motion(source, target), displayID: 2))
            let reverse = try XCTUnwrap(IslandSwitchSurfacePlan(motion: motion(target, source), displayID: 2))
            XCTAssertEqual(forward.travel, max(sourceSize.width, targetSize.width))
            XCTAssertEqual(forward.travel, reverse.travel)
            XCTAssertEqual(forward.canvas, reverse.canvas)
            XCTAssertTrue(forward.canvas.contains(source.frame))
            XCTAssertTrue(forward.canvas.contains(target.frame))
            for endpoint in [source, target] {
                let local = IslandSwitchSurfacePlan.localRect(endpoint.frame, canvas: forward.canvas)
                XCTAssertEqual(local.minX, endpoint.frame.minX - forward.canvas.minX, accuracy: 0.001)
                XCTAssertEqual(local.minY, forward.canvas.maxY - endpoint.frame.maxY, accuracy: 0.001)
                XCTAssertEqual(local.size, endpoint.frame.size)
                assertRect(screenRect(local, canvas: forward.canvas), equals: endpoint.frame)
            }
        }
    }

    func testScreenToCanvasConversionHandlesNegativeOriginsAndDifferentTopEdges() {
        let canvas = CGRect(x: -1450, y: -300, width: 700, height: 260)
        let screen = CGRect(x: -1200, y: -180, width: 220, height: 78)
        let local = IslandSwitchSurfacePlan.localRect(screen, canvas: canvas)
        assertRect(local, equals: CGRect(x: 250, y: 62, width: 220, height: 78))
        assertRect(screenRect(local, canvas: canvas), equals: screen)
    }

    func testLegacyMissingGeometryAndDifferentDisplaysDoNotCreateSurfacePlan() throws {
        let source = try geometry()
        let target = try geometry(size: CGSize(width: 340, height: 78))
        let otherDisplay = try geometry(size: CGSize(width: 340, height: 78), displayID: 3)
        XCTAssertNil(IslandSwitchSurfacePlan(motion: nil, displayID: 2))
        XCTAssertNil(IslandSwitchSurfacePlan(motion: motion(nil, nil), displayID: 2))
        XCTAssertNil(IslandSwitchSurfacePlan(motion: motion(source, nil), displayID: 2))
        XCTAssertNil(IslandSwitchSurfacePlan(motion: motion(nil, target), displayID: 2))
        XCTAssertNil(IslandSwitchSurfacePlan(motion: motion(source, otherDisplay), displayID: 2))
        XCTAssertNil(IslandSwitchSurfacePlan(motion: motion(source, target), displayID: 3))
        XCTAssertNil(IslandSwitchSurfacePlan(motion: motion(source, target), displayID: nil))
        XCTAssertNotNil(IslandSwitchSurfacePlan(motion: motion(source, target), displayID: 2))
    }

    func testShapePathsUseActualEndpointBoundsInsteadOfScalingContent() throws {
        let source = try geometry(size: CGSize(width: 340, height: 78))
        let target = try geometry(size: CGSize(width: 180, height: 32))
        let plan = try XCTUnwrap(IslandSwitchSurfacePlan(motion: motion(source, target), displayID: 2))
        let sourceRect = IslandSwitchSurfacePlan.localRect(source.frame, canvas: plan.canvas)
        let targetRect = IslandSwitchSurfacePlan.localRect(target.frame, canvas: plan.canvas)
        let sourcePath = IslandSwitchSurfacePlan.path(for: source, in: sourceRect)
        let targetPath = IslandSwitchSurfacePlan.path(for: target, in: targetRect)
        assertRect(sourcePath.boundingBoxOfPath, equals: sourceRect)
        assertRect(targetPath.boundingBoxOfPath, equals: targetRect)
        XCTAssertNotEqual(sourcePath.boundingBoxOfPath.size, targetPath.boundingBoxOfPath.size)
        XCTAssertTrue(sourcePath.contains(CGPoint(x: sourceRect.midX, y: sourceRect.midY)))
        XCTAssertTrue(targetPath.contains(CGPoint(x: targetRect.midX, y: targetRect.midY)))
    }

    func testAnimatorMovesHostingChildWithoutMovingContainerAndResetRestoresContent() throws {
        _ = NSApplication.shared
        let container = NSView(frame: CGRect(x: 0, y: 0, width: 420, height: 140))
        container.wantsLayer = true
        let host = NSHostingView(rootView: AnyView(Text("原比例文字与图标").font(.system(size: 14))))
        host.sizingOptions = []
        host.frame = CGRect(x: 20, y: 10, width: 260, height: 70)
        host.wantsLayer = true
        container.addSubview(host)
        let containerLayer = try XCTUnwrap(container.layer)
        let contentLayer = try XCTUnwrap(host.layer)
        let originalFrame = host.frame
        let originalBounds = host.bounds
        let originalMask = CALayer()
        containerLayer.mask = originalMask
        let animator = IslandSlideAnimator(viewProvider: { container })
        defer { animator.reset() }
        // 没有 window 或可形变背景，不会创建原生 SurfaceWindow。
        XCTAssertNil(IslandSlideAnimator.geometry(in: container))
        animator.preview(translation: 42, width: host.frame.width, reduceMotion: false)
        XCTAssertEqual(contentLayer.transform.m41,
                       IslandSlideAnimator.previewOffset(translation: 42, width: host.frame.width), accuracy: 0.001)
        XCTAssertTrue(CATransform3DIsIdentity(containerLayer.transform))
        XCTAssertEqual(host.frame, originalFrame)
        XCTAssertEqual(host.bounds, originalBounds)
        assertNoScale(contentLayer.transform)

        animator.animateOutgoing(motion: motion(nil, nil), reduceMotion: false, completion: {})
        XCTAssertEqual(contentLayer.transform.m41, -host.frame.width, accuracy: 0.001)
        let groups = (contentLayer.animationKeys() ?? []).compactMap {
            contentLayer.animation(forKey: $0) as? CAAnimationGroup
        }
        let keyPaths = groups.flatMap { ($0.animations ?? []).compactMap { ($0 as? CABasicAnimation)?.keyPath } }
        XCTAssertTrue(keyPaths.contains("transform.translation.x"))
        XCTAssertTrue(keyPaths.contains("opacity"))
        XCTAssertFalse(keyPaths.contains { $0.contains("scale") || $0 == "bounds" })
        assertNoScale(contentLayer.transform)
        XCTAssertTrue(CATransform3DIsIdentity(containerLayer.transform))

        animator.reset()
        XCTAssertTrue(CATransform3DIsIdentity(contentLayer.transform))
        XCTAssertEqual(contentLayer.opacity, 1)
        XCTAssertTrue(containerLayer.mask === originalMask)
        XCTAssertEqual(host.frame, originalFrame)
        XCTAssertEqual(host.bounds, originalBounds)
        XCTAssertFalse((contentLayer.animationKeys() ?? []).contains("island.directional-switch"))
    }

    func testBackgroundWrapperDoesNotInterceptInteraction() {
        let background = IslandSwitchBackgroundHost(rootView: AnyView(Button("不能拦截前景") {}))
        background.sizingOptions = []
        background.frame = CGRect(x: 0, y: 0, width: 220, height: 60)
        XCTAssertNil(background.hitTest(CGPoint(x: 110, y: 30)))
        XCTAssertNil(background.hitTest(.zero))
    }

    func testHiddenSurfacePreviewReturnAndResetRestoreMaskAndBackground() throws {
        let fixture = try surfaceFixture()
        defer { fixture.animator.reset(); fixture.panel.close() }
        let visibleWindows = visibleWindowIdentifiers()
        let outline = try XCTUnwrap(IslandSlideAnimator.geometry(in: fixture.container))
        let expectedMask = fixture.container.convert(fixture.panel.convertFromScreen(outline.frame), from: nil)

        fixture.animator.preview(translation: 42, width: fixture.host.bounds.width, reduceMotion: false)
        let mask = try XCTUnwrap(fixture.container.layer?.mask as? CAShapeLayer)
        XCTAssertFalse(mask === fixture.originalMask)
        assertRect(try XCTUnwrap(mask.path).boundingBoxOfPath, equals: expectedMask)
        XCTAssertEqual(fixture.background.layer?.opacity, 0)
        XCTAssertEqual(IslandSlideAnimator.geometry(in: fixture.container), outline,
                       "前景跟手位移不能改变保持静止的外壳几何")
        assertNoScale(try XCTUnwrap(fixture.host.layer).transform)
        XCTAssertTrue(CATransform3DIsIdentity(try XCTUnwrap(fixture.container.layer).transform))
        XCTAssertEqual(visibleWindowIdentifiers(), visibleWindows, "测试外壳必须保持隐藏")

        fixture.animator.returnToRest(reduceMotion: true)
        assertSurfaceRestored(fixture)
        fixture.animator.preview(translation: -35, width: fixture.host.bounds.width, reduceMotion: false)
        XCTAssertNotNil(fixture.container.layer?.mask as? CAShapeLayer)
        XCTAssertEqual(fixture.background.layer?.opacity, 0)
        fixture.animator.reset()
        assertSurfaceRestored(fixture)
        XCTAssertEqual(visibleWindowIdentifiers(), visibleWindows)
    }

    func testIncomingAndOutgoingMorphShareMaskEndpointAndCancellationCleansUp() async throws {
        let fixture = try surfaceFixture()
        defer { fixture.animator.reset(); fixture.panel.close() }
        let visibleWindows = visibleWindowIdentifiers()
        let source = try XCTUnwrap(IslandSlideAnimator.geometry(in: fixture.container))
        let target = try geometry(topCenter: CGPoint(x: source.frame.midX, y: source.frame.maxY),
                                  size: CGSize(width: 340, height: 82), displayID: source.displayID)
        XCTAssertTrue(fixture.screen.frame.contains(source.frame))
        XCTAssertTrue(fixture.screen.frame.contains(target.frame))
        let request = motion(source, target)
        let targetLocal = fixture.container.convert(fixture.panel.convertFromScreen(target.frame), from: nil)
        let sourceLocal = fixture.container.convert(fixture.panel.convertFromScreen(source.frame), from: nil)
        let cancelledCompletion = expectation(description: "取消后不能执行旧完成回调")
        cancelledCompletion.isInverted = true
        var maskEndpoints: [CGRect] = []

        for incoming in [true, false] {
            if incoming {
                fixture.animator.animateIncoming(motion: request, reduceMotion: false) { cancelledCompletion.fulfill() }
            } else {
                fixture.animator.animateOutgoing(motion: request, reduceMotion: false) { cancelledCompletion.fulfill() }
            }
            let mask = try XCTUnwrap(fixture.container.layer?.mask as? CAShapeLayer)
            let endpoint = try XCTUnwrap(mask.path).boundingBoxOfPath
            maskEndpoints.append(endpoint)
            assertRect(endpoint, equals: targetLocal)
            let pathAnimation = try XCTUnwrap(basicAnimations(in: mask).first { $0.keyPath == "path" })
            let fromPath = try XCTUnwrap(pathAnimation.fromValue) as! CGPath
            let toPath = try XCTUnwrap(pathAnimation.toValue) as! CGPath
            assertRect(fromPath.boundingBoxOfPath, equals: sourceLocal)
            assertRect(toPath.boundingBoxOfPath, equals: targetLocal)
            let contentLayer = try XCTUnwrap(fixture.host.layer)
            let movement = try XCTUnwrap(basicAnimations(in: contentLayer).first { $0.keyPath == "transform.translation.x" })
            let travelled = incoming ? movement.fromValue : movement.toValue
            XCTAssertEqual(abs(try XCTUnwrap(travelled as? NSNumber).doubleValue), 340, accuracy: 0.001)
            assertNoScale(contentLayer.transform)
            XCTAssertEqual(fixture.host.frame.size, fixture.container.bounds.size)
            XCTAssertEqual(fixture.background.layer?.opacity, 0)
            XCTAssertEqual(visibleWindowIdentifiers(), visibleWindows)
            fixture.animator.reset()
            assertSurfaceRestored(fixture)
        }
        XCTAssertEqual(maskEndpoints.first, maskEndpoints.last)
        await fulfillment(of: [cancelledCompletion], timeout: 0.4)
        assertSurfaceRestored(fixture)
        XCTAssertEqual(visibleWindowIdentifiers(), visibleWindows)
    }

    func testGeometryUsesBackgroundBoundsAndClipsScreenTopInsteadOfWindowFrame() throws {
        let fixture = try offscreenPanel(overhang: 6)
        defer { fixture.panel.close() }
        let container = FlippedCanvas(frame: CGRect(origin: .zero, size: fixture.panel.frame.size))
        fixture.panel.contentView = container
        let foreground = FlippedCanvas(frame: CGRect(x: 0, y: 0, width: 400, height: 100))
        container.addSubview(foreground)
        let background = IslandSwitchBackgroundHost(rootView: AnyView(Color.red))
        background.sizingOptions = []
        background.frame = CGRect(x: 37, y: 0, width: 180, height: 54)
        background.topRadius = 0
        background.bottomRadius = 17
        background.fillColor = NSColor(deviceRed: 0.1, green: 0.2, blue: 0.3, alpha: 0.9)
        foreground.addSubview(background)
        container.layoutSubtreeIfNeeded()
        let raw = fixture.panel.convertToScreen(background.convert(background.bounds, to: nil))
        let expected = raw.intersection(fixture.screen.frame)
        let geometry = try XCTUnwrap(IslandSlideAnimator.geometry(in: container))
        assertRect(geometry.frame, equals: expected)
        XCTAssertEqual(geometry.frame.width, 180, accuracy: 0.001)
        XCTAssertNotEqual(geometry.frame.size, fixture.panel.frame.size)
        let displayID = try XCTUnwrap(fixture.screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32)
        XCTAssertEqual(geometry.displayID, displayID)
        XCTAssertEqual(geometry.bottomRadius, 17)
        XCTAssertFalse(fixture.panel.isVisible)
        if raw.maxY > fixture.screen.frame.maxY {
            XCTAssertLessThan(geometry.frame.height, background.bounds.height)
        }
        background.allowsMorph = false
        XCTAssertNil(IslandSlideAnimator.geometry(in: container), "不支持的材质应走既有过渡")
    }

    func testAnyViewBackgroundPreservesEnvironmentAcrossUpdatesAndFixedLayout() async throws {
        let fixture = try offscreenPanel()
        defer { fixture.panel.close() }
        let host = NSHostingView(rootView: wrappedProbe(token: "first", scheme: .dark))
        host.sizingOptions = []
        host.frame = CGRect(x: 0, y: 0, width: 180, height: 54)
        fixture.panel.contentView?.addSubview(host)
        await settle(host)
        XCTAssertEqual(probe(in: host)?.value, "first|dark")
        let background = try XCTUnwrap(IslandSlideAnimator.background(in: host))
        XCTAssertEqual(background.frame.width, 180, accuracy: 0.5)
        XCTAssertEqual(background.frame.height, 54, accuracy: 0.5)
        host.rootView = wrappedProbe(token: "second", scheme: .light)
        await settle(host)
        XCTAssertEqual(probe(in: host)?.value, "second|light")
        XCTAssertEqual(background.frame.width, 180, accuracy: 0.5)
        XCTAssertEqual(background.frame.height, 54, accuracy: 0.5)
        XCTAssertFalse(fixture.panel.isVisible)
    }

    func testSwiftUIRootUpdatesPreserveSuppressedLayersDuringOutgoingAnimation() async throws {
        let packageURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let logURL = packageURL.appendingPathComponent(".build/flicker-investigation/flicker-investigation.log")
        try FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        var samples: [[String: Any]] = []
        defer {
            do {
                let data = try JSONSerialization.data(withJSONObject: samples, options: [.prettyPrinted, .sortedKeys])
                try data.write(to: logURL, options: .atomic)
                print("Flicker investigation log: \(logURL.path)")
            } catch { XCTFail("无法保存图层取证日志：\(error)") }
        }
        let fixture = try offscreenPanel()
        let container = FlippedCanvas(frame: CGRect(origin: .zero, size: fixture.panel.frame.size))
        container.wantsLayer = true
        fixture.panel.contentView = container
        func content(_ revision: Int) -> AnyView {
            AnyView(ZStack(alignment: .top) {
                IslandSwitchBackground(topRadius: 0, bottomRadius: 17,
                    fillColor: revision.isMultiple(of: 2) ? .red : .blue) { _ in
                    (revision.isMultiple(of: 2) ? Color.red : Color.blue)
                }.frame(width: 220, height: 54)
                Text("Foreground revision \(revision)").font(.system(size: 14))
                    .frame(width: 220, height: 54)
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top))
        }
        let host = NSHostingView(rootView: content(0))
        host.sizingOptions = []
        host.frame = container.bounds
        host.wantsLayer = true
        container.addSubview(host)
        let animator = IslandSlideAnimator(viewProvider: { container }, presentsSurface: false)
        defer { animator.reset(); fixture.panel.close() }
        await settle(host)
        let initialBackground = try XCTUnwrap(IslandSlideAnimator.background(in: host) as? IslandSwitchBackgroundHost)
        let initialLayer = try XCTUnwrap(host.layer)
        let initialBackgroundLayer = try XCTUnwrap(initialBackground.layer)
        let source = try XCTUnwrap(IslandSlideAnimator.geometry(in: container))
        let target = try geometry(topCenter: CGPoint(x: source.frame.midX, y: source.frame.maxY),
                                  size: CGSize(width: 260, height: 62), displayID: source.displayID)
        let request = IslandSwitchMotion(direction: .left, reduceMotion: false,
            startUptime: ProcessInfo.processInfo.systemUptime + 0.08, sourceGeometry: source, targetGeometry: target)
        var completed = false
        var violations: [String] = []
        func sample(_ stage: String) throws {
            let background = try XCTUnwrap(IslandSlideAnimator.background(in: host) as? IslandSwitchBackgroundHost)
            let foregroundLayer = try XCTUnwrap(host.layer)
            let backgroundLayer = try XCTUnwrap(background.layer)
            samples.append([
                "stage": stage, "uptime": ProcessInfo.processInfo.systemUptime,
                "windowVisible": fixture.panel.isVisible, "completionCalled": completed,
                "sameForegroundLayer": foregroundLayer === initialLayer,
                "sameBackgroundView": background === initialBackground,
                "sameBackgroundLayer": backgroundLayer === initialBackgroundLayer,
                "foregroundViewAlpha": host.alphaValue, "foregroundLayerOpacity": foregroundLayer.opacity,
                "foregroundTranslationX": foregroundLayer.transform.m41,
                "foregroundPresentationOpacity": foregroundLayer.presentation().map { $0.opacity as Any } ?? NSNull(),
                "foregroundPresentationX": foregroundLayer.presentation().map { $0.transform.m41 as Any } ?? NSNull(),
                "foregroundAnimationKeys": foregroundLayer.animationKeys() ?? [],
                "backgroundViewAlpha": background.alphaValue, "backgroundLayerOpacity": backgroundLayer.opacity,
                "backgroundPresentationOpacity": backgroundLayer.presentation().map { $0.opacity as Any } ?? NSNull(),
                "maskInstalled": container.layer?.mask != nil
            ])
            if !completed {
                if backgroundLayer.opacity != 0 { violations.append("\(stage): background.opacity=\(backgroundLayer.opacity)") }
                if foregroundLayer.opacity != 0 { violations.append("\(stage): foreground.opacity=\(foregroundLayer.opacity)") }
                if abs(foregroundLayer.transform.m41 + target.frame.width) > 0.001 {
                    violations.append("\(stage): foreground.translationX=\(foregroundLayer.transform.m41)")
                }
            }
        }
        animator.animateOutgoing(motion: request, reduceMotion: false) { completed = true }
        try sample("started")
        for revision in 1...6 {
            host.rootView = content(revision)
            await settle(host)
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            CATransaction.flush()
            try await Task.sleep(for: .milliseconds(12))
            try sample("root-update-\(revision)")
        }
        XCTAssertFalse(completed, "取证必须在出站动画完成之前采样")
        XCTAssertTrue(violations.isEmpty, "SwiftUI重绘改写了动画图层：\(violations.joined(separator: "; "))")
        XCTAssertFalse(fixture.panel.isVisible, "取证不应把测试窗口显示到用户桌面")
    }

    func testWrappedBackgroundConsumesOuterAnimationWithoutAnimatingNestedHost() async throws {
        let fixture = try offscreenPanel()
        defer { fixture.panel.close() }
        let model = SurfaceTransactionModel()
        let recorder = SurfaceTransactionRecorder()
        let host = transactionHost(model: model, recorder: recorder, in: fixture.panel)
        _ = try await transactionSamples(token: 0, recorder: recorder, host: host)
        let animation = Animation.linear(duration: 0.3)

        withTransaction(Transaction(animation: animation)) { model.token = 1 }

        let samples = try await transactionSamples(token: 1, recorder: recorder, host: host)
        XCTAssertEqual(samples.outer.animation, animation, "外层对照必须确实收到 mutation 事务")
        XCTAssertFalse(samples.outer.disablesAnimations)
        XCTAssertNil(samples.nested.animation, "当前帧由外层插值，嵌套宿主不能再次启动动画")
        XCTAssertTrue(samples.nested.disablesAnimations, "嵌套内容必须禁止二次尺寸动画")
        XCTAssertFalse(fixture.panel.isVisible)
    }

    func testWrappedBackgroundPreservesDisabledHandoffTransaction() async throws {
        let fixture = try offscreenPanel()
        defer { fixture.panel.close() }
        let model = SurfaceTransactionModel()
        let recorder = SurfaceTransactionRecorder()
        let host = transactionHost(model: model, recorder: recorder, in: fixture.panel)
        _ = try await transactionSamples(token: 0, recorder: recorder, host: host)
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true

        withTransaction(transaction) { model.token = 1 }

        let samples = try await transactionSamples(token: 1, recorder: recorder, host: host)
        XCTAssertTrue(samples.outer.disablesAnimations, "外层对照必须收到交接的禁用动画标志")
        XCTAssertNil(samples.outer.animation)
        XCTAssertTrue(samples.nested.disablesAnimations, "嵌套背景不能重新启用交接准备期的动画")
        XCTAssertNil(samples.nested.animation)
        XCTAssertFalse(fixture.panel.isVisible)
    }

    func testWrappedBackgroundInterpolatesSixStyleValuesIntoContentAndGeometry() async throws {
        let fixture = try offscreenPanel()
        defer { fixture.panel.close() }
        let recorder = SurfaceStyleRecorder()
        let start = IslandSwitchBackground(topRadius: 4, bottomRadius: 10, fillColor: .red,
            shadowOpacity: 0.1, shadowRadius: 5, shadowOffsetY: 1, strokeOpacity: 0.2) { style in
            SurfaceStyleProbe(style: style, recorder: recorder)
        }
        let end = IslandSwitchBackground(topRadius: 20, bottomRadius: 30, fillColor: .red,
            shadowOpacity: 0.7, shadowRadius: 17, shadowOffsetY: 9, strokeOpacity: 0.8) { style in
            SurfaceStyleProbe(style: style, recorder: recorder)
        }
        let host = NSHostingView(rootView: AnyView(start.frame(width: 180, height: 54)
            .environment(\.surfaceTestToken, "start")))
        host.sizingOptions = []
        host.frame = CGRect(x: 0, y: 0, width: 180, height: 54)
        fixture.panel.contentView?.addSubview(host)
        _ = try await styleSample(token: "start", recorder: recorder, host: host)

        var midpoint = start
        var difference = end.animatableData - start.animatableData
        difference.scale(by: 0.5)
        midpoint.animatableData = start.animatableData + difference
        host.rootView = AnyView(midpoint.frame(width: 180, height: 54)
            .environment(\.surfaceTestToken, "midpoint"))

        let sample = try await styleSample(token: "midpoint", recorder: recorder, host: host)
        XCTAssertEqual(sample.style.topRadius, 12, accuracy: 0.0001)
        XCTAssertEqual(sample.style.bottomRadius, 20, accuracy: 0.0001)
        XCTAssertEqual(sample.style.shadowOpacity, 0.4, accuracy: 0.0001)
        XCTAssertEqual(sample.style.shadowRadius, 11, accuracy: 0.0001)
        XCTAssertEqual(sample.style.shadowOffsetY, 5, accuracy: 0.0001)
        XCTAssertEqual(sample.style.strokeOpacity, 0.5, accuracy: 0.0001)
        let background = try XCTUnwrap(IslandSlideAnimator.background(in: host) as? IslandSwitchBackgroundHost)
        XCTAssertEqual(background.topRadius, sample.style.topRadius)
        XCTAssertEqual(background.bottomRadius, sample.style.bottomRadius)
        let geometry = try XCTUnwrap(background.switchGeometry)
        XCTAssertEqual(geometry.topRadius, sample.style.topRadius)
        XCTAssertEqual(geometry.bottomRadius, sample.style.bottomRadius)
        XCTAssertEqual(geometry.frame.width, 180, accuracy: 0.5)
        XCTAssertEqual(geometry.frame.height, 54, accuracy: 0.5)
        XCTAssertFalse(fixture.panel.isVisible)
    }

    private func styleSample(token: String, recorder: SurfaceStyleRecorder,
                             host: NSView) async throws -> SurfaceStyleSample {
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        while ProcessInfo.processInfo.systemUptime < deadline {
            host.layoutSubtreeIfNeeded()
            if let sample = recorder.latest, sample.token == token { return sample }
            try await Task.sleep(for: .milliseconds(5))
        }
        let sample = try XCTUnwrap(recorder.latest, "样式探针未更新")
        XCTAssertEqual(sample.token, token, "样式和环境必须来自同一次更新")
        return sample
    }

    private func transactionHost(model: SurfaceTransactionModel, recorder: SurfaceTransactionRecorder,
                                 in panel: NSPanel) -> NSHostingView<SurfaceTransactionOuterView> {
        let host = NSHostingView(rootView: SurfaceTransactionOuterView(model: model, recorder: recorder))
        host.sizingOptions = []
        host.frame = CGRect(x: 0, y: 0, width: 180, height: 54)
        panel.contentView?.addSubview(host)
        return host
    }

    private func transactionSamples(token: Int, recorder: SurfaceTransactionRecorder,
                                    host: NSView) async throws
        -> (outer: SurfaceTransactionSample, nested: SurfaceTransactionSample) {
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        while ProcessInfo.processInfo.systemUptime < deadline {
            host.layoutSubtreeIfNeeded()
            if let outer = recorder.samples.last(where: { $0.token == token && !$0.nested }),
               let nested = recorder.samples.last(where: { $0.token == token && $0.nested }) {
                return (outer, nested)
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        let outer = try XCTUnwrap(recorder.samples.last(where: { $0.token == token && !$0.nested }),
                                 "外层探针未收到 token \(token)")
        let nested = try XCTUnwrap(recorder.samples.last(where: { $0.token == token && $0.nested }),
                                  "嵌套探针未收到 token \(token)")
        return (outer, nested)
    }

    func testWrappedBackgroundRendersOpaqueColorAtTheSameSizeAsPlainBackground() async throws {
        let fixture = try offscreenPanel()
        defer { fixture.panel.close() }
        let size = CGSize(width: 180, height: 54)
        let red = Color(red: 1, green: 0, blue: 0)
        let plain = NSHostingView(rootView: AnyView(red.frame(width: size.width, height: size.height)))
        let wrapped = NSHostingView(rootView: AnyView(
            IslandSwitchBackground(topRadius: 0, bottomRadius: 17, fillColor: .red) { _ in red }
                .frame(width: size.width, height: size.height)))
        var samples: [NSColor] = []
        for (index, host) in [plain, wrapped].enumerated() {
            host.sizingOptions = []
            host.frame = CGRect(x: CGFloat(index) * 200, y: 20, width: size.width, height: size.height)
            fixture.panel.contentView?.addSubview(host)
            await settle(host)
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let color = try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.deviceRGB))
            samples.append(color)
            XCTAssertGreaterThan(color.alphaComponent, 0.9, "包装后背景不能变透明")
            XCTAssertGreaterThan(color.redComponent, 0.8)
            XCTAssertGreaterThan(color.redComponent, color.greenComponent + 0.2)
            XCTAssertEqual(host.bounds.size, size)
        }
        XCTAssertEqual(samples[0].redComponent, samples[1].redComponent, accuracy: 0.01)
        XCTAssertEqual(samples[0].greenComponent, samples[1].greenComponent, accuracy: 0.01)
        XCTAssertEqual(samples[0].blueComponent, samples[1].blueComponent, accuracy: 0.01)
        XCTAssertEqual(samples[0].alphaComponent, samples[1].alphaComponent, accuracy: 0.01)
        let background = try XCTUnwrap(IslandSlideAnimator.background(in: wrapped))
        XCTAssertEqual(background.bounds.width, size.width, accuracy: 0.5)
        XCTAssertEqual(background.bounds.height, size.height, accuracy: 0.5)
        XCTAssertFalse(fixture.panel.isVisible)
    }

    private func geometry(topCenter: CGPoint = CGPoint(x: -1050, y: 940),
                          size: CGSize = CGSize(width: 220, height: 54),
                          displayID: UInt32 = 2) throws -> IslandSwitchGeometry {
        try XCTUnwrap(IslandSwitchGeometry(
            frame: CGRect(x: topCenter.x - size.width / 2, y: topCenter.y - size.height,
                          width: size.width, height: size.height),
            displayID: displayID, topRadius: 0, bottomRadius: 17,
            fill: IslandSwitchColor(red: 0.08, green: 0.1, blue: 0.12, alpha: 1)))
    }

    private func motion(_ source: IslandSwitchGeometry?, _ target: IslandSwitchGeometry?) -> IslandSwitchMotion {
        IslandSwitchMotion(direction: .left, reduceMotion: false, issuedUptime: 100,
                           sourceGeometry: source, targetGeometry: target)
    }

    private func screenRect(_ local: CGRect, canvas: CGRect) -> CGRect {
        CGRect(x: canvas.minX + local.minX, y: canvas.maxY - local.maxY,
               width: local.width, height: local.height)
    }

    private func assertRect(_ value: CGRect, equals expected: CGRect,
                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(value.minX, expected.minX, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(value.minY, expected.minY, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(value.width, expected.width, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(value.height, expected.height, accuracy: 0.001, file: file, line: line)
    }

    private func assertNoScale(_ transform: CATransform3D, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(transform.m11, 1, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(transform.m22, 1, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(transform.m33, 1, accuracy: 0.001, file: file, line: line)
    }

    private struct SurfaceFixture {
        let panel: NSPanel
        let screen: NSScreen
        let container: NSView
        let host: NSHostingView<AnyView>
        let background: IslandSwitchBackgroundHost
        let originalMask: CALayer
        let animator: IslandSlideAnimator
    }

    private func surfaceFixture() throws -> SurfaceFixture {
        let fixture = try offscreenPanel()
        let container = FlippedCanvas(frame: CGRect(origin: .zero, size: fixture.panel.frame.size))
        container.wantsLayer = true
        fixture.panel.contentView = container
        let host = NSHostingView(rootView: AnyView(Text("前景保持原始字号")))
        host.sizingOptions = []
        host.frame = container.bounds
        host.wantsLayer = true
        container.addSubview(host)
        let background = IslandSwitchBackgroundHost(rootView: AnyView(Color(red: 1, green: 0, blue: 0)))
        background.sizingOptions = []
        background.frame = CGRect(x: 100, y: 10, width: 220, height: 54)
        background.bottomRadius = 17
        background.fillColor = .red
        background.wantsLayer = true
        host.addSubview(background)
        container.layoutSubtreeIfNeeded()
        let originalMask = CALayer()
        originalMask.frame = container.bounds
        originalMask.backgroundColor = NSColor.white.cgColor
        let containerLayer = try XCTUnwrap(container.layer)
        let backgroundLayer = try XCTUnwrap(background.layer)
        containerLayer.mask = originalMask
        backgroundLayer.opacity = 0.73
        let animator = IslandSlideAnimator(viewProvider: { container }, presentsSurface: false)
        return SurfaceFixture(panel: fixture.panel, screen: fixture.screen, container: container,
                              host: host, background: background, originalMask: originalMask, animator: animator)
    }

    private func assertSurfaceRestored(_ fixture: SurfaceFixture, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(fixture.container.layer?.mask === fixture.originalMask, file: file, line: line)
        XCTAssertEqual(fixture.background.layer?.opacity ?? -1, 0.73, accuracy: 0.001, file: file, line: line)
        XCTAssertTrue(CATransform3DIsIdentity(fixture.host.layer?.transform ?? CATransform3DIdentity), file: file, line: line)
        XCTAssertEqual(fixture.host.layer?.opacity, 1, file: file, line: line)
        XCTAssertFalse(fixture.panel.isVisible, file: file, line: line)
    }

    private func basicAnimations(in layer: CALayer) -> [CABasicAnimation] {
        (layer.animationKeys() ?? []).flatMap { key -> [CABasicAnimation] in
            if let animation = layer.animation(forKey: key) as? CABasicAnimation { return [animation] }
            return (layer.animation(forKey: key) as? CAAnimationGroup)?.animations?.compactMap { $0 as? CABasicAnimation } ?? []
        }
    }

    private func visibleWindowIdentifiers() -> Set<ObjectIdentifier> {
        Set(NSApp.windows.filter(\.isVisible).map(ObjectIdentifier.init))
    }

    private func offscreenPanel(overhang: CGFloat = 0) throws -> (panel: NSPanel, screen: NSScreen) {
        _ = NSApplication.shared
        guard let screen = NSScreen.screens.first else { throw XCTSkip("离屏几何验证需要可用屏幕") }
        let panel = NSPanel(contentRect: CGRect(x: screen.frame.midX - 210,
                                               y: screen.frame.maxY + overhang - 140,
                                               width: 420, height: 140),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        XCTAssertFalse(panel.isVisible)
        return (panel, screen)
    }

    private func wrappedProbe(token: String, scheme: ColorScheme) -> AnyView {
        AnyView(IslandSwitchBackground(topRadius: 0, bottomRadius: 17, fillColor: .red) { _ in
            SurfaceEnvironmentProbe()
        }
        .frame(width: 180, height: 54)
        .environment(\.surfaceTestToken, token)
        .environment(\.colorScheme, scheme))
    }

    private func settle(_ host: NSView) async {
        host.layoutSubtreeIfNeeded()
        let completed = expectation(description: "提交离屏宿主布局")
        DispatchQueue.main.async { host.layoutSubtreeIfNeeded(); completed.fulfill() }
        await fulfillment(of: [completed], timeout: 1)
        host.layoutSubtreeIfNeeded()
    }

    private func probe(in view: NSView) -> SurfaceEnvironmentProbeView? {
        if let probe = view as? SurfaceEnvironmentProbeView { return probe }
        for child in view.subviews {
            if let probe = probe(in: child) { return probe }
        }
        return nil
    }

    private final class FlippedCanvas: NSView {
        override var isFlipped: Bool { true }
    }
}

private struct SurfaceTestTokenKey: EnvironmentKey {
    static let defaultValue = "missing"
}

private extension EnvironmentValues {
    var surfaceTestToken: String {
        get { self[SurfaceTestTokenKey.self] }
        set { self[SurfaceTestTokenKey.self] = newValue }
    }
}

private final class SurfaceEnvironmentProbeView: NSView {
    var value = ""
}

private struct SurfaceEnvironmentProbe: NSViewRepresentable {
    @Environment(\.surfaceTestToken) private var token
    @Environment(\.colorScheme) private var scheme

    func makeNSView(context: Context) -> SurfaceEnvironmentProbeView { SurfaceEnvironmentProbeView() }

    func updateNSView(_ view: SurfaceEnvironmentProbeView, context: Context) {
        view.value = "\(token)|\(scheme == .dark ? "dark" : "light")"
    }
}

@MainActor @Observable
private final class SurfaceTransactionModel {
    var token = 0
}

private struct SurfaceTransactionSample {
    let token: Int
    let nested: Bool
    let animation: Animation?
    let disablesAnimations: Bool
}

@MainActor
private final class SurfaceTransactionRecorder {
    var samples: [SurfaceTransactionSample] = []
}

private struct SurfaceTransactionOuterView: View {
    let model: SurfaceTransactionModel
    let recorder: SurfaceTransactionRecorder

    var body: some View {
        let token = model.token
        ZStack {
            SurfaceTransactionProbe(token: token, nested: false, recorder: recorder)
            IslandSwitchBackground(topRadius: 0, bottomRadius: 17, fillColor: .red) { _ in
                SurfaceTransactionProbe(token: token, nested: true, recorder: recorder)
                    .scaleEffect(token.isMultiple(of: 2) ? 1 : 1.05)
            }
        }
        .frame(width: 180, height: 54)
    }
}

private struct SurfaceTransactionProbe: NSViewRepresentable {
    let token: Int
    let nested: Bool
    let recorder: SurfaceTransactionRecorder

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        recorder.samples.append(SurfaceTransactionSample(token: token, nested: nested,
            animation: context.transaction.animation, disablesAnimations: context.transaction.disablesAnimations))
    }
}

private struct SurfaceStyleSample {
    let style: IslandSwitchBackgroundStyle
    let token: String
}

@MainActor
private final class SurfaceStyleRecorder {
    var latest: SurfaceStyleSample?
}

private struct SurfaceStyleProbe: NSViewRepresentable {
    let style: IslandSwitchBackgroundStyle
    let recorder: SurfaceStyleRecorder
    @Environment(\.surfaceTestToken) private var token

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        recorder.latest = SurfaceStyleSample(style: style, token: token)
    }
}
