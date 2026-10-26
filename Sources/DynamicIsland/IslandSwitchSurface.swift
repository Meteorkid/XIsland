import AppKit
import SwiftUI
import QuartzCore

struct IslandSwitchBackgroundStyle {
    let topRadius: CGFloat
    let bottomRadius: CGFloat
    let shadowOpacity: CGFloat
    let shadowRadius: CGFloat
    let shadowOffsetY: CGFloat
    let strokeOpacity: CGFloat
}

/// 形状参数由外层 SwiftUI 插值，原生宿主只绘制当前帧，避免丢失或重复弹簧。
struct IslandSwitchBackground<Content: View>: View, Animatable {
    var topRadius: CGFloat
    var bottomRadius: CGFloat
    var fillColor: NSColor
    var allowsMorph: Bool = true
    var shadowOpacity: CGFloat = 0
    var shadowRadius: CGFloat = 0
    var shadowOffsetY: CGFloat = 0
    var strokeOpacity: CGFloat = 0
    @ViewBuilder var content: (IslandSwitchBackgroundStyle) -> Content

    typealias AnimatableData = AnimatablePair<AnimatablePair<CGFloat, CGFloat>,
        AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>>>

    var animatableData: AnimatableData {
        get { .init(.init(topRadius, bottomRadius),
                    .init(.init(shadowOpacity, shadowRadius), .init(shadowOffsetY, strokeOpacity))) }
        set {
            topRadius = newValue.first.first
            bottomRadius = newValue.first.second
            shadowOpacity = newValue.second.first.first
            shadowRadius = newValue.second.first.second
            shadowOffsetY = newValue.second.second.first
            strokeOpacity = newValue.second.second.second
        }
    }

    var body: some View {
        IslandSwitchBackgroundRenderer(
            style: IslandSwitchBackgroundStyle(topRadius: topRadius, bottomRadius: bottomRadius,
                shadowOpacity: shadowOpacity, shadowRadius: shadowRadius,
                shadowOffsetY: shadowOffsetY, strokeOpacity: strokeOpacity),
            fillColor: fillColor, allowsMorph: allowsMorph, content: content)
    }
}

private struct IslandSwitchBackgroundRenderer<Content: View>: NSViewRepresentable {
    var style: IslandSwitchBackgroundStyle
    var fillColor: NSColor
    var allowsMorph: Bool
    var content: (IslandSwitchBackgroundStyle) -> Content

    func makeNSView(context: Context) -> IslandSwitchBackgroundHost {
        let view = IslandSwitchBackgroundHost(rootView: AnyView(content(style).environment(\.self, context.environment)))
        view.sizingOptions = []
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: IslandSwitchBackgroundHost, context: Context) {
        var transaction = context.transaction
        transaction.animation = nil
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            view.rootView = AnyView(content(style).environment(\.self, context.environment)
                .transaction { $0 = transaction })
        }
        view.topRadius = style.topRadius
        view.bottomRadius = style.bottomRadius
        view.fillColor = fillColor
        view.allowsMorph = allowsMorph
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: IslandSwitchBackgroundHost,
                     context: Context) -> CGSize? {
        guard let width = proposal.width, let height = proposal.height else { return nil }
        return CGSize(width: width, height: height)
    }
}

@MainActor
protocol IslandSwitchBackgroundSurface: AnyObject {
    var switchGeometry: IslandSwitchGeometry? { get }
}

final class IslandSwitchBackgroundHost: NSHostingView<AnyView>, IslandSwitchBackgroundSurface {
    var topRadius: CGFloat = 0
    var bottomRadius: CGFloat = 0
    var fillColor: NSColor = .black
    var allowsMorph = true

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    var switchGeometry: IslandSwitchGeometry? {
        guard allowsMorph, let window, let screen = window.screen,
              let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32,
              let color = fillColor.usingColorSpace(.deviceRGB) else { return nil }
        // 顶部的 4/6pt 窗口延伸不属于屏幕内可见轮廓。
        let frame = window.convertToScreen(convert(bounds, to: nil)).intersection(screen.frame)
        return IslandSwitchGeometry(frame: frame, displayID: displayID,
            topRadius: topRadius, bottomRadius: bottomRadius,
            fill: IslandSwitchColor(red: color.redComponent, green: color.greenComponent,
                                    blue: color.blueComponent, alpha: color.alphaComponent))
    }
}

