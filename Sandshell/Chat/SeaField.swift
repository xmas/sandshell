import SwiftUI

/// The empty chat's sea: a quiet band of sea creatures in black and white.
/// Move the pointer over them and the ones it passes color in and give a quick
/// swish, while rings of water ripple out from under them and fade. Nothing
/// stays: a moment later they're gray and still again. The field fills its
/// whole frame so ripples never meet an edge; the creatures rest in `band`.
/// Under Reduce Motion they only color in.
struct SeaField: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    /// Where the creatures rest, in this view's coordinates (up to `size`).
    var band: CGRect
    /// Self-tests: start as if the pointer passed here, in band coordinates.
    var initialSplash: CGPoint?

    /// When each creature was last touched, and which way the pointer pushed it.
    private struct Touch { let start: Date; let push: CGVector }
    @State private var touches: [Int: Touch] = [:]
    /// Rings of water spreading from under touched creatures.
    private struct Ripple { let center: CGPoint; let start: Date; let size: Double }
    @State private var ripples: [Ripple] = []

    static let size = CGSize(width: 400, height: 168)
    private static let reach: Double = 46       // how near the pointer has to pass
    private static let swish: Double = 0.55     // seconds of wiggle
    private static let glow: Double = 1.4       // seconds of color, fading out at the end
    private static let rippleLife: Double = 1.1
    private static let cooldown: Double = 0.45  // before the same creature reacts again

    /// Where each creature rests, scattered over a loose grid (band coordinates).
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

    private var animating: Bool { !touches.isEmpty || !ripples.isEmpty }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 60, paused: !animating)) { timeline in
            Canvas { context, _ in draw(in: context, now: timeline.date) }
                .onChange(of: timeline.date) { _, now in prune(now) }
        }
        .contentShape(.rect)
        .onContinuousHover(coordinateSpace: .local) { phase in
            if case .active(let point) = phase { stir(at: point) }
        }
        .onAppear {
            if let p = initialSplash { stir(at: CGPoint(x: p.x + origin.x, y: p.y + origin.y)) }
        }
        .accessibilityHidden(true)
    }

    /// The creatures' 400-pt field, centred on the band: in a narrow pane the
    /// band is narrower and the outer creatures just run off the edges.
    private var origin: CGPoint { CGPoint(x: band.midX - Self.size.width / 2, y: band.minY) }

    private func home(_ i: Int) -> CGPoint {
        CGPoint(x: origin.x + Self.creatures[i].home.x, y: origin.y + Self.creatures[i].home.y)
    }

    /// The pointer passed `point`: creatures near it react (unless they just did).
    private func stir(at point: CGPoint) {
        let now = Date.now
        for i in Self.creatures.indices {
            let h = home(i)
            let dx = h.x - point.x, dy = h.y - point.y
            let d = hypot(dx, dy)
            guard d < Self.reach else { continue }
            if let t = touches[i], now.timeIntervalSince(t.start) < Self.cooldown { continue }
            let push = d > 0.5 ? CGVector(dx: dx / d, dy: dy / d) : CGVector(dx: 1, dy: 0)
            touches[i] = Touch(start: now, push: push)
            if !reduceMotion { ripples.append(Ripple(center: h, start: now, size: Self.creatures[i].size)) }
        }
    }

    /// Drop what's finished, so the timeline pauses once the water is still.
    private func prune(_ now: Date) {
        if touches.contains(where: { now.timeIntervalSince($0.value.start) > Self.glow }) {
            touches = touches.filter { now.timeIntervalSince($0.value.start) <= Self.glow }
        }
        if ripples.contains(where: { now.timeIntervalSince($0.start) > Self.rippleLife }) {
            ripples.removeAll { now.timeIntervalSince($0.start) > Self.rippleLife }
        }
    }

    private func draw(in context: GraphicsContext, now: Date) {
        let dark = colorScheme == .dark
        let water = Color(red: 0.35, green: 0.62, blue: 0.95)
        // Ripples under the creatures: two rings each, spreading and fading.
        for r in ripples {
            let t = now.timeIntervalSince(r.start) / Self.rippleLife
            guard t >= 0, t < 1 else { continue }
            for (k, lag) in [0.0, 0.22].enumerated() {
                let u = t - lag
                guard u > 0 else { continue }
                let radius = r.size * 0.45 + Self.easeOut(u) * r.size * 1.6
                let ring = Path(ellipseIn: CGRect(x: r.center.x - radius, y: r.center.y - radius * 0.45 + r.size * 0.35,
                                                  width: 2 * radius, height: radius * 0.9))
                let alpha = (1 - u) * (k == 0 ? 0.5 : 0.3)
                context.stroke(ring, with: .color(water.opacity(alpha)), lineWidth: 1.4 * (1 - u) + 0.3)
            }
        }

        for (i, c) in Self.creatures.enumerated() {
            var point = home(i)
            var color = 0.0       // 0 = gray, 1 = full color
            var tilt = 0.0
            if let touch = touches[i] {
                let age = now.timeIntervalSince(touch.start)
                // Color in at once, hold, then fade back to gray.
                color = age < Self.glow - 0.5 ? 1 : max(0, (Self.glow - age) / 0.5)
                if !reduceMotion, age < Self.swish {
                    // A quick swish away from the pointer and back: a damped wiggle.
                    let k = age / Self.swish
                    let wave = sin(k * .pi * 3) * (1 - k) * (1 - k)
                    point.x += touch.push.dx * 5 * wave
                    point.y += touch.push.dy * 3 * wave
                    tilt = wave * (c.seed > 0.5 ? 0.22 : -0.22)
                }
            }
            var g = context
            g.translateBy(x: point.x, y: point.y)
            if tilt != 0 { g.rotate(by: .radians(tilt)) }
            if color < 1 {
                // Gray at rest; color mixed back in by drawing over it.
                var gray = g
                gray.addFilter(.grayscale(1))
                gray.opacity = (dark ? 0.42 : 0.32) * (1 - color)
                gray.draw(gray.resolve(Text(c.glyph).font(.mark(c.size))
), at: .zero)
            }
            if color > 0 {
                g.opacity = color
                g.draw(g.resolve(Text(c.glyph).font(.mark(c.size))
), at: .zero)
            }
        }
    }

    private static func easeOut(_ t: Double) -> Double { 1 - pow(1 - t, 3) }
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
