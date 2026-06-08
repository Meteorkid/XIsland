import SwiftUI

/// 吉祥物表情视图 — 每种运行状态对应独特的表情和动画
///
/// 设计原则：
/// - 24px 下表情清晰可辨，线条粗壮
/// - 每种状态有独特的颜色方案 + 表情形状 + 动画
/// - 所有动画尊重 reduceMotion
struct MascotView: View {
    let status: SessionStatus
    var size: CGFloat = 24
    @AppStorage("reduceMotion") private var reduceMotion = false

    var body: some View {
        Group {
            if reduceMotion {
                staticFace
            } else {
                TimelineView(.periodic(from: .now, by: 0.08)) { timeline in
                    let tick = Int(timeline.date.timeIntervalSince1970 * 1.67)
                    ZStack {
                        eyesView(tick: tick)
                            .offset(y: -size * 0.07)
                        mouthView(tick: tick)
                            .offset(y: size * 0.19)
                        extrasView(tick: tick)
                    }
                }
            }
        }
        .frame(width: size, height: size)
        .animation(nil, value: status)
    }

    /// reduceMotion 时的静态表情（无 TimelineView）
    private var staticFace: some View {
        ZStack {
            eyesView(tick: 0)
                .offset(y: -size * 0.07)
            mouthView(tick: 0)
                .offset(y: size * 0.19)
        }
    }

    // MARK: - 眼睛

    @ViewBuilder
    private func eyesView(tick: Int) -> some View {
        let eyeSpacing = size * 0.2
        let eyeSize = size * 0.17

        switch status {
        case .active:
            // 活力圆眼 + 左右看
            let lookX = lookDirection(tick: tick)
            HStack(spacing: eyeSpacing) {
               ForEach(0..<2, id: \.self) { _ in
                    ZStack {
                        Circle()
                            .fill(statusColor)
                            .frame(width: eyeSize, height: eyeSize)
                        Circle()
                            .fill(.black)
                            .frame(width: eyeSize * 0.5, height: eyeSize * 0.5)
                            .offset(x: lookX * eyeSize * 0.15)
                    }
                }
            }

        case .thinking:
            // 思考眼 — 眼球上移，单眉上扬
            HStack(spacing: eyeSpacing) {
                // 左眼：正常
                ZStack {
                    Circle()
                        .fill(statusColor)
                        .frame(width: eyeSize, height: eyeSize)
                    Circle()
                        .fill(.black)
                        .frame(width: eyeSize * 0.45, height: eyeSize * 0.45)
                        .offset(y: -eyeSize * 0.15)
                }
                // 右眼：上移（思考）
                ZStack {
                    Circle()
                        .fill(statusColor)
                        .frame(width: eyeSize, height: eyeSize)
                    Circle()
                        .fill(.black)
                        .frame(width: eyeSize * 0.45, height: eyeSize * 0.45)
                        .offset(y: -eyeSize * 0.2)
                }
                .offset(y: -eyeSize * 0.15)
            }
            // 眉毛
            .overlay(alignment: .top) {
                HStack(spacing: eyeSpacing + eyeSize) {
                    Capsule()
                        .fill(statusColor)
                        .frame(width: eyeSize * 0.9, height: eyeSize * 0.18)
                    Capsule()
                        .fill(statusColor)
                        .frame(width: eyeSize * 0.9, height: eyeSize * 0.18)
                        .rotationEffect(.degrees(-12))
                        .offset(y: -eyeSize * 0.08)
                }
                .offset(y: -eyeSize * 0.45)
            }

        case .idle:
            // 睡眼 — 半闭的横线
            let breathe = breatheScale(tick: tick)
            HStack(spacing: eyeSpacing) {
                ForEach(0..<2, id: \.self) { _ in
                    Capsule()
                        .fill(statusColor)
                        .frame(width: eyeSize * 1.1, height: eyeSize * 0.22)
                }
            }
            .scaleEffect(breathe)

        case .completed:
            // 开心眯眯眼 — 弯弯的弧线
            HStack(spacing: eyeSpacing) {
                ForEach(0..<2, id: \.self) { _ in
                    ArcShape(startAngle: .degrees(200), endAngle: .degrees(340))
                        .stroke(statusColor, style: StrokeStyle(lineWidth: size * 0.05, lineCap: .round))
                        .frame(width: eyeSize * 1.2, height: eyeSize * 0.8)
                }
            }

        case .error:
            // X 形眼 — 悲伤/崩溃
            HStack(spacing: eyeSpacing) {
                ForEach(0..<2, id: \.self) { _ in
                    ZStack {
                        Capsule()
                            .fill(statusColor)
                            .frame(width: eyeSize * 0.9, height: eyeSize * 0.22)
                            .rotationEffect(.degrees(45))
                        Capsule()
                            .fill(statusColor)
                            .frame(width: eyeSize * 0.9, height: eyeSize * 0.22)
                            .rotationEffect(.degrees(-45))
                    }
                    .frame(width: eyeSize, height: eyeSize)
                }
            }

        case .waitingPermission, .waitingAnswer, .waitingPlanReview:
            // 圆睁大眼 — 惊讶/等待
            let shake = shakeOffset(tick: tick)
            HStack(spacing: eyeSpacing) {
                ForEach(0..<2, id: \.self) { _ in
                    ZStack {
                        Circle()
                            .fill(.white)
                            .frame(width: eyeSize * 1.3, height: eyeSize * 1.3)
                        Circle()
                            .fill(statusColor)
                            .frame(width: eyeSize * 0.6, height: eyeSize * 0.6)
                    }
                }
            }
            .offset(x: shake)

        case .compacting:
            // 紧张眼 — 眉头紧锁
            let jitter = jitterOffset(tick: tick)
            HStack(spacing: eyeSpacing) {
                ForEach(0..<2, id: \.self) { _ in
                    ZStack {
                        Circle()
                            .fill(statusColor)
                            .frame(width: eyeSize, height: eyeSize)
                        Circle()
                            .fill(.black)
                            .frame(width: eyeSize * 0.45, height: eyeSize * 0.45)
                    }
                }
            }
            .offset(x: jitter)
            .overlay(alignment: .top) {
                // 皱眉
                HStack(spacing: eyeSpacing + eyeSize) {
                    Capsule()
                        .fill(statusColor)
                        .frame(width: eyeSize * 0.8, height: eyeSize * 0.18)
                        .rotationEffect(.degrees(15))
                    Capsule()
                        .fill(statusColor)
                        .frame(width: eyeSize * 0.8, height: eyeSize * 0.18)
                        .rotationEffect(.degrees(-15))
                }
                .offset(y: -eyeSize * 0.4)
            }
        }
    }

