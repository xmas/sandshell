import AppKit
import UserNotifications

/// Sends a macOS notification when a session finishes working and navigates back
/// to that session when the notification is tapped.
@MainActor
final class NotificationManager: NSObject {
    static let shared = NotificationManager()

    /// Called (on the main actor) when the user taps a work-complete notification.
    /// `AppDelegate` sets this to find the right window and select the session.
    var onSessionTap: ((UUID) -> Void)?

    func requestPermission() {
        guard !AutomatedRun.isActive else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Fire a work-complete notification for `sessionID`.
    /// Skipped if the session is currently selected and the app is in the foreground
    /// (the user can already see the result).
    func sendWorkComplete(sessionID: UUID,
                          agentName: String,
                          sessionName: String,
                          lastPrompt: String?,
                          workSeconds: TimeInterval,
                          workdir: String) {
        guard !AutomatedRun.isActive else { return }
        let content = UNMutableNotificationContent()
        content.title = "\(agentName.capitalized) finished — \(sessionName)"
        if let p = lastPrompt?.trimmingCharacters(in: .whitespacesAndNewlines), !p.isEmpty {
            content.subtitle = p.count > 80 ? String(p.prefix(77)) + "…" : p
        }
        var bodyParts: [String] = []
        if workSeconds >= 1 { bodyParts.append(formatWorkTime(workSeconds)) }
        bodyParts.append(shortenHome(workdir))
        content.body = bodyParts.joined(separator: " · ")
        content.sound = .default
        content.userInfo = ["sessionID": sessionID.uuidString]

        let request = UNNotificationRequest(
            identifier: "work-done-\(sessionID.uuidString)",
            content: content,
            trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private func shortenHome(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }
}

extension NotificationManager: @preconcurrency UNUserNotificationCenterDelegate {
    /// Show the notification as a banner even while Sandshell is active, so that
    /// background sessions (not currently selected) surface their completion.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                 willPresent notification: UNNotification,
                                 withCompletionHandler handler: @escaping (UNNotificationPresentationOptions) -> Void) {
        handler([.banner, .sound])
    }

    /// Bring the app to the front and select the session that finished.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                 didReceive response: UNNotificationResponse,
                                 withCompletionHandler handler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        if let raw = info["sessionID"] as? String, let id = UUID(uuidString: raw) {
            NSApp.activate(ignoringOtherApps: true)
            onSessionTap?(id)
        }
        handler()
    }
}
