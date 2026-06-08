import SwiftUI

// MARK: - 工具完成波纹效果

/// 工具调用完成时：绿色背景闪光 + checkmark scale 弹入 + 持续时间缩短
struct ToolCompletionEffect: ViewModifier {
    let isComplete: Bool
    let reduceMotion: Bool

    @State private var showFlash = false

    func body(content: Content) -> some View {
        content
            .background(
                Group {
                    if showFlash {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(.green.opacity(0.25))
                            .transition(.opacity)
                    }
                }
            )
            .onChange(of: isComplete) { _, newValue in
                guard newValue, !reduceMotion else { return }
                showFlash = true
            }
            .task(id: showFlash) {
                guard showFlash else { return }
                try? await Task.sleep(for: .milliseconds(500))
                withAnimation(.easeOut(duration: 0.3)) {
                    showFlash = false
                }
            }
    }
}

// MARK: - 活动日志新事件闪光拖尾

/// 新事件出现时：从右向左扫过一道亮光 + scale 弹入
struct ActivityLogGlowTrail: ViewModifier {
    let isActive: Bool
    let reduceMotion: Bool

    @State private var sweepProgress: CGFloat = 0
    @State private var entryScale: CGFloat = 0.92

    func body(content: Content) -> some View {
        content
            .overlay(
                Group {
                    if !reduceMotion && sweepProgress > 0 && sweepProgress < 1 {
                        GeometryReader { geo in
                            Rectangle()
                                .fill(
                                    LinearGradient(
                                        colors: [
                                            .clear,
                                            .white.opacity(0.18),
                                            .white.opacity(0.08),
                                            .clear
                                        ],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                .frame(width: geo.size.width * 0.4)
                                .offset(x: geo.size.width * (sweepProgress * 1.4 - 0.4))
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    }
                }
            )
            .scaleEffect(entryScale)
            .onAppear {
                guard !reduceMotion else {
                    entryScale = 1.0
                    return
                }
                withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                    entryScale = 1.0
                }
                guard isActive else { return }
                withAnimation(.easeInOut(duration: 0.7)) {
                    sweepProgress = 1.0
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                    sweepProgress = 0
                }
            }
    }
}

// MARK: - 活跃会话呼吸光晕

/// 正在运行/思考的会话卡片边框呼吸脉冲光晕
struct ActiveSessionGlow: ViewModifier {
    let isRunning: Bool
    let color: Color
    let reduceMotion: Bool

    func body(content: Content) -> some View {
        content
            .overlay(
                Group {
                    if isRunning && !reduceMotion {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(color.opacity(0.35), lineWidth: 1)
                            .phaseAnimator([false, true]) { view, phase in
                                view
                                    .opacity(phase ? 0.4 : 0.1)
                            } animation: { _ in .easeInOut(duration: 1.8).repeatForever(autoreverses: true) }
                    }
                }
            )
    }
}

// MARK: - 会话状态变化颜色扫过

/// 状态切换时从左到右扫过一道颜色光带
struct StatusChangeSweep: ViewModifier {
    let statusColor: Color
    let trigger: AnyHashable
    let reduceMotion: Bool

    @State private var sweepOffset: CGFloat = -1.0

    func body(content: Content) -> some View {
        content
            .overlay(
                Group {
                    if sweepOffset > -1.0 && sweepOffset < 1.5 {
                        GeometryReader { geo in
                            LinearGradient(
                                colors: [
                                    .clear,
                                    statusColor.opacity(0.3),
                                    statusColor.opacity(0.15),
                                    .clear
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                            .frame(width: geo.size.width * 0.35)
                            .offset(x: geo.size.width * sweepOffset)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .allowsHitTesting(false)
                    }
                }
            )
            .onChange(of: trigger) { _, _ in
                guard !reduceMotion else { return }
                sweepOffset = -1.0
                withAnimation(.easeInOut(duration: 0.6)) {
                    sweepOffset = 1.5
                }
            }
    }
}