    // MARK: - 嘴巴

    @ViewBuilder
    private func mouthView(tick: Int) -> some View {
        let mouthW = size * 0.3

        switch status {
        case .active:
            // 微笑
            MouthShape(smile: true)
                .stroke(statusColor, lineWidth: size * 0.055)
                .frame(width: mouthW, height: mouthW * 0.45)

        case .thinking:
            // 嘟嘴 "..."
            let dotPhase = (tick / 5) % 4
            HStack(spacing: size * 0.035) {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(statusColor.opacity(i < dotPhase ? 1.0 : 0.2))
                        .frame(width: size * 0.055, height: size * 0.055)
                }
            }

        case .idle:
            // Zzz 嘴
            ZStack(alignment: .trailing) {
                Capsule()
                    .fill(statusColor)
                    .frame(width: mouthW * 0.5, height: size * 0.04)
                // 浮动 zzz
                if !reduceMotion {
                    let zPhase = (tick / 8) % 3
                    Text("z")
                        .font(.system(size: size * 0.2, weight: .bold, design: .rounded))
                        .foregroundStyle(statusColor.opacity(0.5))
                        .offset(x: size * 0.15, y: -size * 0.15 - CGFloat(zPhase) * size * 0.06)
                        .opacity(Double(zPhase + 1) / 3.0)
                }
            }

        case .completed:
            // 大笑嘴 — 张开的弧形
            ZStack {
                MouthShape(smile: true)
                    .fill(statusColor.opacity(0.8))
                    .frame(width: mouthW * 1.1, height: mouthW * 0.5)
                MouthShape(smile: true)
                    .fill(.black)
                    .frame(width: mouthW * 0.8, height: mouthW * 0.3)
                    .offset(y: -mouthW * 0.03)
            }

        case .error:
            // 大哭嘴 — 张开的下弯
            ZStack {
                MouthShape(smile: false)
                    .fill(statusColor.opacity(0.8))
                    .frame(width: mouthW, height: mouthW * 0.45)
                MouthShape(smile: false)
                    .fill(.black)
                    .frame(width: mouthW * 0.7, height: mouthW * 0.3)
                    .offset(y: mouthW * 0.02)
            }

        case .waitingPermission, .waitingAnswer, .waitingPlanReview:
            // O 形嘴
            Circle()
                .stroke(statusColor, lineWidth: size * 0.05)
                .frame(width: mouthW * 0.4, height: mouthW * 0.4)

        case .compacting:
            // 波浪嘴 — 紧张
            WaveShape()
                .stroke(statusColor, style: StrokeStyle(lineWidth: size * 0.05, lineCap: .round))
                .frame(width: mouthW, height: mouthW * 0.25)
        }
    }

    // MARK: - 特效（泪滴、汗珠、星星等）

    @ViewBuilder
    private func extrasView(tick: Int) -> some View {
        if reduceMotion {
            EmptyView()
        } else {
            extrasContent(tick: tick)
        }
    }

    @ViewBuilder
    private func extrasContent(tick: Int) -> some View {
        switch status {
        case .error:
            // 泪滴动画
            let tearPhase = Double((tick % 20)) / 20.0
            if tearPhase < 0.8 {
                VStack(spacing: 0) {
                    ForEach(0..<2, id: \.self) { side in
                        Circle()
                            .fill(.blue.opacity(0.6))
                            .frame(width: size * 0.07, height: size * 0.07)
                            .offset(x: CGFloat(side == 0 ? -1 : 1) * size * 0.18)
                            .offset(y: size * 0.05 + CGFloat(tearPhase) * size * 0.35)
                            .opacity(tearPhase < 0.6 ? 1.0 : 1.0 - (tearPhase - 0.6) * 5.0)
                    }
                }
            }

        case .compacting:
            // 汗珠
            let sweatY = Double((tick % 15)) / 15.0
            Circle()
                .fill(.blue.opacity(0.5))
                .frame(width: size * 0.06, height: size * 0.08)
                .offset(x: size * 0.22, y: -size * 0.15 + CGFloat(sweatY) * size * 0.2)
                .opacity(sweatY < 0.7 ? 0.7 : 0.7 - (sweatY - 0.7) * 2.3)

        case .completed:
            // 庆祝星星
            let starPhase = Double((tick % 24)) / 24.0
            Image(systemName: "star.fill")
                .font(.system(size: size * 0.18))
                .foregroundStyle(.yellow.opacity(0.7))
                .offset(x: size * 0.25, y: -size * 0.2 + CGFloat(starPhase) * size * -0.15)
                .opacity(starPhase < 0.6 ? 0.8 : 0.8 - (starPhase - 0.6) * 2.0)
                .rotationEffect(.degrees(starPhase * 360))

        case .waitingPermission:
            // 感叹号浮动
            let floatPhase = Double((tick % 20)) / 20.0
            Text("!")
                .font(.system(size: size * 0.22, weight: .bold, design: .rounded))
                .foregroundStyle(statusColor.opacity(0.6))
                .offset(x: size * 0.28, y: -size * 0.1 + CGFloat(sin(floatPhase * .pi * 2)) * size * 0.06)

        case .waitingAnswer, .waitingPlanReview:
            // 问号浮动
            let floatPhase = Double((tick % 20)) / 20.0
            Text("?")
                .font(.system(size: size * 0.22, weight: .bold, design: .rounded))
                .foregroundStyle(statusColor.opacity(0.6))
                .offset(x: size * 0.28, y: -size * 0.1 + CGFloat(sin(floatPhase * .pi * 2)) * size * 0.06)

        default:
            EmptyView()
        }
    }

    // MARK: - 动画辅助

    private var statusColor: Color {
        status.uiColor
    }

    private func lookDirection(tick: Int) -> CGFloat {
        let cycle = tick % 60
        if cycle < 15 { return 0 }
        if cycle < 30 { return 1 }
        if cycle < 40 { return 0 }
        if cycle < 55 { return -1 }
        return 0
    }

    private func breatheScale(tick: Int) -> CGFloat {
        let phase = Double(tick % 40) / 40.0
        return 1.0 + CGFloat(sin(phase * .pi * 2)) * 0.05
    }

    private func shakeOffset(tick: Int) -> CGFloat {
        let phase = Double(tick % 8) / 8.0
        return CGFloat(sin(phase * .pi * 4)) * size * 0.03
    }

    private func jitterOffset(tick: Int) -> CGFloat {
        let phase = Double(tick % 6) / 6.0
        return CGFloat(sin(phase * .pi * 6)) * size * 0.02
    }
}

