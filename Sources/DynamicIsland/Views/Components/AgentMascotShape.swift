import SwiftUI

/// 以 0...1 坐标绘制的角色外轮廓，不携带客户端颜色或运行状态。
struct AgentMascotShape: Shape {
    let family: AgentMascotFamily

    func path(in rect: CGRect) -> Path {
        if family == .robot {
            return RoundedRectangle(cornerRadius: min(rect.width, rect.height) * 0.3,
                                    style: .continuous).path(in: rect)
        }
        return normalizedPath.applying(CGAffineTransform(
            a: rect.width, b: 0, c: 0, d: rect.height, tx: rect.minX, ty: rect.minY
        ))
    }

    private var normalizedPath: Path {
        var path = Path()
        switch family {
        case .robot:
            path.addRoundedRect(in: CGRect(x: 0, y: 0, width: 1, height: 1),
                                cornerSize: CGSize(width: 0.3, height: 0.3))
        case .crab:
            polygon(&path, [(0.04, 0.24), (0.17, 0.34), (0.19, 0.18), (0.29, 0.30),
                            (0.25, 0.44), (0.34, 0.34), (0.66, 0.34), (0.75, 0.44),
                            (0.71, 0.30), (0.81, 0.18), (0.83, 0.34), (0.96, 0.24),
                            (0.96, 0.51), (0.80, 0.57), (0.77, 0.72), (0.88, 0.83),
                            (0.72, 0.81), (0.63, 0.89), (0.60, 0.78), (0.40, 0.78),
                            (0.37, 0.89), (0.28, 0.81), (0.12, 0.83), (0.23, 0.72),
                            (0.20, 0.57), (0.04, 0.51)])
        case .star:
            polygon(&path, [(0.50, 0.02), (0.66, 0.32), (0.98, 0.50), (0.66, 0.68),
                            (0.50, 0.98), (0.34, 0.68), (0.02, 0.50), (0.34, 0.32)])
        case .pointer:
            polygon(&path, [(0.16, 0.04), (0.88, 0.58), (0.61, 0.63), (0.77, 0.90),
                            (0.57, 0.98), (0.42, 0.70), (0.16, 0.88)])
        case .sprout:
            path.move(to: CGPoint(x: 0.47, y: 0.40))
            curve(&path, to: (0.08, 0.12), c1: (0.17, 0.42), c2: (0.04, 0.30))
            curve(&path, to: (0.50, 0.31), c1: (0.30, 0.08), c2: (0.42, 0.13))
            curve(&path, to: (0.92, 0.08), c1: (0.59, 0.13), c2: (0.75, 0.06))
            curve(&path, to: (0.58, 0.42), c1: (0.97, 0.30), c2: (0.80, 0.42))
            curve(&path, to: (0.86, 0.68), c1: (0.74, 0.41), c2: (0.87, 0.52))
            curve(&path, to: (0.50, 0.96), c1: (0.87, 0.88), c2: (0.72, 0.96))
            curve(&path, to: (0.14, 0.68), c1: (0.28, 0.96), c2: (0.13, 0.88))
            curve(&path, to: (0.47, 0.40), c1: (0.13, 0.51), c2: (0.28, 0.40))
            path.closeSubpath()
        case .book:
            path.move(to: CGPoint(x: 0.05, y: 0.18))
            curve(&path, to: (0.50, 0.30), c1: (0.23, 0.12), c2: (0.39, 0.17))
            curve(&path, to: (0.95, 0.18), c1: (0.61, 0.17), c2: (0.77, 0.12))
            line(&path, to: (0.95, 0.83))
            curve(&path, to: (0.50, 0.94), c1: (0.76, 0.78), c2: (0.62, 0.81))
            curve(&path, to: (0.05, 0.83), c1: (0.38, 0.81), c2: (0.24, 0.78))
            path.closeSubpath()
        case .gear:
            let radii: [CGFloat] = [0.48, 0.48, 0.38, 0.38]
            let points = (0..<32).map { index -> (CGFloat, CGFloat) in
                let angle = CGFloat(index) * .pi / 16 - .pi / 2
                let radius = radii[index % radii.count]
                return (0.5 + cos(angle) * radius, 0.5 + sin(angle) * radius)
            }
            polygon(&path, points)
        case .magnifier:
            path.move(to: CGPoint(x: 0.69, y: 0.58))
            line(&path, to: (0.96, 0.83))
            curve(&path, to: (0.83, 0.96), c1: (1, 0.90), c2: (0.90, 1))
            line(&path, to: (0.58, 0.69))
            curve(&path, to: (0.05, 0.39), c1: (0.34, 0.83), c2: (0.04, 0.67))
            curve(&path, to: (0.39, 0.05), c1: (0.04, 0.18), c2: (0.18, 0.04))
            curve(&path, to: (0.69, 0.58), c1: (0.67, 0.04), c2: (0.83, 0.34))
            path.closeSubpath()
        case .goggles:
            polygon(&path, [(0.02, 0.32), (0.18, 0.36), (0.25, 0.24), (0.42, 0.24),
                            (0.50, 0.34), (0.58, 0.24), (0.75, 0.24), (0.82, 0.36),
                            (0.98, 0.32), (0.92, 0.57), (0.80, 0.60), (0.74, 0.78),
                            (0.57, 0.78), (0.50, 0.71), (0.43, 0.78), (0.26, 0.78),
                            (0.20, 0.60), (0.08, 0.57)])
        case .bear:
            path.move(to: CGPoint(x: 0.17, y: 0.38))
            curve(&path, to: (0.36, 0.22), c1: (-0.02, 0.08), c2: (0.30, -0.02))
            curve(&path, to: (0.64, 0.22), c1: (0.45, 0.18), c2: (0.55, 0.18))
            curve(&path, to: (0.83, 0.38), c1: (0.70, -0.02), c2: (1.02, 0.08))
            curve(&path, to: (0.50, 0.94), c1: (1.03, 0.75), c2: (0.78, 0.94))
            curve(&path, to: (0.17, 0.38), c1: (0.22, 0.94), c2: (-0.03, 0.75))
            path.closeSubpath()
        case .briefcase:
            polygon(&path, [(0.08, 0.29), (0.31, 0.29), (0.31, 0.10), (0.69, 0.10),
                            (0.69, 0.29), (0.92, 0.29), (0.92, 0.87), (0.78, 0.94),
                            (0.22, 0.94), (0.08, 0.87)])
        case .cloud:
            path.move(to: CGPoint(x: 0.22, y: 0.86))
            curve(&path, to: (0.20, 0.38), c1: (-0.04, 0.84), c2: (-0.02, 0.44))
            curve(&path, to: (0.66, 0.23), c1: (0.20, 0.06), c2: (0.55, 0.02))
            curve(&path, to: (0.85, 0.41), c1: (0.86, 0.14), c2: (0.97, 0.28))
            curve(&path, to: (0.78, 0.86), c1: (1.10, 0.53), c2: (1.00, 0.87))
            path.closeSubpath()
        case .crescent:
            path.move(to: CGPoint(x: 0.78, y: 0.06))
            curve(&path, to: (0.78, 0.94), c1: (-0.19, -0.13), c2: (-0.19, 1.13))
            curve(&path, to: (0.78, 0.06), c1: (0.38, 0.80), c2: (0.38, 0.20))
            path.closeSubpath()
        case .whale:
            path.move(to: CGPoint(x: 0.73, y: 0.50))
            line(&path, to: (0.81, 0.27))
            line(&path, to: (0.89, 0.42))
            line(&path, to: (0.98, 0.25))
            curve(&path, to: (0.87, 0.75), c1: (1.03, 0.52), c2: (0.99, 0.69))
            curve(&path, to: (0.13, 0.84), c1: (0.68, 0.94), c2: (0.29, 1.00))
            curve(&path, to: (0.25, 0.28), c1: (-0.07, 0.67), c2: (0.04, 0.28))
            curve(&path, to: (0.73, 0.50), c1: (0.49, 0.18), c2: (0.65, 0.28))
            path.closeSubpath()
        case .ghost:
            path.move(to: CGPoint(x: 0.13, y: 0.94))
            line(&path, to: (0.13, 0.43))
            curve(&path, to: (0.87, 0.43), c1: (0.13, -0.07), c2: (0.87, -0.07))
            line(&path, to: (0.87, 0.94))
            line(&path, to: (0.69, 0.81))
            line(&path, to: (0.50, 0.96))
            line(&path, to: (0.31, 0.81))
            path.closeSubpath()
        case .bolt:
            polygon(&path, [(0.57, 0.03), (0.14, 0.56), (0.42, 0.56),
                            (0.32, 0.96), (0.88, 0.39), (0.59, 0.39), (0.70, 0.03)])
        case .pi:
            polygon(&path, [(0.06, 0.16), (0.94, 0.16), (0.94, 0.34), (0.82, 0.34),
                            (0.82, 0.92), (0.61, 0.92), (0.61, 0.61), (0.39, 0.61),
                            (0.35, 0.92), (0.12, 0.92), (0.20, 0.34), (0.06, 0.34)])
        case .wingedEnvelope:
            polygon(&path, [(0.04, 0.16), (0.27, 0.34), (0.50, 0.23), (0.73, 0.34),
                            (0.96, 0.16), (0.92, 0.51), (0.78, 0.65), (0.78, 0.83),
                            (0.22, 0.83), (0.22, 0.65), (0.08, 0.51)])
        case .crystal:
            polygon(&path, [(0.50, 0.02), (0.81, 0.20), (0.94, 0.59), (0.73, 0.91),
                            (0.27, 0.91), (0.06, 0.59), (0.19, 0.20)])
        case .glove:
            path.move(to: CGPoint(x: 0.23, y: 0.53))
            curve(&path, to: (0.06, 0.38), c1: (0.13, 0.34), c2: (0.05, 0.24))
            curve(&path, to: (0.23, 0.79), c1: (0.01, 0.55), c2: (0.13, 0.70))
            line(&path, to: (0.28, 0.96))
            line(&path, to: (0.77, 0.96))
            curve(&path, to: (0.85, 0.36), c1: (0.81, 0.74), c2: (0.89, 0.62))
            curve(&path, to: (0.69, 0.24), c1: (0.84, 0.22), c2: (0.76, 0.19))
            curve(&path, to: (0.48, 0.14), c1: (0.65, 0.05), c2: (0.52, 0.03))
            curve(&path, to: (0.27, 0.22), c1: (0.40, 0.01), c2: (0.26, 0.08))
            path.closeSubpath()
        case .wave:
            path.move(to: CGPoint(x: 0.05, y: 0.88))
            curve(&path, to: (0.85, 0.10), c1: (0.08, 0.24), c2: (0.45, -0.06))
            curve(&path, to: (0.65, 0.54), c1: (0.58, 0.10), c2: (0.48, 0.40))
            curve(&path, to: (0.96, 0.65), c1: (0.77, 0.65), c2: (0.85, 0.58))
            curve(&path, to: (0.82, 0.92), c1: (0.94, 0.81), c2: (0.92, 0.89))
            path.closeSubpath()
        case .helmet:
            path.move(to: CGPoint(x: 0.15, y: 0.47))
            curve(&path, to: (0.85, 0.47), c1: (0.15, -0.01), c2: (0.85, -0.01))
            line(&path, to: (0.97, 0.47))
            line(&path, to: (0.97, 0.64))
            line(&path, to: (0.81, 0.64))
            curve(&path, to: (0.19, 0.64), c1: (0.80, 1.06), c2: (0.20, 1.06))
            line(&path, to: (0.03, 0.64))
            line(&path, to: (0.03, 0.47))
            path.closeSubpath()
        case .bubble:
            path.move(to: CGPoint(x: 0.24, y: 0.10))
            curve(&path, to: (0.93, 0.32), c1: (0.70, 0.04), c2: (0.93, 0.10))
            curve(&path, to: (0.76, 0.80), c1: (1.01, 0.66), c2: (0.94, 0.80))
            line(&path, to: (0.40, 0.80))
            line(&path, to: (0.13, 0.97))
            line(&path, to: (0.20, 0.77))
            curve(&path, to: (0.24, 0.10), c1: (-0.03, 0.71), c2: (-0.03, 0.17))
            path.closeSubpath()
        case .cat:
            path.move(to: CGPoint(x: 0.11, y: 0.07))
            line(&path, to: (0.38, 0.27))
            line(&path, to: (0.62, 0.27))
            line(&path, to: (0.89, 0.07))
            line(&path, to: (0.89, 0.65))
            curve(&path, to: (0.11, 0.65), c1: (0.89, 1.03), c2: (0.11, 1.03))
            path.closeSubpath()
        case .dog:
            path.move(to: CGPoint(x: 0.32, y: 0.19))
            curve(&path, to: (0.05, 0.79), c1: (0.09, 0.04), c2: (-0.04, 0.53))
            curve(&path, to: (0.25, 0.69), c1: (0.09, 0.95), c2: (0.20, 0.89))
            curve(&path, to: (0.75, 0.69), c1: (0.26, 0.98), c2: (0.74, 0.98))
            curve(&path, to: (0.95, 0.79), c1: (0.80, 0.89), c2: (0.91, 0.95))
            curve(&path, to: (0.68, 0.19), c1: (1.04, 0.53), c2: (0.91, 0.04))
            curve(&path, to: (0.32, 0.19), c1: (0.58, 0.10), c2: (0.42, 0.10))
            path.closeSubpath()
        case .tent:
            polygon(&path, [(0.50, 0.04), (0.98, 0.93), (0.63, 0.93),
                            (0.50, 0.80), (0.37, 0.93), (0.02, 0.93)])
        case .chevron:
            polygon(&path, [(0.05, 0.12), (0.53, 0.12), (0.97, 0.50),
                            (0.53, 0.88), (0.05, 0.88), (0.29, 0.50)])
        case .paperPlane:
            polygon(&path, [(0.50, 0.02), (0.98, 0.88), (0.66, 0.76),
                            (0.50, 0.98), (0.34, 0.76), (0.02, 0.88)])
        case .kangaroo:
            path.move(to: CGPoint(x: 0.28, y: 0.40))
            curve(&path, to: (0.41, 0.37), c1: (0.06, -0.10), c2: (0.38, -0.12))
            line(&path, to: (0.59, 0.37))
            curve(&path, to: (0.72, 0.40), c1: (0.62, -0.12), c2: (0.94, -0.10))
            curve(&path, to: (0.50, 0.96), c1: (0.99, 0.52), c2: (0.75, 0.88))
            curve(&path, to: (0.28, 0.40), c1: (0.25, 0.88), c2: (0.01, 0.52))
            path.closeSubpath()
        case .pear:
            path.move(to: CGPoint(x: 0.45, y: 0.27))
            curve(&path, to: (0.76, 0.05), c1: (0.45, 0.03), c2: (0.61, 0.01))
            curve(&path, to: (0.58, 0.28), c1: (0.78, 0.20), c2: (0.71, 0.28))
            curve(&path, to: (0.85, 0.66), c1: (0.70, 0.32), c2: (0.66, 0.43))
            curve(&path, to: (0.50, 0.96), c1: (1.02, 0.91), c2: (0.73, 0.97))
            curve(&path, to: (0.15, 0.66), c1: (0.27, 0.97), c2: (-0.02, 0.91))
            curve(&path, to: (0.45, 0.27), c1: (0.34, 0.43), c2: (0.32, 0.32))
            path.closeSubpath()
        case .zebra:
            polygon(&path, [(0.22, 0.35), (0.14, 0.08), (0.34, 0.17), (0.42, 0.08),
                            (0.58, 0.08), (0.66, 0.17), (0.86, 0.08), (0.78, 0.35),
                            (0.84, 0.79), (0.69, 0.95), (0.31, 0.95), (0.16, 0.79)])
        case .octopus:
            path.move(to: CGPoint(x: 0.18, y: 0.61))
            curve(&path, to: (0.82, 0.61), c1: (-0.11, -0.10), c2: (1.11, -0.10))
            curve(&path, to: (0.82, 0.93), c1: (0.98, 0.79), c2: (1.02, 0.96))
            line(&path, to: (0.69, 0.76))
            curve(&path, to: (0.50, 0.79), c1: (0.71, 1.04), c2: (0.51, 1.04))
            curve(&path, to: (0.31, 0.76), c1: (0.49, 1.04), c2: (0.29, 1.04))
            line(&path, to: (0.18, 0.93))
            curve(&path, to: (0.18, 0.61), c1: (-0.02, 0.96), c2: (0.02, 0.79))
            path.closeSubpath()
        case .unknown:
            polygon(&path, [(0.28, 0.05), (0.72, 0.05), (0.95, 0.28), (0.95, 0.72),
                            (0.72, 0.95), (0.28, 0.95), (0.05, 0.72), (0.05, 0.28)])
        }
        return path
    }

    private func polygon(_ path: inout Path, _ points: [(CGFloat, CGFloat)]) {
        guard let first = points.first else { return }
        path.move(to: CGPoint(x: first.0, y: first.1))
        for point in points.dropFirst() { line(&path, to: point) }
        path.closeSubpath()
    }

    private func line(_ path: inout Path, to point: (CGFloat, CGFloat)) {
        path.addLine(to: CGPoint(x: point.0, y: point.1))
    }

    private func curve(_ path: inout Path, to end: (CGFloat, CGFloat),
                       c1: (CGFloat, CGFloat), c2: (CGFloat, CGFloat)) {
        path.addCurve(to: CGPoint(x: end.0, y: end.1),
                      control1: CGPoint(x: c1.0, y: c1.1),
                      control2: CGPoint(x: c2.0, y: c2.1))
    }
}
