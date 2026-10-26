import AppKit
import QuartzCore

/// 内容按方向平移，外壳在独立画布内连续改变尺寸；文字与命中区域不缩放。
@MainActor
final class IslandSlideAnimator {
    private let viewProvider: () -> NSView?
    private let presentsSurface: Bool
    private var generation: UInt64 = 0
    private var completionWork: DispatchWorkItem?
    private var isPreviewing = false
    private var previewOrigin: CGFloat = 0
    private var surfaceWindow: IslandSwitchSurfaceWindow?
    private weak var suppressedBackground: NSView?
    private var backgroundOpacity: Float = 1
    private var originalMask: CALayer?
    private var ownsMask = false

    static func background(in view: NSView?) -> NSView? {
        guard let view else { return nil }
        if view is IslandSwitchBackgroundSurface { return view }
        for child in view.subviews {
            if let background = background(in: child) { return background }
        }
        return nil
    }

    static func geometry(in view: NSView?) -> IslandSwitchGeometry? {
        (background(in: view) as? IslandSwitchBackgroundSurface)?.switchGeometry
    }
    private static let animationKey = "island.directional-switch"

    init(viewProvider: @escaping () -> NSView?, presentsSurface: Bool = true) {
        self.viewProvider = viewProvider
        self.presentsSurface = presentsSurface
    }

    static func previewOffset(translation: CGFloat, width: CGFloat) -> CGFloat {
        guard translation.isFinite, width.isFinite, width > 0 else { return 0 }
        let limit = max(1, min(width, 4096) * 0.32)
        return limit * CGFloat(tanh(Double(translation / limit)))
    }

    static func duration(directional: Bool, incoming: Bool, reduceMotion: Bool) -> TimeInterval {
        reduceMotion ? 0 : directional ? 0.28 : incoming ? 0.15 : 0.12
    }

    func preview(translation: CGFloat, width: CGFloat, reduceMotion: Bool) {
        guard !reduceMotion else { reset(); return }
        guard let layer = layer() else { return }
        if !isPreviewing {
            previewOrigin = currentOffset(layer)
            if let geometry = Self.geometry(in: viewProvider()), surfaceWindow == nil {
                suppressBackground()
                surfaceWindow = IslandSwitchSurfaceWindow(geometry: geometry, canvas: geometry.frame.insetBy(dx: -24, dy: -24))
                installMask(from: geometry, to: geometry, duration: 0, delay: 0)
                if presentsSurface { surfaceWindow?.show() }
            }
        }
        cancelCompletion()
        let limit = width.isFinite && width > 0 ? min(width, 4096) * 0.32 : 0
        let offset = max(-limit, min(limit, previewOrigin + Self.previewOffset(translation: translation, width: width)))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.removeAnimation(forKey: Self.animationKey)
        set(layer, offset: offset, opacity: 1)
        CATransaction.commit()
        isPreviewing = true
    }

    func returnToRest(reduceMotion: Bool) {
        guard let layer = layer() else { reset(); return }
        let offset = currentOffset(layer), opacity = currentOpacity(layer)
        guard abs(offset) > 0.01 || abs(opacity - 1) > 0.001 else { reset(); return }
        animate(layer, from: offset, to: 0, fromOpacity: opacity, toOpacity: 1,
                duration: reduceMotion ? 0 : 0.22, startUptime: nil, completion: { [weak self] in self?.restoreSurface() })
        isPreviewing = false
        previewOrigin = 0
    }

    func reset() {
        cancelCompletion()
        isPreviewing = false
        previewOrigin = 0
        restoreSurface()
        guard let layer = layer() else { return }
        layer.removeAnimation(forKey: Self.animationKey)
        set(layer, offset: 0, opacity: 1)
    }

