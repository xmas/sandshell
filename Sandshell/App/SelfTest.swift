#if DEBUG
import AppKit
import SwiftUI

/// `-SandshellUITestHeadless YES` (scripts/run-ui-tests.sh): keep every window
/// — including sheets opened later — transparent, click-through and behind
/// other apps, so the suite never covers or takes input from the user's apps.
/// With `-SandshellUITestBridge <dir>` the suite drives the app through files
/// rather than Apple Events (each fresh test build would need an Automation
/// approval): it writes `<dir>/request` ("stat", "news" or "open <url>"); the
/// app answers in `<dir>/response` and removes the request.
@MainActor
enum UITestHeadless {
    static var enabled: Bool { UserDefaults.standard.bool(forKey: "SandshellUITestHeadless") }
    private static var seen = Set<ObjectIdentifier>()
    private static var timer: Timer?
    private static let bridge = UserDefaults.standard.string(forKey: "SandshellUITestBridge")
        .map { URL(fileURLWithPath: $0, isDirectory: true) }

    static func start() {
        hideNewWindows()
        let t = Timer(timeInterval: 0.05, repeats: true) { _ in
            MainActor.assumeIsolated {
                hideNewWindows()
                serveBridge()
            }
        }
        RunLoop.main.add(t, forMode: .common)   // keeps hiding windows while an alert runs modally
        timer = t
    }

    private static func serveBridge() {
        guard let dir = bridge, let app = NSApp.delegate as? AppDelegate else { return }
        let request = dir.appendingPathComponent("request")
        guard let command = try? String(contentsOf: request, encoding: .utf8) else { return }
        try? FileManager.default.removeItem(at: request)
        let reply = app.uiTestCommand(command.trimmingCharacters(in: .whitespacesAndNewlines))
        try? reply.write(to: dir.appendingPathComponent("response"), atomically: true, encoding: .utf8)
    }

