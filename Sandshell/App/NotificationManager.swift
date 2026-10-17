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
        content.title = "\(agentName) finished — \(sessionName)"
        if let p = lastPrompt?.trimmingCharacters(in: .whitespacesAndNewlines), !p.isEmpty {
            content.subtitle = p.count > 80 ? String(p.prefix(77)) + "…" : p
        }
        var bodyParts: [String] = []
        if workSeconds >= 1 { bodyParts.append(formatWorkTime(workSeconds)) }
        bodyParts.append(workdir.tildeAbbreviated)
        content.body = bodyParts.joined(separator: " · ")
        content.sound = .default
        content.userInfo = ["sessionID": sessionID.uuidString]

        let request = UNNotificationRequest(
            identifier: "work-done-\(sessionID.uuidString)",
            content: content,
            trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// The agent is waiting on the person (a question, a permission).
    func sendNeedsInput(sessionID: UUID, agentName: String, sessionName: String, text: String) {
        guard !AutomatedRun.isActive else { return }
        let content = UNMutableNotificationContent()
        content.title = "\(agentName) needs you — \(sessionName)"
        content.body = text.count > 160 ? String(text.prefix(157)) + "…" : text
        content.sound = .default
        content.threadIdentifier = sessionID.uuidString
        content.userInfo = ["sessionID": sessionID.uuidString]
        UNUserNotificationCenter.current().add(UNNotificationRequest(
            identifier: "needs-input-\(sessionID.uuidString)", content: content, trigger: nil))
    }

    /// Posted (object: session UUID) when a background-task notification is
    /// tapped: the pane showing that session opens its task list.
    static let showBackgroundTasks = Notification.Name("SandshellShowBackgroundTasks")

    /// A session's background task (subagent, background command, Monitor) finished.
    func sendBackgroundTaskDone(sessionID: UUID, sessionName: String, task: BackgroundTask) {
        guard !AutomatedRun.isActive else { return }
        let content = UNMutableNotificationContent()
        let what: String
        switch task.kind {
        case .agent: what = "Subagent"
        case .shell: what = "Background command"
        case .monitor: what = "Monitor"
        case .workflow: what = "Workflow"
        }
        switch task.state {
        case .failed: content.title = "\(what) failed — \(task.title)"
        case .stopped: content.title = "\(what) stopped — \(task.title)"
        default: content.title = "\(what) finished — \(task.title)"
        }
        content.subtitle = sessionName
        var body: [String] = []
        if let summary = task.summary, !summary.isEmpty { body.append(summary) }
        let seconds = task.duration()
        if seconds >= 1 { body.append(formatWorkTime(seconds)) }
        content.body = body.joined(separator: " · ")
        content.sound = .default
        content.threadIdentifier = sessionID.uuidString
        content.userInfo = ["sessionID": sessionID.uuidString, "backgroundTask": task.id]
        UNUserNotificationCenter.current().add(UNNotificationRequest(
            identifier: "bg-\(sessionID.uuidString)-\(task.id)", content: content, trigger: nil))
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
            if info["backgroundTask"] != nil {
                NotificationCenter.default.post(name: Self.showBackgroundTasks, object: id)
            }
        }
        handler()
    }
}
