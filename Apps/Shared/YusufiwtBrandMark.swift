import SwiftUI

struct YusufiwtFlowShape: Shape {
    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let origin = CGPoint(x: rect.midX - side / 2, y: rect.midY - side / 2)
        func point(_ horizontal: CGFloat, _ vertical: CGFloat) -> CGPoint {
            CGPoint(x: origin.x + side * horizontal, y: origin.y + side * vertical)
        }

        var path = Path()
        path.move(to: point(0.27, 0.28))
        path.addCurve(
            to: point(0.5, 0.51),
            control1: point(0.27, 0.40),
            control2: point(0.40, 0.45)
        )
        path.move(to: point(0.73, 0.28))
        path.addCurve(
            to: point(0.5, 0.51),
            control1: point(0.73, 0.40),
            control2: point(0.60, 0.45)
        )
        path.move(to: point(0.5, 0.51))
        path.addLine(to: point(0.5, 0.77))
        return path
    }
}

struct YusufiwtBrandGlyph: View {
    let size: CGFloat
    var monochrome = false

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            let lineWidth = max(1.25, side * 0.09)
            let dotSize = max(2.4, side * 0.125)
            let tint = LinearGradient(
                colors: monochrome
                    ? [.primary, .primary]
                    : [Color(red: 0.21, green: 0.85, blue: 1), Color(red: 0.65, green: 0.42, blue: 1)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            ZStack {
                YusufiwtFlowShape()
                    .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
                terminal(color: monochrome ? .primary : Color(red: 0.21, green: 0.85, blue: 1), size: dotSize)
                    .position(x: side * 0.27, y: side * 0.28)
                terminal(color: monochrome ? .primary : Color(red: 0.65, green: 0.42, blue: 1), size: dotSize)
                    .position(x: side * 0.73, y: side * 0.28)
                terminal(color: monochrome ? .primary : Color(red: 0.45, green: 0.52, blue: 1), size: dotSize)
                    .position(x: side * 0.5, y: side * 0.77)
            }
            .frame(width: side, height: side)
            .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private func terminal(color: Color, size: CGFloat) -> some View {
        Circle().fill(color).frame(width: size, height: size)
    }
}

struct YusufiwtBrandMark: View {
    let size: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color(red: 0.06, green: 0.17, blue: 0.30), Color(red: 0.03, green: 0.08, blue: 0.15)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay {
                    RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                        .stroke(.white.opacity(0.10), lineWidth: max(0.5, size * 0.01))
                }
            YusufiwtBrandGlyph(size: size * 0.76)
        }
        .frame(width: size, height: size)
        .accessibilityLabel("yusufiwt")
    }
}
