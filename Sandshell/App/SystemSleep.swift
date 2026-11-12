import AppKit
import IOKit.ps

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

    /// Also while Remote Control is on and the Mac's on its power adapter,
    /// so a phone can reach it (off unless turned on).
    static let remoteKey = "keepAwakeForRemote"
    static var isEnabledForRemote: Bool {
        get { defaults.bool(forKey: remoteKey) }
        set {
            defaults.set(newValue, forKey: remoteKey)
            shared.update()
        }
    }

    /// Whether the Mac runs on its power adapter (or has no battery).
    static var isOnPowerAdapter: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String? else { return true }
        return type == kIOPMACPowerKey
    }

    /// Whether anything is working right now.
    private var isWorking: () -> Bool = { false }
    /// Whether Remote Control is serving.
    private var isServingRemote: () -> Bool = { false }
    private var activity: NSObjectProtocol?
    private var timer: Timer?
    var isHolding: Bool { activity != nil }

    func start(isWorking: @escaping () -> Bool, isServingRemote: @escaping () -> Bool = { false }) {
        self.isWorking = isWorking
        self.isServingRemote = isServingRemote
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { _ in
            MainActor.assumeIsolated { KeepAwake.shared.update() }
        }
        update()
    }

    /// Why it's kept awake now, if it is.
    private(set) var reason: String?

    func update() {
        let why: String? = if Self.isEnabled && isWorking() {
            "an agent is working"
        } else if Self.isEnabledForRemote && isServingRemote() && Self.isOnPowerAdapter {
            "Remote Control is on"
        } else {
            nil
        }
        guard (why != nil) != isHolding || (why != nil && why != reason) else { return }
        if let held = activity, why != nil, why != reason {
            ProcessInfo.processInfo.endActivity(held)
            activity = nil
        }
        reason = why
        if let why {
            activity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled], reason: why)
            Log.info(.app, "keeping the Mac awake: \(why)")
        } else if let held = activity {
            ProcessInfo.processInfo.endActivity(held)
            activity = nil
            Log.info(.app, "letting the Mac sleep: no agent is working")
        }
    }
}


extension KeepAwake {
    /// A chat's agent left running mid-turn as Sandshell quits or its window
    /// closes (`ChatSession.detach`): keep the Mac awake until that turn is
    /// done — `caffeinate` waiting on the agent's supervisor in the sandbox,
    /// which outlives the app.
    func whileHeld(container: String, conversation: String) {
        guard Self.isEnabled, !AppDelegate.isHostingTests else { return }
        let p = Process()
        p.executableURL = URL(filePath: "/usr/bin/caffeinate")
        p.arguments = ["-i", PathFixer.sbxPath(), "exec", container, SbxCommand.holdEntryPoint, "--wait", conversation]
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            Log.info(.app, "keeping the Mac awake until the turn left running in “\(container)” ends")
        } catch {
            Log.error(.app, "couldn't keep the Mac awake for the turn left running: \(error.localizedDescription)")
        }
    }
}
