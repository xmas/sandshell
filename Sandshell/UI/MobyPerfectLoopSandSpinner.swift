import SwiftUI

/// A compact, cartoon whale loading spinner for macOS.
/// The whale stays in front of a small sand wake that fades to transparent at the sides.
/// Designed to remain legible at 30x30 pt and to loop seamlessly.
///
/// Usage:
///     MobyPerfectLoopSandSpinner(size: 30)
public struct MobyPerfectLoopSandSpinner: View {
    public var size: CGFloat
    public var whaleBlue: Color
    public var whaleDeepBlue: Color
    public var bellyBlue: Color
    public var sandGold: Color
    public var splashGold: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        size: CGFloat = 30,
        whaleBlue: Color = Color(red: 0.00, green: 0.45, blue: 1.0),
        whaleDeepBlue: Color = Color(red: 0.00, green: 0.24, blue: 0.92),
        bellyBlue: Color = Color(red: 0.88, green: 0.97, blue: 1.0),
        sandGold: Color = Color(red: 1.0, green: 0.67, blue: 0.04),
        splashGold: Color = Color(red: 1.0, green: 0.84, blue: 0.16)
    ) {
        self.size = size
        self.whaleBlue = whaleBlue
        self.whaleDeepBlue = whaleDeepBlue
        self.bellyBlue = bellyBlue
        self.sandGold = sandGold
        self.splashGold = splashGold
    }

    public var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { timeline in
            let period: TimeInterval = 2.2
            let t = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
            let phase = CGFloat((t.truncatingRemainder(dividingBy: period)) / period)
            let theta = phase * .pi * 2.0
            let roll = sin(theta)
            let bob = cos(theta)
            let tail = sin(theta + .pi / 3.0)

            ZStack {
                sandWake(phase: phase)
                    .frame(width: size, height: size)
                    .offset(y: size * 0.29)

                sandParticles(phase: phase)
                    .frame(width: size, height: size)

                whale(roll: reduceMotion ? 0 : roll, tail: reduceMotion ? 0 : tail)
                    .frame(width: size * 1.03, height: size * 0.76)
                    .offset(
                        x: reduceMotion ? 0 : roll * size * 0.025,
                        y: reduceMotion ? -size * 0.040 : -size * 0.065 + bob * size * 0.018
                    )
                    .rotationEffect(.degrees(reduceMotion ? 0 : Double(roll) * 6.0), anchor: .center)
                    .animation(nil, value: phase)
            }
            .frame(width: size, height: size)
            .accessibilityLabel(Text("Loading"))
        }
    }

    private func sandWake(phase: CGFloat) -> some View {
        ZStack {
            Capsule()
                .fill(
                    LinearGradient(
                        stops: [
                            .init(color: sandGold.opacity(0.0), location: 0.00),
                            .init(color: sandGold.opacity(0.34), location: 0.22),
                            .init(color: sandGold.opacity(0.50), location: 0.50),
                            .init(color: sandGold.opacity(0.34), location: 0.78),
                            .init(color: sandGold.opacity(0.0), location: 1.00)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(width: size * 1.05, height: size * 0.16)

            SandRibbon(phase: phase)
                .fill(
                    LinearGradient(
                        stops: [
                            .init(color: splashGold.opacity(0.0), location: 0.00),
                            .init(color: splashGold.opacity(0.72), location: 0.28),
                            .init(color: splashGold.opacity(0.88), location: 0.52),
                            .init(color: splashGold.opacity(0.72), location: 0.76),
                            .init(color: splashGold.opacity(0.0), location: 1.00)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(width: size * 1.12, height: size * 0.19)
                .offset(y: -size * 0.015)
        }
        .allowsHitTesting(false)
    }

    private func sandParticles(phase: CGFloat) -> some View {
        ZStack {
            particle(x: 0.18, y: 0.74, r: 0.030, delay: 0.00, phase: phase)
            particle(x: 0.80, y: 0.75, r: 0.026, delay: 0.50, phase: phase)
        }
    }

    private func particle(x: CGFloat, y: CGFloat, r: CGFloat, delay: CGFloat, phase: CGFloat) -> some View {
        let local = (phase + delay).truncatingRemainder(dividingBy: 1)
        let theta = local * .pi * 2.0
        let lift = max(0, sin(theta)) * size * 0.050
        let fade = Double(max(0.0, sin(theta))) * 0.62

        return Circle()
            .fill(splashGold.opacity(fade))
            .frame(width: size * r, height: size * r)
            .position(x: size * x, y: size * y - lift)
    }

    private func whale(roll: CGFloat, tail: CGFloat) -> some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let line = max(1.0, w * 0.034)

            ZStack {
                // Soft contact shadow. It is behind the whale but above the fading sand.
                Capsule()
                    .fill(Color.black.opacity(0.13))
                    .frame(width: w * 0.62, height: h * 0.14)
                    .offset(x: -w * 0.04, y: h * 0.32)
                    .blur(radius: w * 0.022)

                HappyTail()
                    .fill(whaleBlue)
                    .overlay(HappyTail().stroke(Color.white.opacity(0.24), lineWidth: line))
                    .frame(width: w * 0.35, height: h * 0.42)
                    .offset(x: w * 0.35, y: -h * 0.02)
                    .rotationEffect(.degrees(Double(-8 + tail * 5.0)), anchor: .leading)

                HappyWhaleBody()
                    .fill(whaleBlue)
                    .overlay(HappyWhaleBody().stroke(Color.white.opacity(0.24), lineWidth: line))
                    .shadow(color: Color.black.opacity(0.12), radius: w * 0.03, y: h * 0.025)

                HappyWhaleBelly()
                    .fill(bellyBlue)
                    .overlay(HappyWhaleBelly().stroke(Color.white.opacity(0.55), lineWidth: line * 0.65))

                HappyFin()
                    .fill(whaleDeepBlue.opacity(0.96))
                    .overlay(HappyFin().stroke(Color.white.opacity(0.18), lineWidth: line * 0.6))
                    .frame(width: w * 0.26, height: h * 0.38)
                    .offset(x: w * 0.12, y: h * 0.18)
                    .rotationEffect(.degrees(Double(6 + roll * 4.0)))

                Circle()
                    .fill(Color.black.opacity(0.90))
                    .frame(width: w * 0.088, height: w * 0.088)
                    .overlay(
                        Circle()
                            .fill(Color.white)
                            .frame(width: w * 0.034, height: w * 0.034)
                            .offset(x: -w * 0.014, y: -w * 0.014)
                    )
                    .offset(x: -w * 0.09, y: -h * 0.03)

                SmileShape()
                    .stroke(Color.black.opacity(0.74), style: StrokeStyle(lineWidth: line * 1.25, lineCap: .round))
                    .frame(width: w * 0.22, height: h * 0.18)
                    .offset(x: -w * 0.06, y: h * 0.14)

                Circle()
                    .fill(Color(red: 1.0, green: 0.45, blue: 0.46).opacity(0.44))
                    .frame(width: w * 0.07, height: w * 0.045)
                    .offset(x: -w * 0.20, y: h * 0.13)
            }
        }
    }
}

private struct HappyWhaleBody: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        let w = r.width, h = r.height
        p.move(to: CGPoint(x: 0.04*w, y: 0.58*h))
        p.addCurve(to: CGPoint(x: 0.20*w, y: 0.20*h), control1: CGPoint(x: 0.03*w, y: 0.38*h), control2: CGPoint(x: 0.10*w, y: 0.24*h))
        p.addCurve(to: CGPoint(x: 0.58*w, y: 0.22*h), control1: CGPoint(x: 0.35*w, y: 0.10*h), control2: CGPoint(x: 0.50*w, y: 0.15*h))
        p.addCurve(to: CGPoint(x: 0.82*w, y: 0.54*h), control1: CGPoint(x: 0.70*w, y: 0.30*h), control2: CGPoint(x: 0.73*w, y: 0.48*h))
        p.addCurve(to: CGPoint(x: 0.92*w, y: 0.48*h), control1: CGPoint(x: 0.87*w, y: 0.58*h), control2: CGPoint(x: 0.90*w, y: 0.53*h))
        p.addCurve(to: CGPoint(x: 0.84*w, y: 0.76*h), control1: CGPoint(x: 0.94*w, y: 0.62*h), control2: CGPoint(x: 0.93*w, y: 0.73*h))
        p.addCurve(to: CGPoint(x: 0.25*w, y: 0.84*h), control1: CGPoint(x: 0.63*w, y: 0.91*h), control2: CGPoint(x: 0.38*w, y: 0.92*h))
        p.addCurve(to: CGPoint(x: 0.04*w, y: 0.58*h), control1: CGPoint(x: 0.12*w, y: 0.79*h), control2: CGPoint(x: 0.05*w, y: 0.69*h))
        p.closeSubpath()
        return p
    }
}

private struct HappyWhaleBelly: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        let w = r.width, h = r.height
        p.move(to: CGPoint(x: 0.06*w, y: 0.57*h))
        p.addCurve(to: CGPoint(x: 0.28*w, y: 0.52*h), control1: CGPoint(x: 0.12*w, y: 0.50*h), control2: CGPoint(x: 0.20*w, y: 0.49*h))
        p.addCurve(to: CGPoint(x: 0.55*w, y: 0.79*h), control1: CGPoint(x: 0.41*w, y: 0.57*h), control2: CGPoint(x: 0.43*w, y: 0.76*h))
        p.addCurve(to: CGPoint(x: 0.32*w, y: 0.87*h), control1: CGPoint(x: 0.47*w, y: 0.90*h), control2: CGPoint(x: 0.38*w, y: 0.90*h))
        p.addCurve(to: CGPoint(x: 0.06*w, y: 0.57*h), control1: CGPoint(x: 0.16*w, y: 0.81*h), control2: CGPoint(x: 0.07*w, y: 0.70*h))
        p.closeSubpath()
        return p
    }
}

