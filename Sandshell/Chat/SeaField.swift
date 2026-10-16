import SwiftUI

/// The empty chat's sea: a quiet band of sea creatures in black and white.
/// Pass the pointer over them and the ones near it take on color and swim round
/// it in a bubble for a moment, then drift home and fade back to gray. The
/// field fills its whole frame (bubbles reach past the band to the pane's
/// edges); the creatures rest in `band`. Nothing moves until then; under Reduce
/// Motion they only color in.
struct SeaField: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    /// Where the creatures rest, in this view's coordinates (up to `size`).
    var band: CGRect
    /// Self-tests: start with a splash here, in band coordinates.
    var initialSplash: CGPoint?

    /// A bubble and the creatures it caught (each swims in one at a time).
    private struct Splash { let point: CGPoint; let start: Date; let members: Set<Int> }
    @State private var splashes: [Splash] = []
    @State private var lastSpawn: CGPoint?

    static let size = CGSize(width: 400, height: 168)
    private static let swim: Double = 1.2      // seconds in the bubble
    private static let settle: Double = 0.7    // back home and fading to gray
    private static let reach: Double = 74      // how far the pointer reaches
    private static let stride: Double = 36     // pointer travel between bubbles

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

    private var animating: Bool { !splashes.isEmpty }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 60, paused: !animating)) { timeline in
            Canvas { context, _ in draw(in: context, now: timeline.date) }
        }
        .contentShape(Rectangle())
        .onContinuousHover(coordinateSpace: .local) { phase in
            switch phase {
            case .active(let point): hover(point)
            case .ended: lastSpawn = nil
            }
        }
        .onAppear {
            if let p = initialSplash { spawn(at: CGPoint(x: p.x + origin.x, y: p.y + origin.y), force: true) }
        }
        .accessibilityHidden(true)
    }

    /// The creatures' 400-pt field, centred on the band: in a narrow pane the
    /// band is narrower and the outer creatures just run off the edges.
    private var origin: CGPoint { CGPoint(x: band.midX - Self.size.width / 2, y: band.minY) }

    private func home(_ i: Int) -> CGPoint {
        CGPoint(x: origin.x + Self.creatures[i].home.x, y: origin.y + Self.creatures[i].home.y)
    }

    /// A bubble wherever the pointer has travelled far enough since the last
    /// one and finds creatures that aren't already swimming.
    private func hover(_ point: CGPoint) {
        if let last = lastSpawn, hypot(point.x - last.x, point.y - last.y) < Self.stride { return }
        spawn(at: point, force: false)
    }

    private func spawn(at point: CGPoint, force: Bool) {
        let busy = splashes.reduce(into: Set<Int>()) { $0.formUnion($1.members) }
        let members = Set(Self.creatures.indices.filter {
            !busy.contains($0) && hypot(home($0).x - point.x, home($0).y - point.y) < Self.reach
        })
        guard force || !members.isEmpty else { return }
        lastSpawn = point
        let s = Splash(point: point, start: Date(), members: members)
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
            let rest = home(i)
            var point = rest
            var color = 0.0        // 0 = gray, 1 = full color
            var heading = -1.0     // emoji face left; -1 = as drawn, 1 = mirrored
            if let s = splashes.last(where: { $0.members.contains(i) }) {
                let age = now.timeIntervalSince(s.start)
                // Color in fast, hold, fade back out once home.
                color = age < Self.swim ? min(1, age / 0.15) : max(0, 1 - (age - Self.swim) / Self.settle)
                if !reduceMotion {
                    // Into an orbit round the pointer, a lap or so, then home again.
                    let orbit = Self.reach * (0.3 + 0.35 * c.seed)
                    let start = atan2(rest.y - s.point.y, rest.x - s.point.x)
                    let angle = start + age * (2.2 + c.seed) * (i % 2 == 0 ? 1 : -1)
                    let target = CGPoint(x: s.point.x + cos(angle) * orbit, y: s.point.y + sin(angle) * orbit * 0.8)
                    let into = Self.easeInOut(min(1, age / 0.35))
                    let out = Self.easeInOut(max(0, min(1, (age - Self.swim) / Self.settle)))
                    let mix = into * (1 - out)
                    point = CGPoint(x: rest.x + (target.x - rest.x) * mix, y: rest.y + (target.y - rest.y) * mix)
                    // Face the way it's swimming round.
                    let vx = -sin(angle) * (i % 2 == 0 ? 1 : -1)
                    if mix > 0.2 { heading = vx > 0 ? 1 : -1 }
                }
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

/// The empty chat: the sea's band above the prompt, the sea itself spread over
/// the whole pane so bubbles never meet an edge.
struct SeaBackdrop<Content: View>: View {
    var initialSplash: CGPoint?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 14) {
            Color.clear
                .frame(maxWidth: SeaField.size.width)
                .frame(height: SeaField.size.height)
                .anchorPreference(key: SeaBandKey.self, value: .bounds) { $0 }
            content.allowsHitTesting(false)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .backgroundPreferenceValue(SeaBandKey.self) { anchor in
            GeometryReader { proxy in
                if let anchor { SeaField(band: proxy[anchor], initialSplash: initialSplash) }
            }
        }
    }
}

private struct SeaBandKey: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) { value = value ?? nextValue() }
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
