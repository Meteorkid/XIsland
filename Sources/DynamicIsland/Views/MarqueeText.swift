import SwiftUI

struct MarqueeText: View {
    let text: String
    let font: Font
    let availableWidth: CGFloat
    var speed: CGFloat = 25

    @State private var textWidth: CGFloat = 0
    @State private var startTime: Date = .now

    private var needsScroll: Bool { textWidth > availableWidth + 4 }

    var body: some View {
        TimelineView(.animation) { context in
            let offset = calculateOffset(at: context.date)
            Text(text)
                .font(font)
                .fixedSize(horizontal: true, vertical: false)
                .offset(x: offset)
        }
        .frame(width: availableWidth, height: 14)
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
        )
        .onPreferenceChange(TextWidthKey.self) { width in
            textWidth = width
        }
        .onChange(of: text) { _, _ in
            startTime = .now
        }
        .onAppear {
            startTime = .now
        }
    }

    private func calculateOffset(at date: Date) -> CGFloat {
        guard needsScroll, speed > 0 else { return 0 }

        let totalDistance = textWidth - availableWidth + 16
        let scrollDuration = Double(totalDistance) / speed
        let pauseDuration: Double = 1.2
        let totalCycle = scrollDuration + pauseDuration

        let elapsed = date.timeIntervalSince(startTime)
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
