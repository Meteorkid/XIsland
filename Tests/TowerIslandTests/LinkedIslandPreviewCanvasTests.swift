import AppKit
import QuartzCore
import SwiftUI
import XCTest
@testable import XIsland

@MainActor
final class LinkedIslandPreviewCanvasTests: XCTestCase {
    func testFullSceneEndpointsPreserveTransparentHoverPixelsExactly() throws {
        _ = NSApplication.shared
        let source = try snapshot(width: 80, height: 40, border: 9, seed: 17, radius: 12)
        let target = try snapshot(width: 120, height: 60, border: 4, seed: 91, radius: 18)
        let canvas = try XCTUnwrap(LinkedIslandPreviewCanvas(source: source, target: target, presentsWindow: false))
        defer { canvas.close() }
        let original = try bytes(source.image)
        XCTAssertEqual(try bytes(XCTUnwrap(canvas.renderedImage())), original)
        canvas.update(distance: 0.0001)
        let nearZero = try bytes(XCTUnwrap(canvas.renderedImage()))
        for index in stride(from: 3, to: original.count, by: 4) where original[index] == 0 {
            XCTAssertLessThanOrEqual(nearZero[index], 1, "微小位移不能突然用静态背景填满源果冻的透明边缘")
        }
        for distance in [-source.frame.width, target.frame.width] {
            canvas.update(distance: distance)
            XCTAssertEqual(try bytes(XCTUnwrap(canvas.renderedImage())), try bytes(target.image))
        }
        canvas.update(distance: 0)
        XCTAssertEqual(try bytes(XCTUnwrap(canvas.renderedImage())), original)
    }

    func testThreePagesUseOneSignedDistanceAndMatchIndependentPixelSlices() throws {
        _ = NSApplication.shared
        for (sw, sh, tw, th) in [(80, 40, 120, 60), (120, 60, 80, 40)] {
            let source = try snapshot(width: sw, height: sh, seed: 17)
            let target = try snapshot(width: tw, height: th, seed: 91)
            let canvas = try XCTUnwrap(LinkedIslandPreviewCanvas(source: source, target: target, presentsWindow: false))
            defer { canvas.close() }
            var images: [CGFloat: Data] = [:]
            for p in [CGFloat(0), 0.25, 0.5, 0.75, 1] {
                for left in [true, false] {
                    let distance = p * (left ? -source.frame.width : target.frame.width)
                    canvas.update(distance: distance)
                    XCTAssertEqual(canvas.sourceFrame.minX, distance, accuracy: 0.000_001)
                    XCTAssertEqual(canvas.leftPeerFrame.maxX, canvas.sourceFrame.minX, accuracy: 0.000_001)
                    XCTAssertEqual(canvas.sourceFrame.maxX, canvas.rightPeerFrame.minX, accuracy: 0.000_001)
                    XCTAssertEqual(canvas.sourceFrame.size, source.frame.size)
                    XCTAssertEqual(canvas.leftPeerFrame.size, target.frame.size)
                    XCTAssertEqual(canvas.rightPeerFrame.size, target.frame.size)
                    XCTAssertEqual(canvas.sourceFrame.maxY, canvas.viewportSize.height, accuracy: 0.000_001)
                    XCTAssertEqual(canvas.rightPeerFrame.maxY, canvas.viewportSize.height, accuracy: 0.000_001)
                    let image = try bytes(XCTUnwrap(canvas.renderedImage()))
                    XCTAssertEqual(image, try reference(source: source.image, target: target.image, p: p, left: left))
                    images[distance] = image
                }
            }
            for distance in [-source.frame.width / 2, 0, target.frame.width / 2, 0, -source.frame.width / 2] {
                canvas.update(distance: distance)
                XCTAssertEqual(try bytes(XCTUnwrap(canvas.renderedImage())), images[distance])
            }
        }
    }

    func testInterruptedSettleSamplesPresentationAndRejectsOldCompletion() async throws {
        let source = try snapshot(width: 80, height: 40, seed: 17)
        let target = try snapshot(width: 120, height: 60, seed: 91)
        let canvas = try XCTUnwrap(LinkedIslandPreviewCanvas(source: source, target: target, presentsWindow: false))
        defer { canvas.close() }
        canvas.update(distance: -60)
        let stale = expectation(description: "旧回弹完成回调必须失效")
        stale.isInverted = true
        canvas.settle(targetDistance: 0, duration: 0.18) { stale.fulfill() }
        try await Task.sleep(for: .milliseconds(45))
        let visibleDistance = canvas.currentDistance
        XCTAssertGreaterThan(visibleDistance, -60)
        XCTAssertLessThan(visibleDistance, 0)
        canvas.update(distance: visibleDistance)
        XCTAssertEqual(canvas.currentDistance, visibleDistance, accuracy: 0.000_001)
        let latest = expectation(description: "反向提交完成")
        canvas.settle(targetDistance: target.frame.width, duration: 0.06) { latest.fulfill() }
        await fulfillment(of: [latest, stale], timeout: 0.3)
        XCTAssertEqual(canvas.currentDistance, target.frame.width)
        XCTAssertEqual(try bytes(XCTUnwrap(canvas.renderedImage())), try bytes(target.image))
    }

