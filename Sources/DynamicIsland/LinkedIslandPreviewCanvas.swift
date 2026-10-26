import AppKit
import QuartzCore

/// 源端持有的三页快照画布。仅修改自有图层，真实窗口与其 HostingView 由协调器管理。
@MainActor
final class LinkedIslandPreviewCanvas {
    enum CaptureError: Error {
        case invalidGeometry, missingWindow, invalidFrame, bitmapUnavailable, imageUnavailable
    }

    private let source: IslandPreviewSnapshot
    private let target: IslandPreviewSnapshot
    private let canvasFrame: CGRect
    private let panel: NSPanel
    private let root = CALayer()
    let viewportLayer = CALayer()
    private let sourcePage = CALayer()
    private let leftPage = CALayer()
    private let rightPage = CALayer()
    private let background = CAShapeLayer()
    private let clip = CAShapeLayer()
    private var distance: CGFloat = 0
    private var animationStartDistance: CGFloat = 0
    private var isSettling = false
    private var isFading = false
    private var generation: UInt64 = 0
    private var pendingCompletion: DispatchWorkItem?
    private(set) var isClosed = false
    private static let motionKey = "linked-island.motion"
    private static let fadeKey = "linked-island.fade"

    var windowNumber: Int { panel.windowNumber }
    var currentDistance: CGFloat {
        guard isSettling else { return distance }
        let sampled = sourcePage.presentation()?.position.x ?? animationStartDistance
        return bounded(sampled)
    }
    var viewportSize: CGSize { layout(at: currentDistance).size }
    var viewportScreenFrame: CGRect {
        let state = layout(at: currentDistance)
        return CGRect(x: canvasFrame.minX + state.position.x - state.size.width / 2,
                      y: canvasFrame.minY + state.position.y - state.size.height,
                      width: state.size.width, height: state.size.height)
    }
    var sourceFrame: CGRect { sourcePage.frame }
    var leftPeerFrame: CGRect { leftPage.frame }
    var rightPeerFrame: CGRect { rightPage.frame }

    init?(source: IslandPreviewSnapshot, target: IslandPreviewSnapshot, presentsWindow: Bool = true) {
        guard Self.valid(source), Self.valid(target), abs(source.scale - target.scale) < 0.000_1 else { return nil }
        self.source = source
        self.target = target
        let scale = source.scale
        let frame = Self.pixelAligned(source.frame.union(target.frame), scale: scale)
        guard Self.validFrame(frame), frame.width * scale * frame.height * scale <= 4_000_000 else { return nil }
        canvasFrame = frame
        panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isRestorable = false
        panel.animationBehavior = .none
        panel.level = .statusBar + 4
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        root.frame = CGRect(origin: .zero, size: frame.size)
        root.contentsScale = scale
        panel.contentView = CanvasView(frame: root.bounds, root: root)
        viewportLayer.anchorPoint = CGPoint(x: 0.5, y: 1)
        viewportLayer.contentsScale = scale
        viewportLayer.masksToBounds = true
        root.addSublayer(viewportLayer)
        for layer in [background, clip] {
            layer.frame = CGRect(origin: .zero, size: frame.size)
            layer.contentsScale = scale
        }
        viewportLayer.addSublayer(background)
        viewportLayer.mask = clip
        for (layer, snapshot) in [(leftPage, target), (sourcePage, source), (rightPage, target)] {
            layer.anchorPoint = CGPoint(x: 0, y: 1)
            layer.bounds = CGRect(origin: .zero, size: snapshot.frame.size)
            layer.contents = snapshot.image
            layer.contentsScale = snapshot.scale
            layer.contentsGravity = .resize
            layer.edgeAntialiasingMask = []
            viewportLayer.addSublayer(layer)
        }
        apply(layout(at: 0))
        CATransaction.commit()
        if presentsWindow {
            panel.orderFrontRegardless()
            panel.displayIfNeeded()
            CATransaction.flush()
        }
    }

