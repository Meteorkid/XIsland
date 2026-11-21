import SwiftUI

private struct TaskAttentionPresentedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// 仅在岛内容已真实显示时播放；隐藏窗口和静态图例不消费提醒动画。
    var taskAttentionPresented: Bool {
        get { self[TaskAttentionPresentedKey.self] }
        set { self[TaskAttentionPresentedKey.self] = newValue }
    }
}

/// 每次提醒只跳两下，之后保持静态角标；不安装常驻逐帧定时器。
struct TaskAttentionBounce: ViewModifier {
    let token: String?
    let size: CGFloat
    let enabled: Bool
    /// 未查看时持续提醒：跳完停一会儿再来一次；单次模式（默认）只跳一次。
    var repeats: Bool = false
    @State private var progress = 1.0

    private var shouldAnimate: Bool { enabled && token != nil }

    func body(content: Content) -> some View {
        content
            .modifier(TaskAttentionBounceFrame(progress: shouldAnimate ? progress : 1, size: size))
            .transaction { transaction in
                if !shouldAnimate {
                    transaction.animation = nil
                    transaction.disablesAnimations = true
                }
            }
            .task(id: enabled ? token : nil) {
                guard shouldAnimate else { return }
                while !Task.isCancelled {
                    var transaction = Transaction(animation: nil)
                    transaction.disablesAnimations = true
                    withTransaction(transaction) { progress = 0 }
                    await Task.yield()
                    guard !Task.isCancelled else { return }
                    withAnimation(.linear(duration: TaskAttentionBounceFrame.duration)) { progress = 1 }
                    guard repeats else { return }
                    // 跳完停顿，避免变成连续抖动。
                    try? await Task.sleep(nanoseconds: 2_400_000_000)
                }
            }
    }
}

struct TaskAttentionBounceFrame: AnimatableModifier {
    static let duration: TimeInterval = 1.05
    var progress: Double
    let size: CGFloat

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    struct Pose: Equatable {
        var scale: CGFloat = 1
        var lift: CGFloat = 0
    }

    static func pose(progress: Double, size: CGFloat) -> Pose {
        guard progress.isFinite, size.isFinite, size > 0, progress > 0, progress < 1 else { return Pose() }
        let bounce = abs(sin(progress * .pi * 2))
        let amplitude = min(size * 0.16, 5)
        // 整体缩放 + 轻微上抛：读起来是图标自己在弹跳，而不是被平移或旋转。
        let envelope = 1 - 0.35 * progress
        return Pose(scale: 1 + bounce * 0.18,
                    lift: -bounce * amplitude * envelope)
    }

    func body(content: Content) -> some View {
        let pose = Self.pose(progress: progress, size: size)
        content
            .scaleEffect(pose.scale, anchor: .bottom)
            .offset(y: pose.lift)
    }
}
