import SwiftUI

/// The empty chat's sea: a tide line across the pane — two faint waves
/// drifting, their colors moving slowly through the sea's (teal, blue,
/// indigo), a gray shell riding the top one. Move the pointer along it and
/// the water under the pointer stirs and refracts: the front wave splits into
/// a spectrum there, and closes up again as the water settles. The drift
/// pauses when the window isn't active; under Reduce Motion the water lies
/// still in one color.
struct SeaField: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.controlActiveState) private var activeState
    /// Self-tests: start as if the pointer had just passed here (x in points).
    var initialStir: Double?

    /// Where the pointer last passed, and when.
    @State private var stir: (x: Double, at: Date)?

    init(initialStir: Double? = nil) {
        self.initialStir = initialStir
        _stir = State(initialValue: initialStir.map { ($0, .now) })
    }

    static let height: Double = 56
    private static let baseline = 30.0
    private static let settle = 2.0         // how fast a stir dies away (per second)
    private static let stirSpread = 4000.0  // 2σ² of the stir: about 45 pt either side of the pointer
    private static let stirHeight = 9.0
    private static let colorPeriod = 40.0   // seconds for the colors to come round again
    private static let step = 6.0           // points between the wave's samples

    /// The spectrum the stirred water splits into: each color's hue and how
    /// far its wave runs ahead of (or behind) the water's.
    private static let fringes: [(hue: Double, shift: Double)] = [(0.98, -1), (0.33, 0), (0.72, 1)]

    private var still: Bool { reduceMotion || activeState == .inactive }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: still)) { timeline in
            Canvas { context, size in draw(in: context, size: size, now: timeline.date) }
        }
        .frame(height: Self.height)
        .frame(maxWidth: .infinity)
        .contentShape(.rect)
        .onContinuousHover(coordinateSpace: .local) { phase in
            if case .active(let point) = phase { stir = (point.x, .now) }
        }
        .accessibilityHidden(true)
    }

    /// How stirred the water is at `x`, 0…1: most under the pointer, dying away.
    static func stirred(_ x: Double, by stir: (x: Double, age: Double)?) -> Double {
        guard let stir else { return 0 }
        return exp(-pow(x - stir.x, 2) / stirSpread) * exp(-settle * stir.age)
    }

    /// The wave's height at `x`: two slow swells, plus the stir under the
    /// pointer. `split` moves one color of a refracted wave off the water's.
    static func level(_ x: Double, time t: Double, speed: Double, phase: Double,
                      stir: (x: Double, age: Double)?, split: Double = 0) -> Double {
        var y = baseline + sin(x / 38 + t * speed + phase) * 3 + sin(x / 91 - t * 0.6) * 2
        let s = stirred(x, by: stir)
        if s > 0.001 {
            y -= s * stirHeight * sin(t * 6 + x / 20 + split * 0.7)
            y += s * split * 2.5
        }
        return y
    }

    /// The water's hue at `x` (0…1 across), drifting with time: teal to indigo.
    static func hue(at u: Double, time t: Double, lift: Double) -> Double {
        0.55 + lift + 0.13 * sin(t * 2 * .pi / colorPeriod + u * .pi)
    }

    private func draw(in context: GraphicsContext, size: CGSize, now: Date) {
        // Still water: the same frozen moment every time.
        let t = still ? 0 : now.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3600)
        let pushed = stir.map { (x: $0.x, age: now.timeIntervalSince($0.at)) }.flatMap { $0.age < 4 ? $0 : nil }
        let dark = colorScheme == .dark
        let width = max(size.width, 1)

        func wave(speed: Double, phase: Double, lift: Double, split: Double = 0) -> Path {
            var path = Path()
            var x = 0.0
            while x <= size.width + Self.step {
                let p = CGPoint(x: x, y: Self.level(x, time: t, speed: speed, phase: phase,
                                                    stir: pushed, split: split) + lift)
                if x == 0 { path.move(to: p) } else { path.addLine(to: p) }
                x += Self.step
            }
            return path
        }
        /// A stroke whose color follows `color(u)` from the left edge (u = 0) to the right (1).
        func across(_ color: (Double) -> Color) -> GraphicsContext.Shading {
            let stops = stride(from: 0.0, through: 1.0, by: 1 / 48).map { Gradient.Stop(color: color($0), location: $0) }
            return .linearGradient(Gradient(stops: stops), startPoint: .zero, endPoint: CGPoint(x: width, y: 0))
        }
        func water(_ u: Double, lift: Double, opacity: Double) -> Color {
            Color(hue: Self.hue(at: u, time: t, lift: lift), saturation: dark ? 0.55 : 0.7,
                  brightness: dark ? 0.95 : 0.6).opacity(opacity)
        }

        let (front, back) = dark ? (0.38, 0.18) : (0.5, 0.24)
        context.stroke(wave(speed: 0.7, phase: 2, lift: 9),
                       with: across { water($0, lift: 0.08, opacity: back) }, lineWidth: 1)
        context.stroke(wave(speed: 0.9, phase: 0, lift: 0),
                       with: across { water($0, lift: 0, opacity: front) }, lineWidth: 1.2)

        // Refraction: where the water's stirred, the front wave splits into a
        // spectrum, each color off on its own wave; elsewhere they're invisible.
        if let pushed, Self.stirred(pushed.x, by: pushed) > 0.01 {
            var light = context
            light.blendMode = dark ? .plusLighter : .normal
            for fringe in Self.fringes {
                let shine = Color(hue: fringe.hue, saturation: 0.85, brightness: dark ? 1 : 0.75)
                light.stroke(wave(speed: 0.9, phase: 0, lift: 0, split: fringe.shift),
                             with: across { shine.opacity(min(1, Self.stirred($0 * width, by: pushed) * 1.4) * 0.75) },
                             lineWidth: 1.4)
            }
        }

        // The shell drifts a little either side of the middle, on the top wave.
        let sx = size.width / 2 + sin(t * 0.25) * 40
        let sy = Self.level(sx, time: t, speed: 0.9, phase: 0, stir: pushed) - 10
        var g = context
        g.addFilter(.grayscale(1))
        g.opacity = 0.55
        g.draw(Text("🐚").font(.mark(18)), at: CGPoint(x: sx, y: sy), anchor: .center)
    }
}