    func animateIncoming(motion: IslandSwitchMotion?, reduceMotion: Bool, completion: @escaping () -> Void) {
        guard let layer = layer() else { cancelCompletion(); restoreSurface(); completion(); return }
        let reduced = reduceMotion || motion?.reduceMotion == true
        let duration = Self.duration(directional: motion != nil, incoming: true, reduceMotion: reduced)
        let interrupted = isPreviewing || layer.animation(forKey: Self.animationKey) != nil
        let plan = reduced ? nil : surfacePlan(motion: motion)
        let width = plan?.travel ?? max(1, min(layer.bounds.width, 4096))
        let from = interrupted ? currentOffset(layer) : -(motion?.direction.sign ?? 0) * width
        let opacity: Float = interrupted ? currentOpacity(layer) : 0
        if let plan {
            suppressBackground()
            surfaceWindow?.close()
            surfaceWindow = IslandSwitchSurfaceWindow(geometry: plan.source, canvas: plan.canvas)
            let delay = Self.delay(startUptime: motion?.startUptime, duration: duration)
            surfaceWindow?.animate(plan: plan, duration: duration, delay: delay)
            installMask(from: plan.source, to: plan.target, duration: duration, delay: delay)
            if presentsSurface { surfaceWindow?.show() }
        } else { restoreSurface() }
        animate(layer, from: from, to: 0, fromOpacity: opacity, toOpacity: 1,
                duration: duration, startUptime: motion?.startUptime) { [weak self] in
            self?.restoreSurface()
            completion()
        }
        isPreviewing = false
        previewOrigin = 0
    }

    func animateOutgoing(motion: IslandSwitchMotion?, reduceMotion: Bool, completion: @escaping () -> Void) {
        guard let layer = layer() else { cancelCompletion(); restoreSurface(); completion(); return }
        let reduced = reduceMotion || motion?.reduceMotion == true
        let duration = Self.duration(directional: motion != nil, incoming: false, reduceMotion: reduced)
        let plan = reduced ? nil : surfacePlan(motion: motion)
        if let plan {
            suppressBackground()
            // 收到同事务回执后，由目标维护唯一外壳；来源仅保留原比例的前景。
            surfaceWindow?.close()
            surfaceWindow = nil
            installMask(from: plan.source, to: plan.target, duration: duration,
                        delay: Self.delay(startUptime: motion?.startUptime, duration: duration))
        } else { restoreSurface() }
        let width = plan?.travel ?? max(1, min(layer.bounds.width, 4096))
        animate(layer, from: currentOffset(layer), to: (motion?.direction.sign ?? 0) * width,
                fromOpacity: currentOpacity(layer), toOpacity: 0,
                duration: duration, startUptime: motion?.startUptime) { [weak self] in
            completion()
            self?.restoreSurface()
        }
        isPreviewing = false
        previewOrigin = 0
    }

    private func layer() -> CALayer? {
        guard let container = viewProvider() else { return nil }
        // 遮罩留在静止的容器上；只移动里面的 SwiftUI 宿主。
        let view = container.subviews.first ?? container
        if !view.wantsLayer { view.wantsLayer = true }
        return view.layer
    }

    private func surfacePlan(motion: IslandSwitchMotion?) -> IslandSwitchSurfacePlan? {
        guard let view = viewProvider(), let screen = view.window?.screen,
              let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32,
              Self.geometry(in: view) != nil else { return nil }
        guard let plan = IslandSwitchSurfacePlan(motion: motion, displayID: id),
              screen.frame.contains(plan.source.frame), screen.frame.contains(plan.target.frame) else { return nil }
        return plan
    }

    private func suppressBackground() {
        guard suppressedBackground == nil, let view = Self.background(in: viewProvider()) else { return }
        if !view.wantsLayer { view.wantsLayer = true }
        suppressedBackground = view
        backgroundOpacity = view.layer?.opacity ?? 1
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        view.layer?.opacity = 0
        CATransaction.commit()
    }