/// 两端只对同一屏幕上的有效轮廓做形变，旧端/玻璃材质/跨屏仍使用方向淡入淡出。
struct IslandSwitchSurfacePlan {
    let source: IslandSwitchGeometry
    let target: IslandSwitchGeometry

    init?(motion: IslandSwitchMotion?, displayID: UInt32?) {
        guard let source = motion?.sourceGeometry, let target = motion?.targetGeometry,
              source.displayID == target.displayID, source.displayID == displayID,
              source.isValid, target.isValid else { return nil }
        self.source = source
        self.target = target
    }

    var canvas: CGRect { source.frame.union(target.frame).insetBy(dx: -24, dy: -24) }
    var travel: CGFloat { max(source.frame.width, target.frame.width) }

    static func path(for geometry: IslandSwitchGeometry, in rect: CGRect) -> CGPath {
        UnevenRoundedRectangle(topLeadingRadius: geometry.topRadius,
            bottomLeadingRadius: geometry.bottomRadius, bottomTrailingRadius: geometry.bottomRadius,
            topTrailingRadius: geometry.topRadius, style: .continuous).path(in: rect).cgPath
    }

    static func color(_ color: IslandSwitchColor) -> CGColor {
        NSColor(deviceRed: color.red, green: color.green, blue: color.blue, alpha: color.alpha).cgColor
    }

    /// 屏幕是 y 向上，layer 画布是 y 向下；顶边和中心均由同一全局坐标插值。
    static func localRect(_ frame: CGRect, canvas: CGRect) -> CGRect {
        CGRect(x: frame.minX - canvas.minX, y: canvas.maxY - frame.maxY,
               width: frame.width, height: frame.height)
    }
}

@MainActor
final class IslandSwitchSurfaceWindow {
    private let panel: NSPanel
    private let shape = CAShapeLayer()

    init(geometry: IslandSwitchGeometry, canvas: CGRect) {
        panel = NSPanel(contentRect: canvas, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        // XI / XNook 分别为 statusBar+1/+2；共享外壳必须低于两者的前景。
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        let view = SurfaceCanvas(frame: CGRect(origin: .zero, size: canvas.size))
        view.wantsLayer = true
        panel.contentView = view
        shape.frame = view.bounds
        shape.contentsScale = panel.backingScaleFactor
        shape.path = IslandSwitchSurfacePlan.path(for: geometry,
            in: IslandSwitchSurfacePlan.localRect(geometry.frame, canvas: canvas))
        shape.fillColor = IslandSwitchSurfacePlan.color(geometry.fill)
        view.layer?.addSublayer(shape)
    }

    func show() { panel.orderFrontRegardless() }
    func close() { panel.close() }

    func animate(plan: IslandSwitchSurfacePlan, duration: TimeInterval, delay: TimeInterval) {
        let from = IslandSwitchSurfacePlan.path(for: plan.source,
            in: IslandSwitchSurfacePlan.localRect(plan.source.frame, canvas: plan.canvas))
        let to = IslandSwitchSurfacePlan.path(for: plan.target,
            in: IslandSwitchSurfacePlan.localRect(plan.target.frame, canvas: plan.canvas))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shape.path = to
        shape.fillColor = IslandSwitchSurfacePlan.color(plan.target.fill)
        let path = CABasicAnimation(keyPath: "path")
        path.fromValue = from; path.toValue = to; path.duration = duration
        let fill = CABasicAnimation(keyPath: "fillColor")
        fill.fromValue = IslandSwitchSurfacePlan.color(plan.source.fill)
        fill.toValue = IslandSwitchSurfacePlan.color(plan.target.fill); fill.duration = duration
        let group = IslandSlideAnimator.animationGroup([path, fill], layer: shape, duration: duration, delay: delay)
        shape.add(group, forKey: "island.shell-morph")
        CATransaction.commit()
    }

    private final class SurfaceCanvas: NSView {
        override var isFlipped: Bool { true }
    }
}