private struct HappyFin: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        let w = r.width, h = r.height
        p.move(to: CGPoint(x: 0.20*w, y: 0.10*h))
        p.addCurve(to: CGPoint(x: 0.86*w, y: 0.82*h), control1: CGPoint(x: 0.54*w, y: 0.15*h), control2: CGPoint(x: 0.78*w, y: 0.50*h))
        p.addCurve(to: CGPoint(x: 0.12*w, y: 0.58*h), control1: CGPoint(x: 0.55*w, y: 0.88*h), control2: CGPoint(x: 0.26*w, y: 0.78*h))
        p.addCurve(to: CGPoint(x: 0.20*w, y: 0.10*h), control1: CGPoint(x: 0.05*w, y: 0.34*h), control2: CGPoint(x: 0.08*w, y: 0.18*h))
        p.closeSubpath()
        return p
    }
}

private struct HappyTail: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        let w = r.width, h = r.height
        p.move(to: CGPoint(x: 0.04*w, y: 0.52*h))
        p.addCurve(to: CGPoint(x: 0.48*w, y: 0.30*h), control1: CGPoint(x: 0.16*w, y: 0.42*h), control2: CGPoint(x: 0.32*w, y: 0.36*h))
        p.addCurve(to: CGPoint(x: 0.88*w, y: 0.03*h), control1: CGPoint(x: 0.58*w, y: 0.10*h), control2: CGPoint(x: 0.74*w, y: 0.00*h))
        p.addCurve(to: CGPoint(x: 0.72*w, y: 0.48*h), control1: CGPoint(x: 0.98*w, y: 0.22*h), control2: CGPoint(x: 0.94*w, y: 0.40*h))
        p.addCurve(to: CGPoint(x: 0.92*w, y: 0.92*h), control1: CGPoint(x: 0.92*w, y: 0.58*h), control2: CGPoint(x: 1.00*w, y: 0.76*h))
        p.addCurve(to: CGPoint(x: 0.46*w, y: 0.72*h), control1: CGPoint(x: 0.72*w, y: 0.96*h), control2: CGPoint(x: 0.57*w, y: 0.86*h))
        p.addCurve(to: CGPoint(x: 0.04*w, y: 0.52*h), control1: CGPoint(x: 0.30*w, y: 0.67*h), control2: CGPoint(x: 0.16*w, y: 0.60*h))
        p.closeSubpath()
        return p
    }
}

private struct SmileShape: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX + r.width * 0.10, y: r.minY + r.height * 0.25))
        p.addCurve(
            to: CGPoint(x: r.minX + r.width * 0.90, y: r.minY + r.height * 0.25),
            control1: CGPoint(x: r.minX + r.width * 0.30, y: r.minY + r.height * 0.95),
            control2: CGPoint(x: r.minX + r.width * 0.70, y: r.minY + r.height * 0.95)
        )
        return p
    }
}

private struct SandRibbon: Shape {
    let phase: CGFloat

    func path(in r: CGRect) -> Path {
        var p = Path()
        let w = r.width, h = r.height
        let shift = phase * w

        p.move(to: CGPoint(x: 0, y: 0.52*h))
        for i in 0...24 {
            let x = CGFloat(i) / 24.0 * w
            let y = 0.48*h + sin(((x + shift) / w) * .pi * 4.0) * h * 0.13
            if i == 0 { p.move(to: CGPoint(x: x, y: y)) }
            else { p.addLine(to: CGPoint(x: x, y: y)) }
        }
        p.addLine(to: CGPoint(x: w, y: h))
        p.addLine(to: CGPoint(x: 0, y: h))
        p.closeSubpath()
        return p
    }
}
