import SwiftUI

/// A little sea for the empty chat: waves rolling by, a pod of dolphins
/// swimming through and leaping out with a splash, a shell on the sand.
/// Drawn with Canvas on the animation timeline (no web view); holds still
/// under Reduce Motion.
struct DolphinPod: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    /// Hold still (the empty state is hidden behind a conversation).
    var paused = false

    /// One swimmer: how fast it crosses, how deep it cruises, how often it leaps.
    private struct Dolphin {
        var speed: Double        // points per second
        var start: Double        // where along its lap it begins (0…1)
        var depth: Double        // cruising depth below the waterline
        var leaps: Double        // leaps per crossing
        var size: Double
        var rightward: Bool
    }

    private static let pod: [Dolphin] = [
        Dolphin(speed: 46, start: 0.05, depth: 22, leaps: 2.0, size: 44, rightward: true),
        Dolphin(speed: 38, start: 0.18, depth: 30, leaps: 1.5, size: 36, rightward: true),
        Dolphin(speed: 31, start: 0.62, depth: 18, leaps: 2.5, size: 30, rightward: false),
    ]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion || paused)) { timeline in
            Canvas { context, size in
                draw(in: &context, size: size,
                     t: reduceMotion ? 7.3 : timeline.date.timeIntervalSinceReferenceDate)
            }
        }
        .frame(width: 340, height: 150)
        .accessibilityLabel("Dolphins swimming")
    }

    /// A dolphin about 50 points long, nose to the right, centered on the
    /// origin: round melon, short beak, a fin swept back, pale belly.
    private static let dolphin: Path = {
        var p = Path()
        p.move(to: CGPoint(x: 24, y: 2))                                                      // beak tip
        p.addQuadCurve(to: CGPoint(x: 16, y: -2), control: CGPoint(x: 20, y: 0))
        p.addQuadCurve(to: CGPoint(x: 6, y: -9), control: CGPoint(x: 15, y: -10))             // melon
        p.addQuadCurve(to: CGPoint(x: 0, y: -10), control: CGPoint(x: 3, y: -10.5))
        p.addQuadCurve(to: CGPoint(x: -8, y: -17), control: CGPoint(x: -3, y: -16))           // dorsal fin
        p.addQuadCurve(to: CGPoint(x: -6, y: -9), control: CGPoint(x: -7, y: -12))
        p.addQuadCurve(to: CGPoint(x: -18, y: -3), control: CGPoint(x: -13, y: -7))           // tail stock
        p.addQuadCurve(to: CGPoint(x: -27, y: -9), control: CGPoint(x: -22, y: -5))           // flukes
        p.addQuadCurve(to: CGPoint(x: -22, y: 0), control: CGPoint(x: -25, y: -3))
        p.addQuadCurve(to: CGPoint(x: -27, y: 9), control: CGPoint(x: -25, y: 3))
        p.addQuadCurve(to: CGPoint(x: -18, y: 3), control: CGPoint(x: -22, y: 5))
        p.addQuadCurve(to: CGPoint(x: 0, y: 8), control: CGPoint(x: -9, y: 9))                // belly
        p.addQuadCurve(to: CGPoint(x: -4, y: 14), control: CGPoint(x: -1, y: 12))             // flipper
        p.addQuadCurve(to: CGPoint(x: 5, y: 7), control: CGPoint(x: 2, y: 11))
        p.addQuadCurve(to: CGPoint(x: 16, y: 4), control: CGPoint(x: 11, y: 7))               // chin
        p.addQuadCurve(to: CGPoint(x: 24, y: 2), control: CGPoint(x: 21, y: 4))
        p.closeSubpath()
        return p
    }()

    private static func drawDolphin(in c: GraphicsContext, dark: Bool) {
        let back = dark ? Color(red: 0.5, green: 0.64, blue: 0.8) : Color(red: 0.36, green: 0.52, blue: 0.7)
        let belly = dark ? Color(red: 0.86, green: 0.91, blue: 0.96) : Color(red: 0.86, green: 0.92, blue: 0.97)
        c.fill(dolphin, with: .linearGradient(
            Gradient(stops: [.init(color: back, location: 0), .init(color: back, location: 0.55),
                             .init(color: belly, location: 0.72), .init(color: belly, location: 1)]),
            startPoint: CGPoint(x: 0, y: -12), endPoint: CGPoint(x: 0, y: 9)))
        // A big friendly eye with a glint, and a smile.
        c.fill(Path(ellipseIn: CGRect(x: 12.6, y: -4.4, width: 2.8, height: 2.8)), with: .color(.black.opacity(0.8)))
        c.fill(Path(ellipseIn: CGRect(x: 13.8, y: -4.0, width: 0.9, height: 0.9)), with: .color(.white))
        var smile = Path()
        smile.move(to: CGPoint(x: 15.5, y: 2.2))
        smile.addQuadCurve(to: CGPoint(x: 22, y: 2.0), control: CGPoint(x: 19, y: 3.6))
        c.stroke(smile, with: .color(.black.opacity(0.35)), lineWidth: 0.8)
    }

    private func draw(in context: inout GraphicsContext, size: CGSize, t: Double) {
        let w = size.width, waterline = size.height * 0.48
        let dark = colorScheme == .dark
        let sea = Color(red: 0.25, green: 0.55, blue: 0.85)

        func surface(_ x: Double) -> Double {
            waterline + 3 * sin(x / 28 + t * 1.3) + 2 * sin(x / 11 - t * 0.9)
        }

        // Dolphins first: the water drawn over them tints the ones below it.
        var splashes: [CGPoint] = []
        for (i, d) in Self.pod.enumerated() {
            func position(_ t: Double) -> CGPoint {
                let lap = w + 90
                var x = ((t * d.speed / lap + d.start).truncatingRemainder(dividingBy: 1)) * lap - 45
                if !d.rightward { x = w - x }
                let phase = (x / w) * 2 * .pi * d.leaps + Double(i) * 1.7
                // Cruise below the surface; part of each wave lifts it clear of the water.
                let lift = 34 + d.depth
                return CGPoint(x: x, y: waterline + d.depth - lift * max(0, sin(phase)) + 3 * sin(t * 2 + Double(i)))
            }
            let p = position(t), before = position(t - 0.08)
            // Nose along the direction of travel (the lap's wrap-around jump excepted).
            var heading = atan2(p.y - before.y, p.x - before.x)
            if abs(p.x - before.x) > 40 { heading = d.rightward ? 0 : .pi }
            if abs(p.y - surface(p.x)) < 3, p.y < before.y { splashes.append(CGPoint(x: p.x, y: surface(p.x))) }

            var c = context
            c.translateBy(x: p.x, y: p.y)
            c.rotate(by: .radians(heading))
            let scale = d.size / 50
            // Drawn heading right; one heading left is turned around, so flip it belly-down.
            c.scaleBy(x: scale, y: d.rightward ? scale : -scale)
            Self.drawDolphin(in: c, dark: dark)
        }

        // The sea: a band below a moving surface, then the surface line itself.
        var water = Path()
        water.move(to: CGPoint(x: 0, y: surface(0)))
        for x in stride(from: 0.0, through: w, by: 4) { water.addLine(to: CGPoint(x: x, y: surface(x))) }
        water.addLine(to: CGPoint(x: w, y: size.height))
        water.addLine(to: CGPoint(x: 0, y: size.height))
        water.closeSubpath()
        context.fill(water, with: .linearGradient(
            Gradient(colors: [sea.opacity(dark ? 0.55 : 0.45), sea.opacity(dark ? 0.25 : 0.12)]),
            startPoint: CGPoint(x: 0, y: waterline), endPoint: CGPoint(x: 0, y: size.height)))
        var line = Path()
        line.move(to: CGPoint(x: 0, y: surface(0)))
        for x in stride(from: 0.0, through: w, by: 4) { line.addLine(to: CGPoint(x: x, y: surface(x))) }
        context.stroke(line, with: .color(sea.opacity(0.7)), lineWidth: 1.5)

        // Splashes where a dolphin breaks the surface.
        for p in splashes {
            for k in 0..<4 {
                let a = Double(k) / 3 * .pi + .pi
                let r = 2.0 + Double(k % 2)
                let drop = CGRect(x: p.x + cos(a) * 9 - r / 2, y: p.y + sin(a) * 7 - r / 2, width: r, height: r)
                context.fill(Path(ellipseIn: drop), with: .color(.white.opacity(dark ? 0.7 : 0.9)))
                context.stroke(Path(ellipseIn: drop), with: .color(sea.opacity(0.6)), lineWidth: 0.5)
            }
        }

        // A strip of sand, and a shell on it.
        var sand = Path()
        sand.move(to: CGPoint(x: 0, y: size.height - 10))
        for x in stride(from: 0.0, through: w, by: 6) {
            sand.addLine(to: CGPoint(x: x, y: size.height - 10 + 2 * sin(x / 37)))
        }
        sand.addLine(to: CGPoint(x: w, y: size.height))
        sand.addLine(to: CGPoint(x: 0, y: size.height))
        sand.closeSubpath()
        context.fill(sand, with: .color(Color(red: 0.93, green: 0.84, blue: 0.64).opacity(dark ? 0.55 : 0.9)))
        context.draw(context.resolve(Text("🐚").font(.system(size: 15))), at: CGPoint(x: w * 0.78, y: size.height - 11))
    }
}
