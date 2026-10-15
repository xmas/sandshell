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
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    NotificationCenter.default.post(name: didWake, object: nil)
                }
            }
        })
    }
}