    func testViewportInterpolatesDifferentScreenPositionsWithoutEndpointJump() throws {
        let source = try snapshot(width: 80, height: 40, seed: 17)
        let originalTarget = try snapshot(width: 120, height: 60, seed: 91)
        let targetFrame = originalTarget.frame.offsetBy(dx: 160, dy: -30)
        let shiftedOutline = try XCTUnwrap(IslandSwitchGeometry(frame: targetFrame, displayID: 1,
            topRadius: 0, bottomRadius: 0, fill: originalTarget.outline.fill))
        let target = IslandPreviewSnapshot(image: originalTarget.image, frame: targetFrame,
                                          scale: originalTarget.scale, outline: shiftedOutline)
        let canvas = try XCTUnwrap(LinkedIslandPreviewCanvas(source: source, target: target, presentsWindow: false))
        defer { canvas.close() }
        XCTAssertEqual(canvas.viewportScreenFrame, source.frame)
        for distance in [-source.frame.width, target.frame.width] {
            canvas.update(distance: distance)
            XCTAssertEqual(canvas.viewportScreenFrame, target.frame)
            XCTAssertEqual(try bytes(XCTUnwrap(canvas.renderedImage())), try bytes(target.image))
        }
        for distance in [-source.frame.width / 2, target.frame.width / 2] {
            canvas.update(distance: distance)
            XCTAssertEqual(canvas.viewportScreenFrame.midX, (source.frame.midX + target.frame.midX) / 2)
            XCTAssertEqual(canvas.viewportScreenFrame.maxY, (source.frame.maxY + target.frame.maxY) / 2)
        }
        canvas.update(distance: 0)
        XCTAssertEqual(canvas.viewportScreenFrame, source.frame)
        XCTAssertEqual(try bytes(XCTUnwrap(canvas.renderedImage())), try bytes(source.image))
    }

    func testFadeCancellationAndRepeatedCloseLeaveNoLateCallbacks() async throws {
        let source = try snapshot(width: 80, height: 40, seed: 17)
        let target = try snapshot(width: 120, height: 60, seed: 91)
        let canvas = try XCTUnwrap(LinkedIslandPreviewCanvas(source: source, target: target, presentsWindow: false))
        let stale = expectation(description: "被取消的淡出不能关闭新预览")
        stale.isInverted = true
        canvas.fadeOut(duration: 0.08) { stale.fulfill() }
        canvas.update(distance: 10)
        XCTAssertFalse(canvas.isClosed)
        let finished = expectation(description: "新淡出完成")
        canvas.fadeOut(duration: 0.01) { finished.fulfill() }
        await fulfillment(of: [finished, stale], timeout: 0.15)
        canvas.close()
        canvas.update(distance: 0)
        XCTAssertTrue(canvas.isClosed)
        XCTAssertNil(canvas.viewportLayer.sublayers)
        XCTAssertNil(canvas.viewportLayer.mask)
        XCTAssertNil(canvas.renderedImage())
    }

