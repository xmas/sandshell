#if DEBUG
import AppKit

/// `-SandshellUITestHeadless YES` (scripts/run-ui-tests.sh): keep every window
/// — including sheets opened later — transparent, click-through and behind
/// other apps, so the suite never covers or takes input from the user's apps.
@MainActor
enum UITestHeadless {
    static var enabled: Bool { UserDefaults.standard.bool(forKey: "SandshellUITestHeadless") }
    private static var seen = Set<ObjectIdentifier>()
    private static var timer: Timer?

    static func start() {
        hideNewWindows()
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            MainActor.assumeIsolated { hideNewWindows() }
        }
    }

    private static func hideNewWindows() {
        for w in NSApp.windows where w.isVisible && !seen.contains(ObjectIdentifier(w)) {
            seen.insert(ObjectIdentifier(w))
            w.alphaValue = 0
            w.ignoresMouseEvents = true
            if w.sheetParent == nil { w.orderBack(nil) }
        }
    }
}

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
        case "chat": await chat(window)
        case "building": await building(window)
        case "alerts": alerts()
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

    // MARK: Chat

    /// A real Claude chat over ACP in the workspace's sandbox: ready, a prompt
    /// streams back, a tool permission is approved, a long turn is stopped.
    /// Uses the signed-in account (three tiny turns).
    private static func chat(_ window: MainWindowController) async {
        guard let tree = window.paneTree, let ws = window.workspaceController else { return log("no window") }
        guard let s = ws.newChatInCurrentContext() else { return log("no folder to start a chat in") }
        func session() -> ChatSession? { tree.surfaces.chats[s.id]?.session }
        func agentText(_ chat: ChatSession) -> String {
            chat.items.compactMap { if case .agentText(_, let t) = $0 { t } else { nil } }.joined()
        }
        check(await until(600) { session()?.phase == .ready }, "chat reaches ready (sandbox + adapter up)")
        guard let chat = session(), chat.phase == .ready else { return log("chat phase: \(String(describing: session()?.phase))") }
        log("model \(chat.currentModel ?? "-"), mode \(chat.currentMode ?? "-"), \(chat.commands.count) commands")
        check(!chat.commands.isEmpty, "agent advertises slash commands")

        chat.send(text: "Reply with exactly the word PONG and nothing else.", attachments: [])
        check(await until(180) { chat.phase == .ready && agentText(chat).contains("PONG") }, "a prompt streams back text")
        check(chat.usage != nil, "usage reported for the ctx/cost footer (\(String(describing: chat.usage)))")
        snapshot(window, "chat-pong")

        // A shell command: asks permission unless the mode/settings allow it.
        let marker = URL(fileURLWithPath: chat.workdir).appendingPathComponent("sandshell-selftest.txt")
        try? FileManager.default.removeItem(at: marker)
        chat.send(text: "Use the Bash tool to run exactly this command and nothing else: echo ok > sandshell-selftest.txt",
                  attachments: [])
        _ = await until(180) { chat.permission != nil || (chat.phase == .ready && FileManager.default.fileExists(atPath: marker.path)) }
        if let p = chat.permission {
            snapshot(window, "chat-permission")
            let allow = p.options.first { $0.kind == "allow_once" } ?? p.options.first
            log("permission \"\(p.title)\" → \(allow?.name ?? "-")")
            chat.answerPermission(p, optionID: allow?.id)
        } else {
            log("no permission prompt (mode \(chat.currentMode ?? "-") allowed it)")
        }
        check(await until(180) { chat.phase == .ready }, "turn with the tool call finishes")
        let tools = chat.items.compactMap { if case .tool(let t) = $0 { t } else { nil } }
        check(tools.contains { $0.status == "completed" }, "tool call card completed (\(tools.map(\.status)))")
        check(FileManager.default.fileExists(atPath: marker.path), "the command ran in the sandbox (file on the host mount)")
        try? FileManager.default.removeItem(at: marker)

        chat.send(text: "Count from 1 to 400, one number per line, no other text.", attachments: [])
        check(await until(60) { chat.phase == .running }, "long turn starts")
        await wait(3)
        let stopAt = Date()
        chat.cancel()
        check(await until(20) { chat.phase == .ready }, "Stop returns to ready")
        log(String(format: "stopped in %.1fs", Date().timeIntervalSince(stopAt)))
        let countAtStop = chat.items.count
        await wait(3)
        check(chat.items.count == countAtStop, "nothing streams in after Stop (\(chat.items.count - countAtStop) late items)")
        snapshot(window, "chat-final")
    }

    // MARK: New session mid-build

    /// Needs a workspace whose sandbox doesn't exist yet: a session added while
    /// it's being created must launch once it's up.
    private static func building(_ window: MainWindowController) async {
        guard let tree = window.paneTree, let ws = window.workspaceController else { return log("no window") }
        check(await until(30) { ws.isBuilding }, "fresh workspace starts building its sandbox")
        guard let s = ws.newSessionInCurrentContext() else { return log("no folder for a session") }
        check(ws.isBuilding, "New Session added while building")
        let ok = await until(240) { tree.surfaces.terminals[s.id] != nil }
        log("building=\(ws.isBuilding) activity=\(ws.activity ?? "nil") pending=\(tree.surfaces.pending.contains(s.id)) "
            + "shown=\(tree.panes.map { $0.shownSession == s.id }) error=\(ws.lastError ?? "nil")")
        check(ok, "the session launches once the sandbox is up")
        snapshot(window, "building-final")
    }

    // MARK: Alerts

    /// Scripted runs must never wait on a person: alerts answer themselves.
    private static func alerts() {
        let alert = NSAlert()
        alert.messageText = "Self-test alert"
        alert.addButton(withTitle: "Proceed")
        alert.addButton(withTitle: "Cancel")
        let started = Date()
        let answer = alert.runModal()
        check(answer == .alertFirstButtonReturn, String(format: "app-modal alert answered with its default button in %.1fs", Date().timeIntervalSince(started)))
    }
}
#endif
