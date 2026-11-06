import Foundation

/// Following the end of a chat with momentum: a critically damped spring on
/// the scroll position, so it eases in from rest, carries on smoothly as the
/// end keeps moving (a reply streaming in, chunk after chunk, is one motion
/// rather than a jump each time) and eases out, without overshooting.
struct ScrollFollower {
    var position: CGFloat
    var velocity: CGFloat = 0

    /// How briskly it closes the gap: about 5 / ω seconds to arrive.
    static let omega: CGFloat = 10

    /// Advance by `dt` seconds toward `target`. Exact for the spring, so a
    /// long frame can't make it unstable.
    mutating func step(toward target: CGFloat, dt: CGFloat) {
        let w = Self.omega
        let x = position - target
        let c = velocity + w * x
        let decay = exp(-w * dt)
        position = target + (x + c * dt) * decay
        velocity = (c - w * (x + c * dt)) * decay
        if position > target, velocity >= 0 {   // the end moved back up (text shrank)
            position = target
            velocity = 0
        }
    }

    func isAtRest(at target: CGFloat) -> Bool {
        abs(position - target) < 0.5 && abs(velocity) < 8
    }
}
