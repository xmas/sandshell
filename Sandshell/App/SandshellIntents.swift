import AppIntents
import AppKit

/// Brings the Sandshell window to the front. Exposed as an App Shortcut so the
/// App Intents framework has a real intent to register at launch — without one,
/// macOS logs "Error registering app with intents framework" (the
/// `com.apple.linkd.autoShortcut` XPC failures) on every start.
struct ShowSandshellIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Sandshell"
    static let description = IntentDescription("Bring the Sandshell window to the front.")

    /// Launch the app (if needed) and run `perform` in-process so we can touch
    /// AppKit on the main actor.
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        NSApp.activate(ignoringOtherApps: true)
        // Reopen the main window the same way clicking the Dock icon does.
        _ = (NSApp.delegate as? AppDelegate)?
            .applicationShouldHandleReopen(NSApp, hasVisibleWindows: NSApp.keyWindow != nil)
        return .result()
    }
}

/// Registers Sandshell's App Shortcuts. Required for the App Intents metadata
/// to be extracted at build time and registered cleanly at launch.
struct SandshellShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ShowSandshellIntent(),
            phrases: [
                "Open \(.applicationName)",
                "Show \(.applicationName)",
            ],
            shortTitle: "Open Sandshell",
            systemImageName: "shippingbox"
        )
    }
}
