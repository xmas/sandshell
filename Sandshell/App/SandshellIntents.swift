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
    static let supportedModes: IntentModes = .foreground

    @MainActor
    func perform() async throws -> some IntentResult {
        NSApp.activate()
        // Reopen the main window the same way clicking the Dock icon does.
        _ = (NSApp.delegate as? AppDelegate)?
            .applicationShouldHandleReopen(NSApp, hasVisibleWindows: NSApp.keyWindow != nil)
        return .result()
    }
}

/// Starts a native Claude chat in the front workspace, optionally sending a
/// prompt right away — for Shortcuts, Spotlight and Siri.
struct NewClaudeChatIntent: AppIntent {
    static let title: LocalizedStringResource = "New Claude Chat"
    static let description = IntentDescription(
        "Start a Claude chat in Sandshell's front workspace, optionally with a prompt.")
    static let supportedModes: IntentModes = .foreground

    @Parameter(title: "Prompt") var prompt: String?
    @Parameter(title: "Send Immediately", default: true) var sendNow: Bool

    @MainActor
    func perform() async throws -> some IntentResult {
        let text = prompt ?? ""
        (NSApp.delegate as? AppDelegate)?.newChat(draft: text, urls: [], send: sendNow && !text.isEmpty)
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
        AppShortcut(
            intent: NewClaudeChatIntent(),
            phrases: [
                "New chat in \(.applicationName)",
                "Ask Claude in \(.applicationName)",
            ],
            shortTitle: "New Claude Chat",
            systemImageName: "bubble.left.and.text.bubble.right"
        )
    }
}
