import SwiftUI

struct MarqueeText: View {
    let text: String
    let font: Font
    let availableWidth: CGFloat
    var speed: CGFloat = 25

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @AppStorage("reduceMotion") private var appReduceMotion = false
    @AppStorage("disableAnimations") private var disableAnimations = false
    @State private var textWidth: CGFloat = 0
    @State private var startTime: Date = .now
    @State private var isVisible = false

    private var shouldAnimate: Bool {
        Self.shouldAnimate(
            textWidth: textWidth,
            availableWidth: availableWidth,
            speed: speed,
            motionPolicy: IslandMotionPolicy(
                reduceMotion: appReduceMotion,
                systemReduceMotion: systemReduceMotion,
                disableAnimations: disableAnimations
            ),
            isVisible: isVisible
        )
    }

    var body: some View {
        Group {
            if shouldAnimate {
                TimelineView(.animation) { context in
                    Text(text)
                        .font(font)
                        .fixedSize(horizontal: true, vertical: false)
                        .offset(x: Self.scrollOffset(
                            textWidth: textWidth,
                            availableWidth: availableWidth,
                            speed: speed,
                            elapsed: context.date.timeIntervalSince(startTime)
                        ))
                }
            } else {
                Text(text)
                    .font(font)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .frame(width: availableWidth, height: 14, alignment: .leading)
        .clipped()
        .background(
            Text(text)
                .font(font)
                .fixedSize(horizontal: true, vertical: false)
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(key: TextWidthKey.self, value: proxy.size.width)
                    }
                )
                .hidden()
                .accessibilityHidden(true)
        )
        .help(text)
        .accessibilityLabel(text)
        .onPreferenceChange(TextWidthKey.self) { width in
            textWidth = width
        }
        .onChange(of: text) { _, _ in
            startTime = .now
        }
        .onChange(of: shouldAnimate) { _, _ in
            startTime = .now
        }
        .onChange(of: availableWidth) { _, _ in
            startTime = .now
        }
        .onChange(of: speed) { _, _ in
            startTime = .now
        }
        .onAppear {
            startTime = .now
            isVisible = true
        }
        .onDisappear {
            isVisible = false
        }
    }

    static func shouldAnimate(
        textWidth: CGFloat,
        availableWidth: CGFloat,
        speed: CGFloat,
        motionPolicy: IslandMotionPolicy,
        isVisible: Bool
    ) -> Bool {
        isVisible && motionPolicy.allowsContinuousAnimation
            && textWidth.isFinite && availableWidth.isFinite && speed.isFinite
            && availableWidth > 0 && textWidth > availableWidth + 4 && speed > 0
    }

    static func scrollOffset(
        textWidth: CGFloat,
        availableWidth: CGFloat,
        speed: CGFloat,
        elapsed: TimeInterval
    ) -> CGFloat {
        guard textWidth.isFinite, availableWidth.isFinite, speed.isFinite, elapsed.isFinite,
              availableWidth > 0, textWidth > availableWidth + 4, speed > 0 else { return 0 }

        let totalDistance = textWidth - availableWidth + 16
        let scrollDuration = Double(totalDistance) / speed
        let pauseDuration: Double = 1.2
        let totalCycle = scrollDuration + pauseDuration

        let adjustedElapsed = max(0, elapsed - 0.3)
        let cyclePosition = adjustedElapsed.truncatingRemainder(dividingBy: totalCycle)

        if cyclePosition < pauseDuration {
            return 0
        }

        let progress = (cyclePosition - pauseDuration) / scrollDuration
        return -totalDistance * min(progress, 1.0)
    }
}

private struct TextWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