    private func installMask(from source: IslandSwitchGeometry, to target: IslandSwitchGeometry,
                             duration: TimeInterval, delay: TimeInterval) {
        guard let view = viewProvider(), let window = view.window else { return }
        if !view.wantsLayer { view.wantsLayer = true }
        guard let container = view.layer else { return }
        if !ownsMask { originalMask = container.mask; ownsMask = true }
        let from = IslandSwitchSurfacePlan.path(for: source,
            in: view.convert(window.convertFromScreen(source.frame), from: nil))
        let to = IslandSwitchSurfacePlan.path(for: target,
            in: view.convert(window.convertFromScreen(target.frame), from: nil))
        let mask = CAShapeLayer()
        mask.frame = view.bounds
        mask.path = to
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        container.mask = mask
        if duration > 0 {
            let path = CABasicAnimation(keyPath: "path")
            path.fromValue = from; path.toValue = to; path.duration = duration
            mask.add(Self.animationGroup([path], layer: mask, duration: duration, delay: delay), forKey: "island.shell-mask")
        }
        CATransaction.commit()
    }

    private func restoreSurface() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        suppressedBackground?.layer?.opacity = backgroundOpacity
        suppressedBackground = nil
        if ownsMask { viewProvider()?.layer?.mask = originalMask }
        originalMask = nil
        ownsMask = false
        CATransaction.commit()
        surfaceWindow?.close()
        surfaceWindow = nil
    }

    static func delay(startUptime: TimeInterval?, duration: TimeInterval) -> TimeInterval {
        let delay = startUptime.map { $0 - ProcessInfo.processInfo.systemUptime } ?? 0
        return delay.isFinite ? min(0.25, max(-duration, delay)) : 0
    }

    static func animationGroup(_ animations: [CAAnimation], layer: CALayer,
                               duration: TimeInterval, delay: TimeInterval) -> CAAnimationGroup {
        let group = CAAnimationGroup()
        group.animations = animations
        group.duration = duration
        group.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) + delay
        group.fillMode = .backwards
        group.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
        return group
    }

    private func currentOffset(_ layer: CALayer) -> CGFloat {
        let value = (layer.presentation() ?? layer).value(forKeyPath: "transform.translation.x") as? NSNumber
        let result = CGFloat(value?.doubleValue ?? 0)
        return result.isFinite ? result : 0
    }

    private func currentOpacity(_ layer: CALayer) -> Float { (layer.presentation() ?? layer).opacity }

    private func set(_ layer: CALayer, offset: CGFloat, opacity: Float) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.setValue(offset, forKeyPath: "transform.translation.x")
        layer.opacity = opacity
        CATransaction.commit()
    }

    private func cancelCompletion() {
        generation &+= 1
        completionWork?.cancel()
        completionWork = nil
    }

    private func animate(_ layer: CALayer, from: CGFloat, to: CGFloat, fromOpacity: Float, toOpacity: Float,
                         duration: TimeInterval, startUptime: TimeInterval?, completion: @escaping () -> Void) {
        cancelCompletion()
        let token = generation
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.removeAnimation(forKey: Self.animationKey)
        set(layer, offset: to, opacity: toOpacity)
        guard duration > 0 else { CATransaction.commit(); completion(); return }
        let boundedDelay = Self.delay(startUptime: startUptime, duration: duration)
        let position = CABasicAnimation(keyPath: "transform.translation.x")
        position.fromValue = from; position.toValue = to; position.duration = duration
        let opacity = CABasicAnimation(keyPath: "opacity")
        opacity.fromValue = fromOpacity; opacity.toValue = toOpacity; opacity.duration = duration
        let animation = Self.animationGroup([position, opacity], layer: layer, duration: duration, delay: boundedDelay)
        layer.add(animation, forKey: Self.animationKey)
        CATransaction.commit()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.generation == token else { return }
            self.completionWork = nil
            completion()
        }
        completionWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, boundedDelay + duration), execute: work)
    }
}