    func testCaptureHiddenOwnViewPreservesNativeProperties() async throws {
        _ = NSApplication.shared
        guard let screen = NSScreen.screens.first else { throw XCTSkip("需要可用WindowServer") }
        let frame = CGRect(x: screen.frame.midX - 50, y: screen.frame.maxY - 100, width: 100, height: 60)
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        let host = NSHostingView(rootView: Text("Own snapshot").foregroundStyle(.white)
            .frame(width: 100, height: 60).background(Color.black))
        host.sizingOptions = []
        host.frame = CGRect(origin: .zero, size: frame.size)
        panel.contentView = host
        host.wantsLayer = true
        host.alphaValue = 0.8
        host.layoutSubtreeIfNeeded()
        let settled = expectation(description: "布局就绪")
        DispatchQueue.main.async { host.layoutSubtreeIfNeeded(); settled.fulfill() }
        await fulfillment(of: [settled], timeout: 1)
        let originalFrame = host.frame, originalBounds = host.bounds
        let originalTransform = try XCTUnwrap(host.layer).transform
        let originalOpacity = host.layer?.opacity
        let originalMask = host.layer?.mask
        let id = try XCTUnwrap(screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32)
        let outline = try XCTUnwrap(IslandSwitchGeometry(frame: frame, displayID: id,
            topRadius: 0, bottomRadius: 10, fill: IslandSwitchColor(red: 0, green: 0, blue: 0, alpha: 1)))

        let result = try LinkedIslandPreviewCanvas.capture(view: host, outline: outline)

        XCTAssertEqual(result.outline, outline)
        XCTAssertEqual(result.image.width, Int((result.frame.width * result.scale).rounded()))
        XCTAssertEqual(host.alphaValue, 0.8, accuracy: 0.000_001)
        XCTAssertEqual(host.layer?.opacity, originalOpacity)
        XCTAssertTrue(CATransform3DEqualToTransform(try XCTUnwrap(host.layer).transform, originalTransform))
        XCTAssertTrue(host.layer?.mask === originalMask)
        XCTAssertEqual(host.frame, originalFrame)
        XCTAssertEqual(host.bounds, originalBounds)
        XCTAssertFalse(panel.isVisible)
    }

    func testInvalidAndDifferentScaleSnapshotsFallBackWithoutAWindow() throws {
        let source = try snapshot(width: 80, height: 40, seed: 17)
        let target = try snapshot(width: 120, height: 60, seed: 91, scale: 1)
        XCTAssertNil(LinkedIslandPreviewCanvas(source: source, target: target, presentsWindow: false))
        let invalid = IslandPreviewSnapshot(image: source.image, frame: .zero, scale: 2, outline: source.outline)
        XCTAssertNil(LinkedIslandPreviewCanvas(source: source, target: invalid, presentsWindow: false))
    }

    private func snapshot(width: Int, height: Int, border: Int = 0, seed: Int, radius: CGFloat = 0,
                          scale: CGFloat = 2) throws -> IslandPreviewSnapshot {
        _ = NSApplication.shared
        let pw = Int(CGFloat(width) * scale), ph = Int(CGFloat(height) * scale)
        let context = try XCTUnwrap(CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8,
            bytesPerRow: pw * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
        let storage = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        for y in 0..<ph {
            for x in 0..<pw {
                let offset = (y * pw + x) * 4
                let visible = x >= border && x < pw - border && y >= border && y < ph - border
                storage[offset] = visible ? UInt8(40 + (x + seed) % 160) : 0
                storage[offset + 1] = visible ? UInt8(40 + (y + seed) % 160) : 0
                storage[offset + 2] = visible ? UInt8(seed) : 0
                storage[offset + 3] = visible ? 255 : 0
            }
        }
        let image = try XCTUnwrap(context.makeImage())
        let frame = CGRect(x: 100, y: 200, width: width, height: height)
        let outline = try XCTUnwrap(IslandSwitchGeometry(frame: frame, displayID: 1,
            topRadius: 0, bottomRadius: radius, fill: IslandSwitchColor(red: 0, green: 0, blue: 0, alpha: 1)))
        return IslandPreviewSnapshot(image: image, frame: frame, scale: scale, outline: outline)
    }

    private func bytes(_ image: CGImage) throws -> Data { try XCTUnwrap(image.dataProvider?.data as Data?) }

    private func reference(source: CGImage, target: CGImage, p: CGFloat, left: Bool) throws -> Data {
        let sourceVisible = Int(((1 - p) * CGFloat(source.width)).rounded())
        let targetVisible = Int((p * CGFloat(target.width)).rounded())
        let width = sourceVisible + targetVisible
        let height = Int(((1 - p) * CGFloat(source.height) + p * CGFloat(target.height)).rounded())
        let sourceBytes = [UInt8](try bytes(source)), targetBytes = [UInt8](try bytes(target))
        var result = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let isSource = left ? x < sourceVisible : x >= targetVisible
                let column = left ? (isSource ? source.width - sourceVisible + x : x - sourceVisible)
                    : (isSource ? x - targetVisible : target.width - targetVisible + x)
                let image = isSource ? source : target, storage = isSource ? sourceBytes : targetBytes
                let output = (y * width + x) * 4
                result[output + 3] = 255
                if y < image.height {
                    let input = y * image.bytesPerRow + column * 4
                    result.replaceSubrange(output..<(output + 4), with: storage[input..<(input + 4)])
                }
            }
        }
        return Data(result)
    }
}
