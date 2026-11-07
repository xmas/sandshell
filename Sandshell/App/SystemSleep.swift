import AppKit

/// Whether the Mac is asleep (between `willSleep` and `didWake`), and a way to
/// hear about waking — chats whose agents died while it slept reconnect then.
@MainActor
enum SystemSleep {
    private(set) static var isAsleep = false
    /// Posted shortly after the Mac wakes (once the sandbox VM has had a moment).
    static let didWake = Notification.Name("SandshellSystemDidWake")
    private static var observers: [NSObjectProtocol] = []

    static func start() {
        guard observers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { isAsleep = true }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                isAsleep = false
                Log.info(.app, "the Mac woke")
                Task { @MainActor in
                    // Suspending clock: like uptime, it doesn't count time the Mac
                    // spends asleep again before the 2 s are up.
                    try? await Task.sleep(for: .seconds(2), clock: .suspending)
                    NotificationCenter.default.post(name: didWake, object: nil)
                }
            }
        })
    }
}

/// Built-in `caffeinate`: while an agent works, the Mac doesn't sleep on its
/// own, so long turns finish overnight. The display may still sleep, and macOS
/// sleeps anyway with the lid closed unless it's on power with an external display.
@MainActor
final class KeepAwake {
    static let shared = KeepAwake()
    static let key = "keepAwakeWhileWorking"
    static var defaults = AppDelegate.isHostingTests
        ? (UserDefaults(suiteName: "SandshellKeepAwakeTests") ?? .standard) : .standard

    static var isEnabled: Bool {
        get { defaults.object(forKey: key) as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: key)
            shared.update()
        }
    }

    /// Whether anything is working right now.
    private var isWorking: () -> Bool = { false }
    private var activity: NSObjectProtocol?
    private var timer: Timer?
    var isHolding: Bool { activity != nil }

    func start(isWorking: @escaping () -> Bool) {
        self.isWorking = isWorking
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { _ in
            MainActor.assumeIsolated { KeepAwake.shared.update() }
        }
        update()
    }

    func update() {
        let hold = Self.isEnabled && isWorking()
        guard hold != isHolding else { return }
        if hold {
            activity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled],
                                                             reason: "An agent is working")
            Log.info(.app, "keeping the Mac awake: an agent is working")
        } else if let held = activity {
            ProcessInfo.processInfo.endActivity(held)
            activity = nil
            Log.info(.app, "letting the Mac sleep: no agent is working")
        }
    }
}