    private static func hideNewWindows() {
        for w in NSApp.windows where w.isVisible && !seen.contains(ObjectIdentifier(w)) {
            seen.insert(ObjectIdentifier(w))
            // Not 0: AppKit leaves fully transparent windows out of the AX tree.
            w.alphaValue = 0.01
            w.ignoresMouseEvents = true
            // AX only lists windows on the current Space; follow the user's.
            w.collectionBehavior.insert(.canJoinAllSpaces)
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

    /// Before any window opens: start from the default single-pane layout so
    /// one scenario's saved panes can't leak into the next (`files-relaunch`
    /// is the one that checks a saved layout, so it keeps them).
    static func prepare() {
        guard let scenario = requested, scenario != "files-relaunch" else { return }
        let defaults = UserDefaults.standard
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("paneLayout:") {
            defaults.removeObject(forKey: key)
        }
    }
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
        case "files": await files(window)
        case "files-relaunch": await filesRelaunch(window)
        case "kits": await kits(window)
        case "agents": await agents(window)
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

    // MARK: Custom agents + Codex/Gemini chats

    /// Custom agent registration (from the `kind: sandbox` kit named by
    /// `-SandshellSelfTestKit <dir>`, optionally a mixin at
    /// `-SandshellSelfTestMixin <dir>`), the New Session menu, then for Codex
    /// and Gemini: a raw ACP initialize + session/new against each agent's
    /// sandbox (created through the app's own path), and the chat surface's
    /// behavior without credentials (or a PONG round trip with them).
    private static func agents(_ window: MainWindowController) async {
        guard let tree = window.paneTree, let ws = window.workspaceController else { return log("no window") }
        let defaults = UserDefaults.standard

        // 1. Registration from a kind: sandbox kit.
        if let kit = defaults.string(forKey: "SandshellSelfTestKit") {
            do {
                let p = try await AgentProfileStore.register(kitRef: kit)
                log("registered \(p.agent) “\(p.displayName)” color \(p.colorHex) image \(p.image ?? "-")")
                let agent = p.kind
                check(!agent.isBuiltin && agent.displayName == p.displayName, "custom agent shows its kit's display name")
                check(agent.createReference == kit, "sbx create positional is the kit (\(agent.createReference))")
                check(ImageChannel.custom.templateImage(for: agent, custom: "example/img:1") == nil
                      && ImageChannel.custom.templateImage(for: .codex, custom: "example/img:1") != nil,
                      "no -t for a kit agent (builtins still get it)")
                ws.setCustomAgents([agent])
                check(ws.availableAgents.contains(agent) && ws.customAgents == [agent], "workspace offers the custom agent")
                let cfg = (try? WorkspaceConfig.load(root: ws.rootURL)) ?? nil
                check(cfg?.customAgents == [agent], "custom agent persisted in config.json")
                check(ws.agentForContainer(named: ws.containerName(for: agent)) == agent,
                      "agentForContainer finds the custom agent's container")
                var edited = p
                edited.displayName = "Probe Agent"
                AgentProfileStore.upsert(edited)
                check(agent.displayName == "Probe Agent", "display name edit applies")
                renderAgentsPane(ws)

                // The custom agent's sandbox, created from its kit through the app's path.
                if let c = await ws.ensureContainerReady(for: agent),
                   let sb = try? await SbxClient.shared.status(name: c) {
                    check(sb.agent == p.agent, "custom agent's sandbox \(c) created from its kit (sbx agent \(sb.agent))")
                } else {
                    check(false, "custom agent's sandbox comes up (\(ws.lastError ?? "?"))")
                }
                if let folder = ws.folders.first, let s = ws.addSession(folderID: folder.id, agent: agent) {
                    ws.selection = .session(s.id)
                    check(await until(90) { tree.surfaces.terminals[s.id] != nil }, "custom agent terminal session launches")
                    await wait(3)
                    snapshot(window, "custom-agent-session")
                }
            } catch {
                check(false, "register custom agent: \(error.localizedDescription)")
            }
        }
        if let mixin = defaults.string(forKey: "SandshellSelfTestMixin") {
            do {
                _ = try await AgentProfileStore.register(kitRef: mixin)
                check(false, "a mixin kit is refused as an agent")
            } catch {
                check(error.localizedDescription.contains("not an agent"), "a mixin kit is refused: \(error.localizedDescription)")
            }
        }

        // 2. New Session menu.
        let titles = window.sidebarList?.newSessionMenuTitles() ?? []
        log("menu: \(titles.joined(separator: " | "))")
        for t in ["New Claude Chat", "New Codex Chat", "New Gemini Chat", "New Gemini", "Other Agents ▸ New Kiro"] {
            check(titles.contains(t), "menu has “\(t)”")
        }
        for agent in ws.customAgents {
            check(titles.contains("New \(agent.displayName)") && titles.contains("Shell in \(agent.displayName) Sandbox"),
                  "menu offers the custom agent \(agent.displayName)")
        }

        // 3. Codex + Gemini over ACP.
        for agent in [AgentKind.codex, .gemini] {
            guard let container = await ws.ensureContainerReady(for: agent) else {
                check(false, "\(agent.rawValue) sandbox comes up (\(ws.lastError ?? "?"))")
                continue
            }
            log("\(agent.rawValue) sandbox: \(container)")
            await handshake(agent, container: container, workdir: ws.rootURL.path, home: ws.home.path)

            guard let s = ws.newChatInCurrentContext(agent: agent) else { check(false, "new \(agent.rawValue) chat"); continue }
            check(s.agent == agent && s.isChat && s.containerAgentKind == agent, "\(agent.displayName) chat session runs in its own sandbox")
            func chat() -> ChatSession? { tree.surfaces.chats[s.id]?.session }
            let service = ChatSession.credentialService(for: agent) ?? ""
            let hasCreds = await SbxClient.shared.hasServiceSecret(service, sandbox: container)
            if hasCreds {
                check(await until(300) { chat()?.phase == .ready }, "\(agent.displayName) chat reaches ready")
                guard let c = chat(), c.phase == .ready else { continue }
                c.send(text: "Reply with exactly the word PONG and nothing else.", attachments: [])
                check(await until(180) {
                    c.phase == .ready && c.items.contains { if case .agentText(_, let t) = $0 { t.contains("PONG") } else { false } }
                }, "\(agent.displayName) prompt round trip")
            } else {
                log("no \(service) secret: expecting the credential error")
                check(await until(120) { if case .closed = chat()?.phase { true } else { false } },
                      "\(agent.displayName) chat stops instead of hanging")
                let notices: [String] = chat()?.items.compactMap { item -> String? in
                    if case .notice(_, let t, true) = item { return t } else { return nil }
                } ?? []
                log("\(agent.rawValue) chat: \(String(describing: chat()?.phase)) — \(notices.first ?? "-")")
                check(notices.contains { $0.contains("sbx secret set \(service)") }, "\(agent.displayName) chat says how to add a credential")
            }
            ws.selection = .session(s.id)
            await wait(1)
            snapshot(window, "chat-\(agent.rawValue)")
        }
    }

    /// Initialize + session/new against `agent`'s ACP entry point, with the
    /// same argv the chat uses.
    private static func handshake(_ agent: AgentKind, container: String, workdir: String, home: String) async {
        guard let args = SbxCommand.acpArguments(agent: agent, containerName: container, workdir: workdir,
                                                 home: home, mcpURL: nil) else {
            return check(false, "\(agent.rawValue) has an ACP launch")
        }
        let conn = ACPConnection(executable: PathFixer.sbxPath(), arguments: args)
        let drain = Task {
            for await event in conn.incoming {
                if case .stderr(let line) = event { Log.info(.sbx, "selftest[\(agent.rawValue)]: \(line)") }
            }
        }
        defer { conn.terminate(); drain.cancel() }
        do { try conn.start() } catch { return check(false, "\(agent.rawValue) adapter launches: \(error)") }
        let started = Date()
        do {
            let initResult = try await withTimeout(300) {
                try await conn.request("initialize", [
                    "protocolVersion": 1,
                    "clientCapabilities": ["fs": ["readTextFile": false, "writeTextFile": false], "terminal": false],
                ])
            }
            let info = initResult["agentInfo"]
            log(String(format: "\(agent.rawValue) initialize in %.1fs: %@ %@ · auth methods %@", Date().timeIntervalSince(started),
                       info?["name"]?.string ?? "?", info?["version"]?.string ?? "?",
                       (initResult["authMethods"]?.array ?? []).compactMap { $0["id"]?.string }.joined(separator: ",")))
            check(initResult["protocolVersion"]?.int == 1, "\(agent.rawValue) ACP initialize")
        } catch {
            return check(false, "\(agent.rawValue) ACP initialize: \(error.localizedDescription)")
        }
        do {
            let new = try await withTimeout(120) {
                try await conn.request("session/new", ["cwd": .string(workdir), "mcpServers": []])
            }
            let models = (new["models"]?["availableModels"]?.array ?? []).compactMap { $0["modelId"]?.string }
            let modes = (new["modes"]?["availableModes"]?.array ?? []).compactMap { $0["id"]?.string }
            log("\(agent.rawValue) session/new: \(new["sessionId"]?.string ?? "-") models [\(models.joined(separator: ","))] modes [\(modes.joined(separator: ","))]")
            check(new["sessionId"]?.string != nil, "\(agent.rawValue) session/new returns a session")
        } catch {
            // Without a credential, codex-acp answers session/new with ACP's auth error.
            log("\(agent.rawValue) session/new: \(error.localizedDescription)")
            check(ChatSession.isAuthRequired(error), "\(agent.rawValue) session/new: auth-required error (no credential)")
        }
    }

    private struct Timeout: Error {}

    private static func withTimeout<T: Sendable>(_ seconds: Double, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask { try await Task.sleep(for: .seconds(seconds)); throw Timeout() }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }
    }

    /// Render the Agents inspector pane offscreen to a PNG.
    private static func renderAgentsPane(_ ws: WorkspaceController) {
        let model = AgentConfigModel(enabled: ws.customAgents, apply: { _ in })
        let host = NSHostingView(rootView: AgentConfigView(model: model))
        host.frame = NSRect(x: 0, y: 0, width: InspectorMetrics.paneWidth, height: InspectorMetrics.paneHeight)
        let w = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        w.alphaValue = 0
        w.ignoresMouseEvents = true
        w.contentView = host
        w.orderBack(nil)
        host.layoutSubtreeIfNeeded()
        if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out + "/agents-pane.png"))
            log("snapshot agents-pane.png")
        }
        w.orderOut(nil)
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

    // MARK: Files in a pane

    private static func snapshot(_ view: NSView, _ name: String) {
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out + "/\(name).png"))
        log("snapshot \(name).png")
    }

    private static func git(_ repo: URL, _ args: String...) -> String {
        GitStatus.git(["-C", repo.path] + args) ?? "<git failed>"
    }

    /// Needs a workspace that is a git repo with README.md (headings, prose,
    /// a fenced code block) and a committed src/app.py modified in two places,
    /// plus one shell session.
    private static func files(_ window: MainWindowController) async {
        guard let tree = window.paneTree, let ws = window.workspaceController else { return log("no window") }
        guard let a = ws.orderedSessions.first?.id else { return log("need a session") }
        let repo = ws.rootURL
        ws.selection = .session(a)
        check(await until(90) { tree.surfaces.terminals[a] != nil }, "session launches in the only pane")

        window.openFilesInSplit()
        await wait()
        check(tree.panes.count == 2 && tree.panes[0].shownSession == a && tree.panes[1].shownFiles?.session == a,
              "Open Files in Split puts Files for the session beside it")
        check(tree.focused === tree.panes[1], "the Files pane is focused")
        guard let files = tree.panes[1].filesPane else { return log("no Files surface") }
        check(await until(10) { files.tree.git.repoRoot != nil }, "Files pane sees the git repo")
        check(files.tree.root?.standardizedFileURL.path == repo.standardizedFileURL.path, "Files root is the session's folder")

        window.openFilesInSplit()
        await wait()
        check(tree.panes.count == 2, "opening the same Files again focuses it instead of duplicating")

        // Picking a session while Files is focused leaves the Files pane in place.
        ws.selection = nil
        ws.selection = .session(a)
        await wait()
        check(tree.panes[1].shownFiles != nil && tree.focused === tree.panes[0], "sidebar pick focuses the session pane, Files stays")

        // Markdown preview: serif prose, monospaced code.
        files.open(repo.appendingPathComponent("README.md"))
        await wait(0.8)
        if let text = files.editor.previewText, text.length > 0 {
            let s = text.string as NSString
            func font(at needle: String) -> NSFont? {
                let r = s.range(of: needle)
                return r.location == NSNotFound ? nil : text.attribute(.font, at: r.location, effectiveRange: nil) as? NSFont
            }
            let prose = font(at: "Sandshell keeps")
            let code = font(at: "print(")
            let heading = font(at: "Scratch Notes")
            log("prose font: \(prose?.fontName ?? "nil") · heading: \(heading?.fontName ?? "nil") · code: \(code?.fontName ?? "nil")")
            func isSerif(_ f: NSFont?) -> Bool {
                guard let f else { return false }
                let name = f.fontName.lowercased()
                return name.contains("newyork") || name.contains("serif") || (f.familyName ?? "").contains("New York")
            }
            check(isSerif(prose) && isSerif(heading), "Markdown prose and headings render in New York")
            check(code?.isFixedPitch == true, "Markdown code stays monospaced")
        } else {
            check(false, "Markdown preview rendered")
        }
        await wait(0.4)
        snapshot(window, "files-split")
        snapshot(files.view, "files-markdown")

        // Open Quickly finds and opens src/app.py.
        files.openQuickly(nil)
        await wait(0.6)
        if let finder = files.openQuicklyController {
            _ = await until(5) { finder.search("apy"); return !finder.results.isEmpty }
            check(finder.results.first == "src/app.py", "Open Quickly: “apy” finds src/app.py first (got \(finder.results.prefix(3)))")
            snapshot(finder.view, "files-open-quickly")
            finder.openSelected()
            await wait()
            check(files.editor.currentURL?.lastPathComponent == "app.py", "Open Quickly opens the file")
        } else {
            check(false, "Open Quickly popover shown")
        }

        // Go to Line.
        files.editor.goToLineForTesting(7)
        check(files.editor.caretLineForTesting == 7, "Go to Line moves the caret to line 7")

        // Changes view: two unstaged hunks → stage one → unstage → revert one.
        files.editor.setMode(.changes)
        check(await until(5) { files.editor.hunkCounts.map { $0 == (2, 0) } ?? false },
              "Changes view shows 2 unstaged hunks (got \(String(describing: files.editor.hunkCounts)))")
        snapshot(files.view, "files-changes")
        var error = await files.editor.performHunkAction(.stage, hunk: 0, staged: false)
        check(error == nil, "stage hunk 1 \(error ?? "")")
        check(await until(5) { files.editor.hunkCounts.map { $0 == (1, 1) } ?? false }, "after staging: 1 unstaged, 1 staged")
        check(git(repo, "diff", "--cached", "--numstat").contains("src/app.py"), "the hunk is in the index")
        snapshot(files.view, "files-changes-staged")
        error = await files.editor.performHunkAction(.unstage, hunk: 0, staged: true)
        check(error == nil, "unstage it \(error ?? "")")
        check(await until(5) { files.editor.hunkCounts.map { $0 == (2, 0) } ?? false }, "after unstaging: 2 unstaged again")
        let before = (try? String(contentsOf: repo.appendingPathComponent("src/app.py"), encoding: .utf8)) ?? ""
        error = await files.editor.performHunkAction(.revert, hunk: 1, staged: false)
        check(error == nil, "revert hunk 2 \(error ?? "")")
        let after = (try? String(contentsOf: repo.appendingPathComponent("src/app.py"), encoding: .utf8)) ?? ""
        check(before.contains("CHANGED-TAIL") && !after.contains("CHANGED-TAIL") && after.contains("CHANGED-HEAD"),
              "revert removed only the second hunk from the file")
        check(await until(5) { files.editor.hunkCounts.map { $0 == (1, 0) } ?? false }, "after revert: 1 unstaged hunk")

        // Equalize, then the layout (with its Files pane) is saved.
        window.equalizePanes()
        await wait(1.2)
        let key = "paneLayout:" + ws.rootURL.standardizedFileURL.path
        let saved = UserDefaults.standard.data(forKey: key).map { String(decoding: $0, as: UTF8.self) } ?? ""
        log("saved layout: \(saved)")
        check(saved.contains("\"files\"") && saved.contains(a.uuidString), "layout saved with the Files pane")
    }

    /// Second launch after `files`: the Files pane comes back beside the session.
    private static func filesRelaunch(_ window: MainWindowController) async {
        guard let tree = window.paneTree, let ws = window.workspaceController else { return log("no window") }
        await wait(1.0)
        check(tree.panes.count == 2, "two panes restored (got \(tree.panes.count))")
        let filesPane = tree.panes.first { $0.shownFiles != nil }
        check(filesPane != nil && tree.panes.contains { $0.shownSession != nil }, "a session pane and a Files pane restored")
        if let files = filesPane?.filesPane {
            check(files.tree.root?.standardizedFileURL.path == ws.rootURL.standardizedFileURL.path, "restored Files shows the session's folder")
        }
        await wait(1.5)
        snapshot(window, "files-relaunch")
    }

    // MARK: Kits

    /// Kit add + drift against a real sandbox. Needs `-SandshellSelfTestKits
    /// '("<a>","<b>","<c>","<d>","<e>")'`: five local mixin kit dirs, where the
    /// workspace config starts with [a], and d declares `files` (which
    /// `sbx kit add` refuses, forcing the rebuild fallback).
    private static func kits(_ window: MainWindowController) async {
        guard let ws = window.workspaceController else { return log("no window") }
        let refs = UserDefaults.standard.stringArray(forKey: "SandshellSelfTestKits") ?? []
        guard refs.count == 5 else { return log("need 5 kit dirs in -SandshellSelfTestKits, have \(refs.count)") }
        let (a, b, c, d, e) = (refs[0], refs[1], refs[2], refs[3], refs[4])
        let agent = ws.primaryAgent
        let name = ws.containerName(for: agent)
        let stateFile = ws.rootURL.appendingPathComponent(".sandshell/state.json")
        func actualKits() async -> [String] { await SbxClient.shared.inspect(name)?.kits ?? [] }
        func sandboxID() async -> String? { try? await SbxClient.shared.status(name: name)?.id }
        func settle() async -> Bool { await until(300) { !ws.busy && !ws.isBuilding } }

        check(await until(300) { ws.containerPhases[agent] == .running && !ws.busy }, "container '\(name)' comes up")
        check(await actualKits() == [a], "sbx inspect reports the configured kit [a]")
        ws.refreshKitDrift(for: agent)
        await wait(3)
        check(ws.kitDrift[agent] == nil, "no drift right after create")

        // Hand-run `sbx kit add` behind Sandshell's back → drift → adopt.
        let handB = try? await SbxClient.shared.kitAdd(sandbox: name, ref: b, cwd: ws.rootURL.path, mcpURL: ws.mcpURL)
        check(handB?.ok == true, "hand-run sbx kit add b succeeds")
        ws.refreshKitDrift(for: agent)
        check(await until(30) { ws.kitDrift[agent]?.extra == [b] }, "drift reports b as extra")
        log("drift: \(String(describing: ws.kitDrift[agent]))")
        await wait(0.8)
        snapshot(window, "kits-drift-banner")
        renderKitsPane(drift: ws.kitDrift[agent], enabled: [a])

        ws.adoptKitDrift(for: agent)
        check(ws.kits == [a, b], "adopt adds b to the workspace config")
        await wait(3)
        check(ws.kitDrift[agent] == nil, "no drift after adopting")

        // Hand-add c → drop on next rebuild (persisted ignore).
        _ = try? await SbxClient.shared.kitAdd(sandbox: name, ref: c, cwd: ws.rootURL.path, mcpURL: ws.mcpURL)
        ws.refreshKitDrift(for: agent)
        check(await until(30) { ws.kitDrift[agent]?.extra == [c] }, "drift reports c as extra")
        ws.ignoreKitDrift(for: agent)
        ws.refreshKitDrift(for: agent)
        await wait(3)
        check(ws.kitDrift[agent] == nil, "ignored drift stays hidden after a re-check")
        let stateText = (try? String(contentsOf: stateFile, encoding: .utf8)) ?? ""
        check(stateText.contains("ignoredKitDrift"), "ignored drift persisted to state.json")

        // Additions only → sbx kit add in place (same sandbox id, nothing rebuilt).
        let idBefore = await sandboxID()
        ws.applyKits([a, b, e])
        check(await settle(), "kit-add apply finishes")
        let afterAdd = await actualKits()
        log("kits after apply [a,b,e]: \(afterAdd)")
        check(afterAdd == [a, b, c, e], "e appended in place; hand-added c still there")
        check(await sandboxID() == idBefore && idBefore != nil, "same sandbox id → kit add path, not a rebuild")
        check(ws.containerPhases[agent] == .running, "container running after kit add")

        // A kit sbx refuses to add in place → full rebuild fallback.
        ws.applyKits([a, b, e, d])
        check(await settle(), "refused kit add apply finishes")
        let afterRefusal = await actualKits()
        log("kits after apply [a,b,e,d]: \(afterRefusal)")
        check(afterRefusal == [a, b, e, d], "rebuild applied the config's kits (ignored c dropped)")
        check(await sandboxID() != idBefore, "new sandbox id → fell back to a rebuild")
        let stateAfter = (try? String(contentsOf: stateFile, encoding: .utf8)) ?? ""
        check(!stateAfter.contains("ignoredKitDrift"), "ignored drift cleared by the rebuild")
        ws.refreshKitDrift(for: agent)
        await wait(3)
        check(ws.kitDrift[agent] == nil, "no drift after the rebuild")
        await wait(1)
        snapshot(window, "kits-final")
    }

    /// Render the Settings ▸ Kits pane offscreen with a drift section.
    private static func renderKitsPane(drift: KitDrift?, enabled: [String]) {
        let view = NSHostingView(rootView: KitConfigView(
            model: KitConfigModel(enabledRefs: enabled), onRebuild: {},
            drift: drift, onAdoptDrift: {}, onIgnoreDrift: {}))
        view.frame = NSRect(x: 0, y: 0, width: InspectorMetrics.paneWidth, height: InspectorMetrics.paneHeight)
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out + "/kits-pane-drift.png"))
        log("snapshot kits-pane-drift.png")
    }
}
#endif