    /// 截取本进程视图的屏幕内部分；不改变 alpha、mask、transform、窗口顺序或显示意图。
    static func capture(view: NSView, outline: IslandSwitchGeometry) throws -> IslandPreviewSnapshot {
        guard outline.isValid else { throw CaptureError.invalidGeometry }
        guard let window = view.window, let screen = window.screen else { throw CaptureError.missingWindow }
        view.layoutSubtreeIfNeeded()
        let scale = window.backingScaleFactor
        let raw = window.convertToScreen(view.convert(view.bounds, to: nil)).intersection(screen.frame)
        let frame = pixelAligned(raw, scale: scale).intersection(screen.frame)
        guard validFrame(frame), (0.5...8).contains(scale),
              frame.width * scale * frame.height * scale <= 4_000_000,
              frame.insetBy(dx: -1 / scale, dy: -1 / scale).contains(outline.frame) else {
            throw CaptureError.invalidFrame
        }
        let local = view.convert(window.convertFromScreen(frame), from: nil)
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: local) else { throw CaptureError.bitmapUnavailable }
        view.cacheDisplay(in: local, to: bitmap)
        guard let rawImage = bitmap.cgImage,
              let context = imageContext(width: rawImage.width, height: rawImage.height) else {
            throw CaptureError.imageUnavailable
        }
        // 统一快照色彩空间与像素格式，后续预览不再对文字图像做重采样。
        context.draw(rawImage, in: CGRect(x: 0, y: 0, width: rawImage.width, height: rawImage.height))
        guard let image = context.makeImage() else { throw CaptureError.imageUnavailable }
        let snapshot = IslandPreviewSnapshot(image: image, frame: frame, scale: scale, outline: outline)
        guard valid(snapshot) else { throw CaptureError.invalidFrame }
        return snapshot
    }

    func update(distance: CGFloat) {
        guard !isClosed, distance.isFinite else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cancelAnimation()
        self.distance = bounded(distance)
        apply(layout(at: self.distance))
        setRootOpacity(1)
        CATransaction.commit()
    }

    func settle(targetDistance: CGFloat, duration: TimeInterval = 0.24,
                completion: @escaping @MainActor () -> Void) {
        guard !isClosed, targetDistance.isFinite else { return }
        let start = currentDistance
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cancelAnimation()
        let end = bounded(targetDistance)
        animationStartDistance = start
        distance = end
        let duration = duration.isFinite ? max(0, min(1, duration)) : 0
        apply(layout(at: end))
        setRootOpacity(1)
        guard duration > 0, abs(end - start) > 0.000_1 else {
            CATransaction.commit()
            completion()
            return
        }
        isSettling = true
        var times = (0...24).map { Double($0) / 24 }
        if start * end < 0 { times.append(Double(-start / (end - start))) }
        times = Array(Set(times)).sorted()
        let layouts = times.map { layout(at: start + CGFloat($0) * (end - start)) }
        let now = CACurrentMediaTime()
        animate(viewportLayer, properties: ["bounds": layouts.map { NSValue(rect: CGRect(origin: .zero, size: $0.size)) },
            "position": layouts.map { NSValue(point: $0.position) }],
                times: times, duration: duration, start: now)
        animate(sourcePage, properties: ["position": layouts.map { NSValue(point: $0.sourcePosition) }],
                times: times, duration: duration, start: now)
        animate(leftPage, properties: ["position": layouts.map { NSValue(point: $0.leftPosition) }],
                times: times, duration: duration, start: now)
        animate(rightPage, properties: ["position": layouts.map { NSValue(point: $0.rightPosition) }],
                times: times, duration: duration, start: now)
        animate(background, properties: ["path": layouts.map(\.backgroundPath),
            "fillColor": layouts.map(\.color), "opacity": layouts.map { NSNumber(value: $0.backgroundOpacity) }],
                times: times, duration: duration, start: now)
        animate(clip, properties: ["path": layouts.map(\.clipPath)], times: times, duration: duration, start: now)
        CATransaction.commit()
        scheduleCompletion(after: duration) { [weak self] in
            guard let self else { return }
            self.isSettling = false
            self.removeMotionAnimations()
            completion()
        }
    }

    /// 真实页面先在背后就位，画布仅淡出自身；完成时关闭临时窗口。
    func fadeOut(duration: TimeInterval = 0.12, completion: @escaping @MainActor () -> Void) {
        guard !isClosed else { return }
        let current = currentDistance
        let opacity = root.presentation()?.opacity ?? root.opacity
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cancelAnimation()
        distance = current
        apply(layout(at: current))
        let duration = duration.isFinite ? max(0, min(1, duration)) : 0
        setRootOpacity(0)
        guard duration > 0 else {
            CATransaction.commit()
            close()
            completion()
            return
        }
        isFading = true
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = opacity
        animation.toValue = 0
        animation.duration = duration
        root.add(animation, forKey: Self.fadeKey)
        CATransaction.commit()
        scheduleCompletion(after: duration) { [weak self] in
            guard let self else { return }
            self.close()
            completion()
        }
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        panel.close()
        cancelAnimation()
        for page in [sourcePage, leftPage, rightPage] { page.contents = nil }
        viewportLayer.mask = nil
        viewportLayer.sublayers = nil
        root.sublayers = nil
    }

    deinit {
        pendingCompletion?.cancel()
        let panel = panel
        DispatchQueue.main.async { panel.close() }
    }

    /// 对静止进度做离屏像素验证；不代表屏幕呈现帧率。
    func renderedImage() -> CGImage? {
        guard !isClosed, !isSettling, !isFading else { return nil }
        let size = viewportLayer.bounds.size
        guard let context = Self.imageContext(width: Int((size.width * source.scale).rounded()),
                                               height: Int((size.height * source.scale).rounded())) else { return nil }
        context.scaleBy(x: source.scale, y: source.scale)
        viewportLayer.render(in: context)
        return context.makeImage()
    }

    private struct Layout {
        let size: CGSize
        let position: CGPoint
        let sourcePosition: CGPoint
        let leftPosition: CGPoint
        let rightPosition: CGPoint
        let backgroundPath: CGPath
        let clipPath: CGPath
        let color: CGColor
        let backgroundOpacity: Float
    }

    private func layout(at distance: CGFloat) -> Layout {
        let p = min(1, abs(distance) / (distance < 0 ? source.frame.width : target.frame.width))
        func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * p }
        let size = CGSize(width: mix(source.frame.width, target.frame.width),
                          height: mix(source.frame.height, target.frame.height))
        let from = source.outline.frame.offsetBy(dx: -source.frame.minX, dy: -source.frame.minY)
        let to = target.outline.frame.offsetBy(dx: -target.frame.minX, dy: -target.frame.minY)
        let outline = CGRect(x: mix(from.minX, to.minX), y: mix(from.minY, to.minY),
                             width: mix(from.width, to.width), height: mix(from.height, to.height))
        let top = mix(source.outline.topRadius, target.outline.topRadius)
        let bottom = mix(source.outline.bottomRadius, target.outline.bottomRadius)
        // 两端使用原始快照的透明像素，不能用静态黑壳覆盖正在果冻形变的源轮廓。
        let ramp = min(1, min(p, 1 - p) * 4)
        let envelope = ramp * ramp * (3 - 2 * ramp)
        let clipping = CGRect(x: outline.minX * envelope, y: outline.minY * envelope,
            width: size.width + (outline.width - size.width) * envelope,
            height: size.height + (outline.height - size.height) * envelope)
        let color = target.outline.fill
        let startColor = source.outline.fill
        return Layout(size: size,
            position: CGPoint(x: mix(source.frame.midX, target.frame.midX) - canvasFrame.minX,
                              y: mix(source.frame.maxY, target.frame.maxY) - canvasFrame.minY),
            sourcePosition: CGPoint(x: distance, y: size.height),
            leftPosition: CGPoint(x: -target.frame.width + distance, y: size.height),
            rightPosition: CGPoint(x: source.frame.width + distance, y: size.height),
            backgroundPath: Self.path(outline, top: top, bottom: bottom),
            clipPath: Self.path(clipping, top: top * envelope, bottom: bottom * envelope),
            color: CGColor(srgbRed: mix(startColor.red, color.red), green: mix(startColor.green, color.green),
                           blue: mix(startColor.blue, color.blue), alpha: mix(startColor.alpha, color.alpha)),
            backgroundOpacity: Float(envelope))
    }

    private func apply(_ layout: Layout) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        viewportLayer.bounds = CGRect(origin: .zero, size: layout.size)
        viewportLayer.position = layout.position
        sourcePage.position = layout.sourcePosition
        leftPage.position = layout.leftPosition
        rightPage.position = layout.rightPosition
        background.path = layout.backgroundPath
        background.fillColor = layout.color
        background.opacity = layout.backgroundOpacity
        clip.path = layout.clipPath
        CATransaction.commit()
    }

    private func animate(_ layer: CALayer, properties: [String: [Any]], times: [Double],
                         duration: TimeInterval, start: TimeInterval) {
        let group = CAAnimationGroup()
        group.animations = properties.map { key, values in
            let animation = CAKeyframeAnimation(keyPath: key)
            animation.values = values
            animation.keyTimes = times.map { NSNumber(value: $0) }
            animation.duration = duration
            animation.calculationMode = .linear
            return animation
        }
        group.duration = duration
        group.beginTime = layer.convertTime(start, from: nil)
        group.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
        layer.add(group, forKey: Self.motionKey)
    }

    private func scheduleCompletion(after duration: TimeInterval, action: @escaping @MainActor () -> Void) {
        let token = generation
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isClosed, self.generation == token else { return }
            self.pendingCompletion = nil
            action()
        }
        pendingCompletion = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    private func cancelAnimation() {
        generation &+= 1
        pendingCompletion?.cancel()
        pendingCompletion = nil
        isSettling = false
        isFading = false
        removeMotionAnimations()
        root.removeAnimation(forKey: Self.fadeKey)
    }

    private func removeMotionAnimations() {
        for layer in [viewportLayer, sourcePage, leftPage, rightPage, background, clip] {
            layer.removeAnimation(forKey: Self.motionKey)
        }
    }

    private func setRootOpacity(_ opacity: Float) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        root.opacity = opacity
        CATransaction.commit()
    }

    private func bounded(_ value: CGFloat) -> CGFloat { max(-source.frame.width, min(target.frame.width, value)) }

    private static func validFrame(_ frame: CGRect) -> Bool {
        [frame.origin.x, frame.origin.y, frame.size.width, frame.size.height].allSatisfy(\.isFinite)
            && abs(frame.origin.x) <= 100_000 && abs(frame.origin.y) <= 100_000
            && frame.size.width > 0 && frame.size.width <= 4096 && frame.size.height > 0 && frame.size.height <= 2048
    }

    private static func valid(_ snapshot: IslandPreviewSnapshot) -> Bool {
        guard validFrame(snapshot.frame), snapshot.outline.isValid, snapshot.scale.isFinite,
              (0.5...8).contains(snapshot.scale), snapshot.image.width * snapshot.image.height <= 4_000_000,
              Int((snapshot.frame.width * snapshot.scale).rounded()) == snapshot.image.width,
              Int((snapshot.frame.height * snapshot.scale).rounded()) == snapshot.image.height else { return false }
        return snapshot.frame.insetBy(dx: -1 / snapshot.scale, dy: -1 / snapshot.scale).contains(snapshot.outline.frame)
    }

    private static func pixelAligned(_ rect: CGRect, scale: CGFloat) -> CGRect {
        guard !rect.isNull, scale.isFinite, scale > 0 else { return .null }
        let minX = floor(rect.minX * scale) / scale, minY = floor(rect.minY * scale) / scale
        return CGRect(x: minX, y: minY, width: ceil(rect.maxX * scale) / scale - minX,
                      height: ceil(rect.maxY * scale) / scale - minY)
    }

    private static func imageContext(width: Int, height: Int) -> CGContext? {
        guard width > 0, height > 0, width * height <= 4_000_000,
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: space,
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    private static func path(_ rect: CGRect, top: CGFloat, bottom: CGFloat) -> CGPath {
        let top = max(0, min(top, min(rect.width / 2, rect.height / 2)))
        let bottom = max(0, min(bottom, min(rect.width / 2, rect.height / 2)))
        let path = CGMutablePath()
        path.move(to: CGPoint(x: rect.minX + top, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - top, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.maxY - top),
                          control: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + bottom))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - bottom, y: rect.minY),
                          control: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + bottom, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.minY + bottom),
                          control: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - top))
        path.addQuadCurve(to: CGPoint(x: rect.minX + top, y: rect.maxY),
                          control: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }

    /// 固定窗口上的 layer-hosting 视图；内部没有任何 NSHostingView。
    private final class CanvasView: NSView {
        init(frame: CGRect, root: CALayer) {
            super.init(frame: frame)
            layer = root
            wantsLayer = true
        }
        required init?(coder: NSCoder) { return nil }
    }
}
