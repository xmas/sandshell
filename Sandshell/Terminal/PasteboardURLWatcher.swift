import AppKit

/// Watches the system pasteboard for a URL landing there and opens it
/// immediately in the default browser.
///
/// Why this exists: libghostty forwards a terminal's OSC 52 clipboard writes
/// straight to `NSPasteboard.general` (see the vendored
/// `TerminalController+Callbacks.swift`'s `write_clipboard_cb`), with no
/// per-surface delegate hook exposed above that. So when a CLI tool running
/// inside a sandbox does the "here's your login link, copied to your
/// clipboard" dance for a device-code auth flow, there's no clean callback to
/// intercept — watching the pasteboard directly is the pragmatic way to catch
/// that moment without patching/vendoring libghostty.
///
/// Only runs while Sandshell is the active app, so a copy made in another app
/// never triggers it. Within that window, it still can't distinguish an OSC
/// 52 hand-off from you deliberately selecting and ⌘C-ing a URL out of
/// terminal output — both look identical at the pasteboard layer — so it
/// only fires when the *entire* trimmed clipboard string is a bare
/// http/https URL, not a URL found inside a larger block of copied text.
/// That's a deliberate, accepted trade-off: a manual copy-of-just-a-link
/// opens it too, which is usually what you'd want anyway.
@MainActor
final class PasteboardURLWatcher {
    static let shared = PasteboardURLWatcher()

    private let pollInterval: TimeInterval = 0.3
    private var timer: Timer?
    private var lastChangeCount: Int
    private var lastOpenedText: String?

    private init() {
        lastChangeCount = NSPasteboard.general.changeCount
    }

    func start() {
        guard timer == nil else { return }
        // Skip whatever's already on the clipboard from before Sandshell
        // became active — only react to changes from here on.
        lastChangeCount = NSPasteboard.general.changeCount
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChangeCount else { return }
        lastChangeCount = pb.changeCount

        guard let text = pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty, text != lastOpenedText,
              let url = URL(string: text),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              url.host != nil
        else { return }

        lastOpenedText = text
        NSWorkspace.shared.open(url)
    }
}
