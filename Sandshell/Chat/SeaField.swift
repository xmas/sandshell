import SwiftUI

/// The empty chat's sea: a quiet field of sea creatures in black and white.
/// Click it and the ones near the click take on color and swim round it in a
/// bubble for a moment, then drift home and fade back to gray. Nothing moves
/// until then; under Reduce Motion they only color in.
struct SeaField: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    /// Self-tests: start with a click here (then nothing else moves on its own).
    var initialSplash: CGPoint?

    private struct Splash { let point: CGPoint; let start: Date }
    @State private var splashes: [Splash] = []

    private static let size = CGSize(width: 400, height: 168)
    private static let swim: Double = 1.2      // seconds in the bubble
    private static let settle: Double = 0.7    // back home and fading to gray
    private static let reach: Double = 74      // how far a click reaches

    /// Where each creature rests, scattered over a loose grid.
    private struct Creature { let glyph: String; let home: CGPoint; let size: Double; let seed: Double }
    private static let creatures: [Creature] = {
        let glyphs = ["🐳", "🐬", "🐟", "🦀", "🐙", "🐠", "🦈", "🪼", "🐚", "🦑", "🐡", "🦞",
                      "🐋", "🐢", "🦐", "🪸", "🦭", "🐟", "🐬", "🐠"]
        var rng = SplitMix(seed: 7)
        var out: [Creature] = []
        let cols = 11, rows = 5
        let cell = CGSize(width: size.width / Double(cols), height: size.height / Double(rows))
        for row in 0..<rows {
            for col in 0..<cols where rng.next() < 0.8 {
                let x = (Double(col) + 0.5 + (row % 2 == 0 ? 0 : 0.5)) * cell.width + (rng.next() - 0.5) * cell.width * 0.5
                let y = (Double(row) + 0.5) * cell.height + (rng.next() - 0.5) * cell.height * 0.4
                guard x < size.width - 10 else { continue }
                out.append(Creature(glyph: glyphs[out.count % glyphs.count], home: CGPoint(x: x, y: y),
                                    size: 15 + rng.next() * 7, seed: rng.next()))
            }
        }
        return out
    }()

    private var animating: Bool { !splashes.isEmpty }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 60, paused: !animating)) { timeline in
            Canvas { context, _ in draw(in: context, now: timeline.date) }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .contentShape(Rectangle())
        .onTapGesture(coordinateSpace: .local) { splash(at: $0) }
        .onAppear { if let p = initialSplash { splash(at: p) } }
        .accessibilityLabel("Sea creatures")
        .accessibilityHint("Click to stir them up")
    }

    private func splash(at point: CGPoint) {
        let s = Splash(point: point, start: Date())
        splashes.append(s)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.swim + Self.settle + 0.05) {
            splashes.removeAll { $0.start == s.start }
        }
    }

    private func draw(in context: GraphicsContext, now: Date) {
        let dark = colorScheme == .dark
        // Bubbles first, under the creatures swimming in them.
        for s in splashes {
            let age = now.timeIntervalSince(s.start)
            guard age < Self.swim + 0.25 else { continue }
            let grow = min(1, age / 0.25), pop = max(0, (age - Self.swim) / 0.25)
            let r = Self.reach * (0.55 + 0.45 * Self.easeOut(grow)) * (1 + 0.15 * pop)
            let bubble = Path(ellipseIn: CGRect(x: s.point.x - r, y: s.point.y - r, width: 2 * r, height: 2 * r))
            let tint = Color(red: 0.35, green: 0.62, blue: 0.95)
            context.fill(bubble, with: .radialGradient(
                Gradient(colors: [tint.opacity(0.04 * (1 - pop)), tint.opacity(0.16 * (1 - pop))]),
                center: s.point, startRadius: 0, endRadius: r))
            context.stroke(bubble, with: .color(tint.opacity(0.45 * (1 - pop))), lineWidth: 1.2)
            // A glint, as on a soap bubble.
            let glint = Path(ellipseIn: CGRect(x: s.point.x - r * 0.55, y: s.point.y - r * 0.7, width: r * 0.3, height: r * 0.16))
            context.fill(glint, with: .color(.white.opacity(0.5 * (1 - pop))))
        }

        for (i, c) in Self.creatures.enumerated() {
            var point = c.home
            var color = 0.0        // 0 = gray, 1 = full color
            var heading = -1.0     // emoji face left; -1 = as drawn, 1 = mirrored
            for s in splashes {
                let distance = hypot(c.home.x - s.point.x, c.home.y - s.point.y)
                guard distance < Self.reach else { continue }
                let age = now.timeIntervalSince(s.start)
                // Color in fast, hold, fade back out once home.
                let fade = age < Self.swim ? min(1, age / 0.15) : max(0, 1 - (age - Self.swim) / Self.settle)
                color = max(color, fade)
                guard !reduceMotion else { continue }
                // Into an orbit round the click, a lap or so, then home again.
                let orbit = Self.reach * (0.3 + 0.35 * c.seed)
                let start = atan2(c.home.y - s.point.y, c.home.x - s.point.x)
                let angle = start + age * (2.2 + c.seed) * (i % 2 == 0 ? 1 : -1)
                let target = CGPoint(x: s.point.x + cos(angle) * orbit, y: s.point.y + sin(angle) * orbit * 0.8)
                let into = Self.easeInOut(min(1, age / 0.35))
                let out = Self.easeInOut(max(0, min(1, (age - Self.swim) / Self.settle)))
                let mix = into * (1 - out)
                point = CGPoint(x: c.home.x + (target.x - c.home.x) * mix, y: c.home.y + (target.y - c.home.y) * mix)
                // Face the way it's swimming round.
                let vx = -sin(angle) * (i % 2 == 0 ? 1 : -1)
                if mix > 0.2 { heading = vx > 0 ? 1 : -1 }
            }
            var g = context
            g.translateBy(x: point.x, y: point.y)
            if heading > 0 { g.scaleBy(x: -1, y: 1) }
            if color < 1 {
                // Gray at rest; color mixed back in by drawing over it.
                var gray = g
                gray.addFilter(.grayscale(1))
                gray.opacity = (dark ? 0.42 : 0.32) * (1 - color)
                gray.draw(gray.resolve(Text(c.glyph).font(.system(size: c.size))), at: .zero)
            }
            if color > 0 {
                g.opacity = color
                g.draw(g.resolve(Text(c.glyph).font(.system(size: c.size * (1 + 0.15 * color)))), at: .zero)
            }
        }
    }

    private static func easeOut(_ t: Double) -> Double { 1 - pow(1 - t, 3) }
    private static func easeInOut(_ t: Double) -> Double { t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2 }
}

/// Small deterministic generator, so the field looks the same every time.
private struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> Double {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Double(z >> 11) / Double(1 << 53)
    }
}
