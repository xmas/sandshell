import AppKit

/// The app's questions and notices, built one way: a confirm whose action
/// button can be marked destructive, a save-changes prompt, and an inform —
/// as a sheet on a window when there is one, app-modal otherwise.
@MainActor
enum Alerts {
    private static func make(_ title: String, _ info: String, style: NSAlert.Style,
                             buttons: [String], destructive: Bool) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = info
        alert.alertStyle = style
        for b in buttons { alert.addButton(withTitle: b) }
        if destructive { alert.buttons.first?.hasDestructiveAction = true }
        return alert
    }

    /// Ask, app-modal; true for `confirm`.
    static func confirm(_ title: String, _ info: String, confirm: String, cancel: String = "Cancel",
                        destructive: Bool = false, style: NSAlert.Style = .warning) -> Bool {
        make(title, info, style: style, buttons: [confirm, cancel], destructive: destructive)
            .runModal() == .alertFirstButtonReturn
    }

    /// Ask as a sheet on `window` (app-modal without one); true for `confirm`.
    static func confirm(_ title: String, _ info: String, confirm: String, cancel: String = "Cancel",
                        destructive: Bool = false, style: NSAlert.Style = .warning,
                        in window: NSWindow?) async -> Bool {
        let alert = make(title, info, style: style, buttons: [confirm, cancel], destructive: destructive)
        guard let window else { return alert.runModal() == .alertFirstButtonReturn }
        return await alert.beginSheetModal(for: window) == .alertFirstButtonReturn
    }

    /// Say something; a sheet on `window` when there is one.
    static func inform(_ title: String, _ info: String, style: NSAlert.Style = .informational, in window: NSWindow? = nil) {
        let alert = make(title, info, style: style, buttons: [], destructive: false)
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }

    /// Ask with several answers, as a sheet on `window` (app-modal without
    /// one): the index of the button pressed, `buttons[0]` being the default.
    static func choose(_ title: String, _ info: String, buttons: [String], style: NSAlert.Style = .warning,
                       in window: NSWindow?) async -> Int {
        let alert = make(title, info, style: style, buttons: buttons, destructive: false)
        let answer: NSApplication.ModalResponse
        if let window { answer = await alert.beginSheetModal(for: window) } else { answer = alert.runModal() }
        return answer.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
    }

    enum SaveChoice { case save, cancel, discard }

    /// "Save changes to …?" with Save (All) / Cancel / Don't Save.
    static func saveChanges(_ names: [String]) -> SaveChoice {
        let alert = make(names.count == 1 ? "Save changes to “\(names[0])”?" : "Save changes to \(names.count) files?",
                         "Your changes will be lost if you don’t save them.", style: .warning,
                         buttons: [names.count == 1 ? "Save" : "Save All", "Cancel", "Don’t Save"], destructive: false)
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .save
        case .alertSecondButtonReturn: return .cancel
        default: return .discard
        }
    }
}