// MARK: - 辅助形状

/// 弧线形状（开心眯眼用）
private struct ArcShape: Shape {
    let startAngle: Angle
    let endAngle: Angle

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addArc(
            center: CGPoint(x: rect.midX, y: rect.midY),
            radius: rect.width / 2,
            startAngle: startAngle,
            endAngle: endAngle,
            clockwise: false
        )
        return path
    }
}

/// 波浪嘴形状（compacting 用）
private struct WaveShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let midY = rect.midY
        path.move(to: CGPoint(x: rect.minX, y: midY))
        path.addCurve(
            to: CGPoint(x: rect.maxX, y: midY),
            control1: CGPoint(x: rect.width * 0.25, y: rect.minY),
            control2: CGPoint(x: rect.width * 0.75, y: rect.maxY)
        )
        return path
    }
}

/// 笑/哭嘴形状
private struct MouthShape: Shape {
    let smile: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        if smile {
            path.move(to: CGPoint(x: 0, y: rect.midY * 0.3))
            path.addQuadCurve(
                to: CGPoint(x: rect.width, y: rect.midY * 0.3),
                control: CGPoint(x: rect.midX, y: rect.height * 1.4)
            )
        } else {
            path.move(to: CGPoint(x: 0, y: rect.height * 0.7))
            path.addQuadCurve(
                to: CGPoint(x: rect.width, y: rect.height * 0.7),
                control: CGPoint(x: rect.midX, y: -rect.height * 0.3)
            )
        }
        return path
    }
}

#Preview {
    VStack(spacing: 12) {
        let statuses: [SessionStatus] = [.active, .thinking, .idle, .completed, .error, .waitingPermission, .waitingAnswer, .waitingPlanReview, .compacting]
        ForEach(statuses, id: \.self) { status in
            HStack {
                MascotView(status: status, size: 32)
                Text(status.rawValue)
                    .font(.caption)
            }
        }
    }
    .padding()
    .background(.black)
}
