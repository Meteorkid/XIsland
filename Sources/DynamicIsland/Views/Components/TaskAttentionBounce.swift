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
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                withTransaction(transaction) { progress = 0 }
                await Task.yield()
                guard !Task.isCancelled else { return }
                withAnimation(.linear(duration: TaskAttentionBounceFrame.duration)) { progress = 1 }
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
        var lift: CGFloat = 0
        var rotation: Double = 0
    }

    static func pose(progress: Double, size: CGFloat) -> Pose {
        guard progress.isFinite, size.isFinite, size > 0, progress > 0, progress < 1 else { return Pose() }
        let amplitude = min(size * 0.16, 5)
        let envelope = 1 - 0.35 * progress
        return Pose(lift: -abs(sin(progress * .pi * 2)) * amplitude * envelope,
                    rotation: sin(progress * .pi * 4) * 5 * (1 - progress))
    }

    func body(content: Content) -> some View {
        let pose = Self.pose(progress: progress, size: size)
        content
            .rotationEffect(.degrees(pose.rotation), anchor: .bottom)
            .offset(y: pose.lift)
    }
}
