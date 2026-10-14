#if DEBUG
import AppKit

/// Debug-only scripted checks, run with `-SandshellSelfTest panes
/// -SandshellSelfTestOut <dir>`: drives the real window offscreen (no
/// activation, no input events), logs PASS/FAIL lines, writes snapshots, quits.
@MainActor
enum SelfTest {
    static var requested: String? { UserDefaults.standard.string(forKey: "SandshellSelfTest") }
    private static var out: String { UserDefaults.standard.string(forKey: "SandshellSelfTestOut") ?? NSTemporaryDirectory() }
    private static var lines: [String] = []
    private static var failures = 0

    static func run(_ window: MainWindowController) async {
        // On screen (so terminals' display links tick and redraw after resizes)
        // but fully transparent, click-through and behind other windows.
        if let w = window.window {
            w.alphaValue = 0
            w.ignoresMouseEvents = true
            let screen = w.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
            w.setFrame(NSRect(x: screen.minX, y: screen.minY, width: 1400, height: 820), display: true)
            w.orderBack(nil)
        }
        switch requested {
        case "panes": await panes(window)
        default: log("unknown self-test \(requested ?? "")")
        }
        log(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
        try? lines.joined(separator: "\n").write(toFile: out + "/selftest.log", atomically: true, encoding: .utf8)
        NSApp.terminate(nil)
    }

    private static func log(_ s: String) {
        lines.append(s)
        print("[selftest] " + s)
    }

    private static func check(_ ok: Bool, _ what: String) {
        if !ok { failures += 1 }
        log((ok ? "PASS " : "FAIL ") + what)
    }

    private static func wait(_ seconds: Double = 0.4) async { try? await Task.sleep(for: .seconds(seconds)) }

    private static func until(_ timeout: Double, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline { if condition() { return true }; await wait(0.25) }
        return condition()
    }

    private static func snapshot(_ window: MainWindowController, _ name: String) {
        guard let view = window.window?.contentView else { return }
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)   // (layer contents, regardless of window alpha)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out + "/\(name).png"))
        log("snapshot \(name).png")
    }

    // MARK: Panes

    private static func panes(_ window: MainWindowController) async {
        guard let tree = window.paneTree, let ws = window.workspaceController else { return log("no window") }
        let sessions = ws.orderedSessions
        guard sessions.count >= 2 else { return log("need 2 sessions, have \(sessions.count)") }
        let a = sessions[0].id, b = sessions[1].id
        func shown() -> [UUID?] { tree.panes.map(\.shownSession) }
        func focusedIndex() -> Int? { tree.panes.firstIndex { $0 === tree.focused } }
        func live(_ id: UUID) -> Bool { tree.surfaces.terminals[id] != nil }

        ws.selection = .session(a)
        check(await until(90) { live(a) }, "session A launches in the only pane")
        check(tree.panes.count == 1 && shown() == [a], "one pane showing A")

        window.splitRight()
        await wait()
        check(tree.panes.count == 2 && shown() == [a, nil] && focusedIndex() == 1, "Split Right adds an empty focused pane")

        ws.selection = .session(b)
        check(await until(90) { live(b) }, "selecting B launches it in the focused pane")
        check(shown() == [a, b], "panes show [A, B]")

        ws.selection = .session(a)
        await wait()
        check(shown() == [a, b] && focusedIndex() == 0, "selecting A focuses its pane instead of duplicating")

        window.splitDown()
        await wait()
        check(tree.panes.count == 3 && shown() == [a, nil, b] && focusedIndex() == 1, "Split Down under A adds an empty pane")
        snapshot(window, "panes-3")

        // Move B into the empty pane (what a centre drop does): B's terminal is reparented, not relaunched.
        let bView = tree.surfaces.terminals[b]?.view
        tree.split(tree.panes[1], edge: .trailing, showing: b)
        await wait()
        check(tree.panes.count == 4 && shown().filter { $0 == b }.count == 1, "B shows in exactly one pane after moving")
        check(tree.surfaces.terminals[b]?.view === bView && live(b), "B's terminal moved without relaunching")
        if let pane = tree.panes.first(where: { $0.shownSession == b }), let v = bView {
            check(v.isDescendant(of: pane.view), "B's terminal view lives in its new pane")
        }

        tree.closeFocused()
        await wait()
        check(tree.panes.count == 3 && live(b), "Close Pane keeps the session running")

        window.equalizePanes()
        await wait()
        let frames = tree.panes.map { $0.view.frame }
        log("pane sizes after equalize: \(frames.map { "\(Int($0.width))×\(Int($0.height))" })")
        // Layout now: [A over empty] | old-B pane — two equal columns, A/empty equal rows.
        if frames.count == 3 {
            check(abs(frames[0].width - frames[2].width) <= 2, "Equalize: columns equal width")
            check(abs(frames[0].height - frames[1].height) <= 2, "Equalize: rows equal height")
        }
        await wait(0.6)
        snapshot(window, "panes-final")

        window.focusNextPane()
        await wait()
        check(focusedIndex() != nil, "Next Pane moves focus")

        // Layout persists (saved asynchronously).
        await wait(1.0)
        let key = "paneLayout:" + ws.rootURL.standardizedFileURL.path
        check(UserDefaults.standard.data(forKey: key) != nil, "layout saved for the window")
    }
}
#endif
