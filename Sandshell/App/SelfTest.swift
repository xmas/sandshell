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
            // AX only lists windows on the current Space; follow the user's,
            // full-screen apps' Spaces included.
            w.collectionBehavior.formUnion([.canJoinAllSpaces, .fullScreenAuxiliary])
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
        guard let scenario = requested, !["files-relaunch", "files-alone"].contains(scenario) else { return }
        let defaults = UserDefaults.standard
        // The inspector starts closed, the sidebar and inspector at their default widths.
        for key in defaults.dictionaryRepresentation().keys
        where key.hasPrefix("filesPaneVisible") || key.hasPrefix("NSSplitView Subview Frames MainSplit")
            || key.hasPrefix("filesTabs:") || key.hasPrefix("filesExpanded:")
            || ["sessionDetailsShown", "inspectorCardOrder", "inspectorCollapsedCards"].contains(key) {
            defaults.removeObject(forKey: key)
        }
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("paneLayout:") {
            defaults.removeObject(forKey: key)
        }
    }
    private static var out: String { UserDefaults.standard.string(forKey: "SandshellSelfTestOut") ?? NSTemporaryDirectory() }
    private static var lines: [String] = []
    private static var failures = 0

    static func run(_ window: MainWindowController) async {
        setvbuf(stdout, nil, _IOLBF, 0)   // run.log shows progress even if the run is killed
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
        case "bootstrap": await bootstrap(window)
        case "background": await background(window)
        case "pane-buttons": await paneButtons(window)
        case "files-alone": await filesAlone(window)
        case "two-windows": await twoWindows(window)
        case "question": await agentQuestion(window)
        case "mac": await macBehaviors(window)
        case "subagents": await subagentRows(window)
        case "details": await sessionDetails(window)
        case "clone": await cloneMode(window)
        case "sandbox-access": await sandboxAccess(window)
        case "launch-failure": await launchFailure(window)
        case "fork": await fork(window)
        case "links": links()
        case "tool-groups": await toolGroups()
        case "tables": await tables()
        case "codex-chat": await codexChat(window)
        case "commits": await commitsView(window)
        case "warm": await warmChats(window)
        case "extras": await chatExtras(window)
        case "kit-extras": await kitExtras(window)
        case "queue": await queueWhileWorking(window)
        case "sea": await sea(window)
        case "title-strip": await titleStrip(window)
        case "follow": await follow(window)
        case "reconnect": await reconnect(window)
        case "chat-model": await chatModel(window)
        case "kit-agents": await kitAgents(window)
        case "paste": await paste(window)
        case "open-quickly": await openQuickly()
        case "files": await files(window)
        case "files-relaunch": await filesRelaunch(window)
        case "kits": await kits(window)
        case "agents": await agents(window)
        case "search": await search(window)
        default: check(false, "unknown self-test \(requested ?? "")")
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
        snapshot(window.window, name)
    }

    private static func snapshot(_ window: NSWindow?, _ name: String) {
        guard let view = window?.contentView else { return }
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
        /// Whether the keys are in `id`'s terminal (they go with the focus ring).
        func keysIn(_ id: UUID) -> Bool {
            guard let held = window.window?.firstResponder as? NSView, let v = tree.surfaces.terminals[id]?.view else { return false }
            return held.isDescendant(of: v)
        }

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
        check(keysIn(b), "the keys go with B to its new pane")

        tree.closeFocused()
        await wait()
        check(tree.panes.count == 3 && live(b), "Close Pane keeps the session running")
        check(tree.focused.shownSession == a && keysIn(a), "Close Pane hands the keys to the pane now focused (A)")

        window.equalizePanes()
        await wait()
        check(keysIn(a), "Equalize Panes leaves the keys in A's terminal")
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
        check(focusedIndex() == 1 && !keysIn(a), "Next Pane moves focus, and the keys leave A")
        window.focusPreviousPane()
        await wait()
        check(focusedIndex() == 0 && keysIn(a), "Previous Pane brings focus and the keys back to A")

        // Layout persists (saved asynchronously).
        await wait(1.0)
        let key = tree.layoutKey
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
        if await until(120, { session()?.phase == .starting }), let view = tree.surfaces.chats[s.id] {
            check(!view.debugComposerEnabled, "no typing while the agent starts")
        }
        check(await until(600) { session()?.phase == .ready }, "chat reaches ready (sandbox + adapter up)")
        guard let chat = session(), chat.phase == .ready else { return log("chat phase: \(String(describing: session()?.phase))") }
        check(tree.surfaces.chats[s.id]?.debugComposerEnabled == true, "the composer opens once it's ready")
        log("modes: \(chat.modes.map(\.id))")
        check(!chat.modes.contains { $0.id == "auto" } || chat.currentMode == "auto", "a new chat starts in Auto mode")
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
        // Chat is the default; terminal versions sit under In Terminal.
        for t in ["New Claude", "New Codex", "New Gemini", "In Terminal ▸ New Claude in Terminal",
                  "Other Agents ▸ New Kiro"] {
            check(titles.contains(t), "menu has “\(t)”")
        }
        for agent in ws.customAgents {
            check(titles.contains("New \(agent.displayName)") && titles.contains("Shell in \(agent.displayName) Sandbox"),
                  "menu offers the custom agent \(agent.displayName)")
        }

        // 2b. An agent kit added under Kits goes to the agent registry, not `--kit`.
        if let kit = defaults.string(forKey: "SandshellSelfTestKit") {
            let kits = KitConfigModel(enabledRefs: [])
            var handed: AgentProfile?
            kits.onAgentKit = { handed = $0 }
            kits.add(kit)
            check(await until(30) { kits.notice != nil }, "the Kits pane reads the added kit")
            check(handed?.kitRef == kit && !kits.isRegistered(kit) && !kits.enabledRefs.contains(kit),
                  "an agent kit added under Kits becomes an agent (\(kits.notice ?? "-"))")
        }

        // 2c. A pristine session named before brand spellings is reused, renamed.
        if let folder = ws.folders.first?.id,
           let old = ws.addSession(folderID: folder, agent: .dockerAgent, name: "New Docker-Agent Session") {
            let again = ws.addSession(folderID: folder, agent: .dockerAgent)
            check(again?.id == old.id && again?.name == "New Docker Agent Session",
                  "an old blank “New Docker-Agent Session” is reused (\(again?.name ?? "-"))")
            ws.closeSession(old.id)
        }

        // 2d. Rebuilding an unregistered kit agent's sandbox refuses before taking it down.
        let orphan = try! JSONDecoder().decode(Sandbox.self, from: Data(
            #"{"name":"sandshell-selftest-no-such-sandbox","agent":"never-registered-agent","status":"running"}"#.utf8))
        do {
            _ = try await SbxClient.shared.rebuildSandbox(orphan)
            check(false, "rebuilding an unregistered kit agent fails")
        } catch {
            check(error.localizedDescription.contains("isn’t registered"),
                  "rebuilding an unregistered kit agent says why (\(error.localizedDescription.prefix(80)))")
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
                check(ws.runtime(s.id)?.stoppedReason != nil, "\(agent.displayName) chat's row says Stopped, not Ready")
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
        await wait(0.5)
        check(window.sidebarList?.emptyStateText == nil,
              "with a row in the list, the build placeholder stays off it (\(window.sidebarList?.emptyStateText ?? "hidden"))")
        // A new session is a chat (the default) or a terminal: either one up.
        let ok = await until(300) { tree.surfaces.terminals[s.id] != nil || tree.surfaces.chats[s.id]?.session.phase == .ready }
        log("building=\(ws.isBuilding) activity=\(ws.activity ?? "nil") pending=\(tree.surfaces.pending.contains(s.id)) "
            + "shown=\(tree.panes.map { $0.shownSession == s.id }) error=\(ws.lastError ?? "nil")")
        check(ok, "the session launches once the sandbox is up")
        snapshot(window, "building-final")
    }

    // MARK: Bootstrap

    /// For the self-test runner: open a new workspace far enough that it has
    /// written its config.json (which the runner then edits), and quit.
    private static func bootstrap(_ window: MainWindowController) async {
        guard let ws = window.workspaceController else { return log("no window") }
        let config = ws.rootURL.appendingPathComponent(".sandshell/config.json")
        check(await until(60) { FileManager.default.fileExists(atPath: config.path) }, "the workspace has a config.json")
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
        let key = tree.layoutKey
        let saved = UserDefaults.standard.data(forKey: key).map { String(decoding: $0, as: UTF8.self) } ?? ""
        log("saved layout: \(saved)")
        check(saved.contains("\"files\"") && saved.contains(a.uuidString), "layout saved with the Files pane")

        // The trailing inspector runs under the toolbar: its filter must sit below it.
        window.toggleFiles()
        await wait(0.8)
        if let inspector = window.inspectorFiles, let w = window.window {
            let filter = inspector.tree.debugFilterFrameInWindow
            log("inspector filter \(filter), content layout \(w.contentLayoutRect)")
            check(filter.maxY <= w.contentLayoutRect.maxY + 1, "the inspector's filter sits below the toolbar")
            snapshot(window, "files-inspector")
        }
        window.toggleFiles()

        // Content search finds a file with an accented name, by its real path.
        let accented = repo.appendingPathComponent("Café notes.md")
        try? "zanzibar-needle\n".write(to: accented, atomically: true, encoding: .utf8)
        files.tree.debugContentSearch("zanzibar-needle")
        check(await until(10) { files.tree.debugSearchFiles == ["Café notes.md"] },
              "content search: an accented name comes back as itself (\(files.tree.debugSearchFiles))")
        check(files.tree.debugSearchURLs.first.map { FileManager.default.fileExists(atPath: $0.path) } == true,
              "content search: the match opens the real file")
        files.tree.debugClearFilter()
        try? FileManager.default.removeItem(at: accented)

        // Typing isn't reset by a changed-files refresh (another file changing).
        let typed = repo.appendingPathComponent("src/typing.txt")
        try? "line one\nline two\n".write(to: typed, atomically: true, encoding: .utf8)
        files.open(typed)
        await wait(0.5)
        files.editor.debugType("XY", at: 4)
        let caret = files.editor.debugCaret
        files.editor.setScope(.uncommitted, files: ["/elsewhere/\(UUID().uuidString)"])
        await wait(0.3)
        check(files.editor.debugCaret == caret && files.editor.debugEditorText.hasPrefix("lineXY one"),
              "a changed-list refresh leaves the text and caret where you're typing (caret \(files.editor.debugCaret), was \(caret))")

        // Closing a dirty tab whose save fails keeps the tab (and the edits).
        let locked = repo.appendingPathComponent("locked")
        try? FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        let lockedFile = locked.appendingPathComponent("ro.txt")
        try? "keep me\n".write(to: lockedFile, atomically: true, encoding: .utf8)
        files.open(lockedFile)
        await wait(0.5)
        files.editor.debugType("edit ", at: 0)
        try? FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        files.editor.debugCloseCurrent()   // Save (answered by the automated run), which fails
        check(files.editor.openURLs.contains(lockedFile) && files.editor.debugIsDirty,
              "a tab whose save failed stays open with its edits")
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
        files.editor.debugCloseCurrent()   // now the save works
        check(!files.editor.openURLs.contains(lockedFile)
              && (try? String(contentsOf: lockedFile, encoding: .utf8)) == "edit keep me\n", "then it saves and closes")
        try? FileManager.default.removeItem(at: locked)
        try? FileManager.default.removeItem(at: typed)
    }

    /// Clone mode (`sbx create --clone`): the sandbox works on a private clone
    /// of the repo, a commit made in it comes back through the
    /// `sandbox-<name>` remote, and Session Details sees it. Fixture: `clone`
    /// (a repo whose sandboxes the runner removed).
    private static func cloneMode(_ window: MainWindowController) async {
        guard let tree = window.paneTree, let ws = window.workspaceController else { return log("no window") }
        guard let a = ws.orderedSessions.first else { return log("need a session") }
        let root = ws.rootURL
        check(ws.isGitRepository, "the folder is a git repo")
        ws.setCloneRepo(true)
        check(ws.workspace.cloneRepo, "clone mode is on")
        ws.selection = .session(a.id)
        check(await until(900) { tree.surfaces.terminals[a.id] != nil }, "a session starts in a clone-mode sandbox")
        let name = ws.containerName(for: a.containerAgentKind)
        let remotes = GitStatus.git(["-C", root.path, "remote"]) ?? ""
        log("remotes: \(remotes.split(separator: "\n"))")
        check(remotes.split(separator: "\n").contains { $0 == "sandbox-\(name)" }, "sbx added the sandbox-\(name) remote")
        // Where the agent works, and a commit made there.
        let probe = await SbxClient.shared.exec(inSandbox: name, script: "cd '\(root.path)' && pwd && git status -sb | head -1 && git remote -v | head -2") ?? "-"
        log("in the sandbox: \(probe)")
        let commit = await SbxClient.shared.exec(inSandbox: name, script:
            "cd '\(root.path)' && git -c user.name=Agent -c user.email=agent@sandbox -c commit.gpgsign=false commit -q --allow-empty -m 'from the agent' && git log --oneline -1") ?? "-"
        log("agent commit: \(commit)")
        check(commit.contains("from the agent"), "the agent commits in its clone")
        let hostLog = GitStatus.git(["-C", root.path, "log", "--oneline", "-1"]) ?? ""
        check(hostLog.contains("from the agent") == false, "the folder itself doesn't change")
        _ = GitStatus.git(["-C", root.path, "fetch", "sandbox-\(name)"])
        let facts = GitFacts.load(root, sandbox: name)
        log("clone facts: remote \(facts.sandboxRemote ?? "-"), ahead \(facts.sandboxAhead.map(String.init) ?? "-")")
        check(facts.sandboxRemote == "sandbox-\(name)" && facts.sandboxAhead == 1,
              "after a fetch, Session Details sees the agent's commit")
        ws.setCloneRepo(false)
    }

    /// Session Details beside a chat: shown with the setting on, its cards
    /// there, a workflow run (made on disk the way Claude Code writes one)
    /// opening in its window with phases and agents. Fixture: `chat`.
    private static func sessionDetails(_ window: MainWindowController) async {
        guard let tree = window.paneTree, let ws = window.workspaceController else { return log("no window") }
        if !SessionDetails.isShown { SessionDetails.toggle() }
        guard let s = ws.newChatInCurrentContext() else { return log("no folder to start a chat in") }
        func view() -> ChatSessionView? { tree.surfaces.chats[s.id] }
        check(await until(600) { view()?.session.phase == .ready }, "chat reaches ready")
        guard let v = view() else { return }
        await wait(1)
        check(v.isInspectorShown, "Session Details shows beside the chat")
        v.session.send(text: "Reply with exactly the word PONG and nothing else.", attachments: [])
        check(await until(180) { v.session.phase == .ready && v.session.usage != nil }, "a turn gives it usage to show")
        await wait(1)
        snapshot(window, "details")
        SessionDetails.toggle()
        await wait(0.5)
        check(v.isInspectorShown == false, "View ▸ Hide Session Details hides it")
        // A wide pane: the conversation reads in a centered column.
        if let w = window.window {
            let before = w.frame
            w.setFrame(NSRect(x: before.minX, y: before.minY, width: 1700, height: before.height), display: true)
            await wait(0.5)
            v.layoutSubtreeIfNeeded()
            let col = v.debugColumn
            log("column: window \(Int(w.frame.width)), pane \(Int(v.bounds.width)), composer x \(Int(col.composer.minX)) w \(Int(col.composer.width)), text inset \(Int(col.textInset))")
            check(col.composer.width <= ChatTranscriptView.readableWidth + 1
                  && abs(col.composer.midX - v.bounds.midX) < 2, "a wide pane centers the composer, at most the readable width")
            check(col.textInset == ChatTranscriptView.sideInset(forWidth: col.textWidth), "the transcript's text sits in the same column")
            // The window can't outgrow the screen: a transcript on its own, wider.
            let wide = ChatTranscriptView(frame: NSRect(x: 0, y: 0, width: 1600, height: 400))
            wide.layoutSubtreeIfNeeded()
            log("1600-wide transcript: text inset \(Int(wide.debugTextInset))")
            check(wide.debugTextInset >= 390, "a wide transcript centers its text in an 800-point column")
            w.setFrame(before, display: true)
            await wait(0.3)
        }
        SessionDetails.toggle()
        await wait(0.5)
        check(v.isInspectorShown, "and Show brings it back")

        // A workflow run as Claude Code writes it.
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("sandshell-wf-\(UUID().uuidString)")
        let transcript = tmp.appendingPathComponent("s1.jsonl")
        let runDir = tmp.appendingPathComponent("s1/subagents/workflows/wf_test-1")
        let scripts = tmp.appendingPathComponent("s1/workflows/scripts")
        try? FileManager.default.createDirectory(at: runDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        try? Data().write(to: transcript)
        try? """
        export const meta = {
          name: 'review-changes',
          description: 'Review the diff, then verify each finding',
          phases: [{ title: 'Review', detail: 'one reviewer per area' }, { title: "Verify", detail: "skeptics" }],
        }
        """.write(to: scripts.appendingPathComponent("review-changes-wf_test-1.js"), atomically: true, encoding: .utf8)
        let journal = [#"{"type":"launched"}"#,
                       #"{"type":"started","agentId":"a1","label":"review:ui","phase":"Review"}"#,
                       #"{"type":"started","agentId":"a2","label":"review:core","phase":"Review"}"#,
                       #"{"type":"result","agentId":"a1","result":"ok"}"#,
                       #"{"type":"started","agentId":"a3","label":"verify:1","phase":"Verify"}"#]
        try? (journal.joined(separator: "\n") + "\n").write(to: runDir.appendingPathComponent("journal.jsonl"), atomically: true, encoding: .utf8)
        for (id, tokens) in [("a1", 1200), ("a2", 3400), ("a3", 500)] {
            let lines = [#"{"type":"user","isSidechain":true,"timestamp":"2026-10-17T07:00:00.000Z","message":{"role":"user","content":"go"}}"#,
                         #"{"type":"assistant","isSidechain":true,"timestamp":"2026-10-17T07:01:30.000Z","message":{"id":"m","role":"assistant","model":"claude-opus-5-5","usage":{"input_tokens":\#(tokens),"output_tokens":0},"content":[{"type":"text","text":"done"}]}}"#]
            try? (lines.joined(separator: "\n") + "\n").write(to: runDir.appendingPathComponent("agent-\(id).jsonl"), atomically: true, encoding: .utf8)
        }
        let runs = WorkflowScanner.scan(transcript: transcript)
        check(runs.count == 1 && runs[0].name == "review-changes" && runs[0].phases.map(\.title) == ["Review", "Verify"],
              "a workflow run reads with its name and phases (\(runs.map(\.name)))")
        if let run = runs.first {
            check(run.progress(of: run.phases[0]) == (done: 1, total: 2) && run.totalTokens == 5100
                  && run.agents.first?.model == "claude-opus-5-5", "its agents: progress, tokens, model")
            WorkflowWindowController.show(run, sessionID: s.id, workspace: ws, stop: nil)
            await wait(1)
            let w = NSApp.windows.first { $0.title == "review-changes" }
            check(w?.isVisible == true, "the workflow opens in its window")
            if let w { w.alphaValue = 0.01; snapshot(w, "workflow-window"); w.close() }
        }
        try? FileManager.default.removeItem(at: tmp)
        ws.closeSession(s.id)
    }

    /// Subagents under their session: the scanner reads `<session>/subagents/`
    /// (meta + transcript), and a real Claude turn that runs one shows it as a
    /// row whose transcript opens read-only. Fixture: `chat`.
    private static func subagentRows(_ window: MainWindowController) async {
        // The scanner, on a made-up session folder.
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("sandshell-sub-\(UUID().uuidString)")
        let transcript = tmp.appendingPathComponent("s1.jsonl")
        let dir = tmp.appendingPathComponent("s1/subagents")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? Data().write(to: transcript)
        let lines = [
            #"{"type":"user","isSidechain":true,"agentId":"a1","message":{"role":"user","content":"Survey the code"}}"#,
            #"{"type":"assistant","isSidechain":true,"agentId":"a1","message":{"id":"m1","role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":"Found 3 files."}]}}"#,
        ]
        try? (lines.joined(separator: "\n") + "\n").write(to: dir.appendingPathComponent("agent-a1.jsonl"), atomically: true, encoding: .utf8)
        try? #"{"agentType":"Explore","description":"Survey the code"}"#.write(to: dir.appendingPathComponent("agent-a1.meta.json"), atomically: true, encoding: .utf8)
        let found = SubagentScanner.scan(sessionID: UUID(), transcript: transcript)
        check(found.count == 1 && found[0].title == "Survey the code" && found[0].agentType == "Explore" && found[0].state == .done,
              "scanner: a finished Explore subagent with its description (\(found.map(\.title)))")
        let items = found.first.map { SubagentScanner.items($0.transcript) } ?? []
        check(items.contains { if case .agentText(_, let t) = $0 { t == "Found 3 files." } else { false } }
              && items.contains { if case .user(_, let t, _) = $0 { t == "Survey the code" } else { false } },
              "its transcript reads as a conversation (sidechain lines included)")
        try? FileManager.default.removeItem(at: tmp)

        // A real one.
        guard let tree = window.paneTree, let ws = window.workspaceController, let sidebar = window.sidebarController
        else { return log("no window") }
        guard let s = ws.newChatInCurrentContext() else { return log("no folder to start a chat in") }
        func chat() -> ChatSession? { tree.surfaces.chats[s.id]?.session }
        check(await until(600) { chat()?.phase == .ready }, "chat reaches ready")
        guard let c = chat() else { return }
        c.send(text: "Use the Agent tool to start one Explore subagent with the description \"List the top-level files\" "
               + "that lists the files in the current folder. Then reply with exactly DONE.", attachments: [])
        check(await until(240) { !(ws.subagents[s.id] ?? []).isEmpty }, "the session's subagent is found")
        guard let info = ws.subagents[s.id]?.first else { return snapshot(window, "subagents-missing") }
        log("subagent: \(info.title) (\(info.agentType ?? "-")) \(info.state)")
        check(!info.title.isEmpty, "it has a title (\(info.title))")
        ws.selection = .session(s.id)
        await wait(1)
        check(sidebar.rows.contains(.subagent(info)) || sidebar.rows.contains { if case .subagent(let i) = $0 { i.id == info.id } else { false } },
              "it's a row under its session")
        snapshot(window, "subagents")
        check(await until(240) { c.phase == .ready && c.items.contains { if case .agentText(_, let t) = $0 { t.contains("DONE") } else { false } } },
              "the turn finishes")
        await ws.refreshSubagents()
        check(await until(60) { ws.subagents[s.id]?.first?.state == .done }, "and the subagent reads as done")
        SubagentWindowController.show(ws.subagents[s.id]?.first ?? info, workspace: ws)
        let viewer = SubagentWindowController.debugWindow(info.id)
        check(await until(10) { !(viewer?.debugTranscriptText.isEmpty ?? true) }, "its transcript opens read-only")
        viewer?.window?.close()
        // A workflow run beside it (made in this session's folder the way Claude Code writes one).
        let runDir = info.transcript.deletingLastPathComponent().appendingPathComponent("workflows/wf_selftest-1")
        try? FileManager.default.createDirectory(at: runDir, withIntermediateDirectories: true)
        try? (#"{"type":"started","agentId":"w1","label":"scan:a","phase":"Scan"}"# + "\n")
            .write(to: runDir.appendingPathComponent("journal.jsonl"), atomically: true, encoding: .utf8)
        try? (#"{"type":"user","isSidechain":true,"timestamp":"2026-10-17T07:00:00.000Z","message":{"role":"user","content":"go"}}"# + "\n")
            .write(to: runDir.appendingPathComponent("agent-w1.jsonl"), atomically: true, encoding: .utf8)
        await ws.refreshSubagents()
        check(ws.workflows[s.id]?.contains { $0.id == "wf_selftest-1" } == true, "a workflow run in the session's folder is found")
        sidebar.setShowsSubagents(true, of: s.id)
        check(sidebar.rows.contains { if case .workflow(_, let run) = $0 { run.id == "wf_selftest-1" } else { false } },
              "it's a row under its session, beside the subagent")
        snapshot(window, "subagents-workflow")
        try? FileManager.default.removeItem(at: runDir)
        await ws.refreshSubagents()
        // Collapsing hides it; expanding shows it again.
        sidebar.setShowsSubagents(false, of: s.id)
        check(!sidebar.rows.contains { if case .subagent = $0 { true } else { false } }, "collapsing hides the subagents")
        sidebar.setShowsSubagents(true, of: s.id)
        check(sidebar.rows.contains { if case .subagent = $0 { true } else { false } }, "expanding shows them")
        ws.closeSession(s.id)
    }

    /// Mac conventions (the Mac-arsed audit): the menu bar's commands and their
    /// validation, undoable close / rename, Reopen Closed Session, the sidebar's
    /// multi-selection, copy, live filter and inline rename, Files' copy, file
    /// operations with undo, tabs and expansion remembered, the Settings window.
    /// Fixture: `files` (two shell sessions in a git repo). Copies go to a
    /// private pasteboard (never the person's clipboard).
    private static func macBehaviors(_ window: MainWindowController) async {
        guard let ws = window.workspaceController, let app = NSApp.delegate as? AppDelegate,
              let sidebar = window.sidebarController, let w = window.window, let undo = w.undoManager
        else { return log("no window") }
        let sessions = ws.orderedSessions
        guard sessions.count >= 2 else { return check(false, "the fixture has two sessions") }
        let (a, b) = (sessions[0], sessions[1])
        let pb = NSPasteboard(name: .init("sandshell-selftest-\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }

        // The menu bar: the commands are there, with their shortcuts; no dead items.
        let shortcuts = ShortcutsWindowController.collect()
        func has(_ title: String, _ keys: String) -> Bool { shortcuts.contains { $0.title == title && $0.keys == keys } }
        check(has("Stop", "⌘.") && has("Restart", "⌘R") && has("Reopen Closed Session", "⇧⌘T")
              && has("Filter Sessions", "⌥⌘F") && has("Print…", "⌘P") && has("Keyboard Shortcuts", "⌥⌘/"),
              "the menu bar has Session, File and Help commands with their shortcuts")
        check(!shortcuts.contains { $0.title == "Show Tab Bar" || $0.title == "Move Tab to New Window" },
              "no tab commands in a window that doesn't tab")
        let menuTitles = (NSApp.mainMenu?.items ?? []).compactMap { $0.submenu?.title }
        check(menuTitles.contains("Session") && menuTitles.contains("Help"), "a Session menu (\(menuTitles))")
        func validate(_ action: Selector) -> NSMenuItem {
            let item = NSMenuItem("", action: action)
            _ = app.validateMenuItem(item)
            return item
        }
        ws.selection = .session(a.id)
        await wait(0.5)
        check(validate(#selector(AppDelegate.closeSessionOrWindow(_:))).title == "Close Session", "⌘W says Close Session")
        let filesTitle = validate(#selector(AppDelegate.toggleFiles(_:))).title
        check(filesTitle == (window.isFilesShown ? "Hide Files" : "Show Files"), "View says what Files will do (\(filesTitle))")
        check(validate(#selector(AppDelegate.toggleSessionSidebar(_:))).title == "Hide Sidebar", "and the sidebar")

        // Close is undoable; Reopen Closed Session brings back the last one.
        ws.closeSession(a.id)
        check(ws.session(id: a.id) == nil && undo.canUndo && undo.undoActionName == "Close Session", "closing offers Undo Close Session")
        undo.undo()
        check(ws.session(id: a.id) != nil, "Undo brings the session back")
        ws.closeSession(b.id)
        check(window.canReopenClosedSession, "Reopen Closed Session is available")
        window.reopenClosedSession()
        check(ws.session(id: b.id) != nil && ws.selection == .session(b.id), "Reopen Closed Session brings it back, selected")

        // Rename: it sticks (prompts no longer rename it) and undoes.
        ws.renameSession(a.id, to: "Release checklist")
        ws.autoName(a.id, from: "some later prompt")
        check(ws.session(id: a.id)?.name == "Release checklist" && ws.session(id: a.id)?.isNamedByUser == true,
              "a renamed session keeps its name")
        undo.undo()
        check(ws.session(id: a.id)?.name == a.name && ws.session(id: a.id)?.isNamedByUser == false, "Undo Rename")
        // Inline, from the row.
        await wait(0.3)
        sidebar.beginRename(a.id)
        if let cell = sidebar.debugCell(a.id) {
            cell.debugFinishRenaming("Renamed inline")
            check(ws.session(id: a.id)?.name == "Renamed inline", "renaming in the row")
        } else { check(false, "the row's cell") }
        ws.renameSession(a.id, to: "")   // back to automatic naming

        // The sidebar: two selected → copy has both, one undo closes and restores both.
        await wait(0.3)
        sidebar.debugSelect([a.id, b.id])
        check(sidebar.selectedSessionIDs.count == 2, "the sidebar selects two sessions")
        sidebar.writeSelection(to: pb)
        let copied = pb.string(forType: .string) ?? ""
        check(copied.split(separator: "\n").count == 2 && copied.contains(a.workdir), "⌘C copies both (\(copied))")
        sidebar.closeSelectedSession()
        check(ws.session(id: a.id) == nil && ws.session(id: b.id) == nil && undo.undoActionName == "Close Sessions",
              "Delete closes the whole selection")
        undo.undo()
        check(ws.session(id: a.id) != nil && ws.session(id: b.id) != nil, "one Undo brings both back")
        // Live filter.
        sidebar.debugFilter(String(b.name.prefix(7)))
        await wait(0.3)
        check(sidebar.displayedSessionIDs == [b.id] || sidebar.displayedSessionIDs.contains(b.id) && !sidebar.displayedSessionIDs.contains(a.id),
              "the filter narrows as you type (\(sidebar.displayedSessionIDs.count))")
        sidebar.debugFilter("")
        await wait(0.3)
        check(sidebar.displayedSessionIDs.count == ws.orderedSessions.count, "clearing it shows them all")

        // Files: copy, new file, rename, duplicate, trash — each undoable.
        window.toggleFiles()
        await wait(1)
        guard let files = window.inspectorFiles else { return check(false, "the Files inspector") }
        check(await until(10) { files.tree.root != nil }, "Files has a root")
        let repo = files.tree.root!
        let readme = repo.appendingPathComponent("README.md")
        files.tree.debugSelect([readme])
        files.tree.writeSelection(to: pb)
        let fileURLs = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        check(fileURLs.map(\.path) == [readme.path] && pb.string(forType: .string) == readme.path,
              "⌘C in Files copies the file (for Finder) and its path")
        let made = FileTreeController.unique("untitled.txt", in: repo)
        try? Data().write(to: made)
        let renamed = repo.appendingPathComponent("notes-\(UUID().uuidString.prefix(4)).txt")
        files.open(made)
        await wait(0.3)
        files.tree.debugRefresh()
        check(files.tree.move(made, to: renamed, action: "Rename"), "rename a file")
        check(FileManager.default.fileExists(atPath: renamed.path) && files.editor.openURLs.contains(renamed),
              "renamed on disk, and its open tab follows")
        undo.undo()
        check(FileManager.default.fileExists(atPath: made.path) && !FileManager.default.fileExists(atPath: renamed.path),
              "Undo Rename puts the old name back")
        files.tree.duplicate([made])
        let copy = repo.appendingPathComponent("untitled copy.txt")
        check(FileManager.default.fileExists(atPath: copy.path), "Duplicate makes “untitled copy.txt”")
        files.tree.trash([copy])
        check(await until(5) { !FileManager.default.fileExists(atPath: copy.path) }, "Move to Trash")
        await wait(0.3)
        undo.undo()
        check(await until(5) { FileManager.default.fileExists(atPath: copy.path) }, "Undo puts it back from the Trash")
        files.tree.trash([copy, made], undoable: false)
        _ = await until(5) { !FileManager.default.fileExists(atPath: made.path) }

        // Expansion and tabs are remembered for the folder.
        let src = repo.appendingPathComponent("src")
        files.tree.debugExpand(src)
        let expanded = UserDefaults.standard.stringArray(forKey: "filesExpanded:" + repo.standardizedFileURL.path) ?? []
        check(expanded.contains("src"), "an opened folder is remembered (\(expanded))")
        files.open(readme)
        await wait(0.3)
        let tabs = files.editor.tabsKey.flatMap { UserDefaults.standard.stringArray(forKey: $0) } ?? []
        check(tabs.contains(readme.path), "open tabs are remembered (\(tabs.count))")
        window.toggleFiles()

        // Settings: a window of its own, on the pane used last.
        window.showSettings()
        await wait(0.5)
        let settings = SettingsWindowController.window(for: w)
        check(settings?.isVisible == true && settings?.sheetParent == nil && w.attachedSheet == nil,
              "Settings opens as a window, not a sheet")
        settings?.close()
        // Split sizes are kept per window.
        check(UserDefaults.standard.dictionaryRepresentation().keys.contains { $0.hasPrefix("NSSplitView Subview Frames MainSplit") },
              "the sidebar and inspector widths are saved")
    }

    /// An agent's interactive question (ACP elicitation): the forms Claude's
    /// AskUserQuestion and Codex's request_user_input send parse right, and a
    /// real Claude turn asks, gets an answer through the form, and uses it.
    /// Fixture: `chat`.
    private static func agentQuestion(_ window: MainWindowController) async {
        // Claude's shape: question_<n> + question_<n>_custom, multi-select as an array.
        let claude = AgentQuestion.parse(id: 7, params: [
            "mode": "form", "sessionId": "s", "toolCallId": "t1", "message": "Please answer the following questions.",
            "requestedSchema": ["type": "object", "properties": [
                "question_1_custom": ["type": "string", "title": "Other"],
                "question_0": ["type": "string", "title": "Color", "description": "Which color?",
                               "oneOf": [["const": "Red", "title": "Red", "description": "Warm"],
                                         ["const": "Blue", "title": "Blue",
                                          "_meta": ["_claude/askUserQuestionOption": ["preview": "#00f"]]]]],
                "question_1": ["type": "array", "title": "Sizes", "description": "Which sizes?",
                               "items": ["anyOf": [["const": "S", "title": "S"], ["const": "L", "title": "L"]]]],
                "question_0_custom": ["type": "string", "title": "Other"],
            ]]])
        check(claude?.questions.map(\.id) == ["question_0", "question_1"]
              && claude?.fields.map(\.id) == ["question_0", "question_0_custom", "question_1", "question_1_custom"],
              "parse (Claude): questions in order, each followed by its Other box (\(claude?.fields.map(\.id) ?? []))")
        if let q = claude, case .choice(let options) = q.questions[0].kind, case .multiChoice = q.questions[1].kind {
            check(options.map(\.value) == ["Red", "Blue"] && options[0].detail == "Warm" && options[1].preview == "#00f",
                  "parse (Claude): options with details and previews")
            let summary = q.summary(of: .accept(["question_0": "Blue", "question_1": ["S", "L"], "question_1_custom": "XL"]))
            check(summary.contains("Color: Blue") && summary.contains("Sizes: S, L, XL"), "summary: \(summary)")
        } else { check(false, "parse (Claude): a choice and a multi-choice") }
        // Codex's shape: required order, secret text, a note field marked by questionId.
        let codex = AgentQuestion.parse(id: "c1", params: [
            "mode": "form", "sessionId": "s", "message": "Codex needs your input to continue.",
            "requestedSchema": ["type": "object", "required": ["zeta", "alpha"], "properties": [
                "alpha": ["type": "string", "title": "API token?", "_meta": ["codex": ["isSecret": true]]],
                "zeta": ["type": "string", "title": "Proceed?", "oneOf": [["const": "Yes", "title": "Yes"], ["const": "No", "title": "No"]]],
                "zeta_note": ["type": "string", "title": "Additional answer or note",
                              "_meta": ["codex": ["questionId": "zeta", "role": "user_note"]]],
            ]]])
        check(codex?.questions.map(\.id) == ["zeta", "alpha"] && codex?.companion(of: codex!.questions[0])?.id == "zeta_note"
              && codex?.questions[1].kind == .text(secret: true) && codex?.questions.allSatisfy(\.required) == true,
              "parse (Codex): required order, its note box, a secret field")
        let url = AgentQuestion.parse(id: 9, params: ["mode": "url", "message": "Sign in to Linear",
                                                      "url": "https://linear.app/oauth", "elicitationId": "e1"])
        check(url?.mode == .url(URL(string: "https://linear.app/oauth")!, elicitationID: "e1"), "parse: a sign-in link")
        check(AgentQuestion.parse(id: 10, params: ["mode": "url", "url": "file:///etc/passwd"]) == nil,
              "parse: a non-web link isn't offered")

        // A real turn: Claude asks, the form answers, the reply uses it.
        guard let tree = window.paneTree, let ws = window.workspaceController else { return log("no window") }
        guard let s = ws.newChatInCurrentContext() else { return log("no folder to start a chat in") }
        func chat() -> ChatSession? { tree.surfaces.chats[s.id]?.session }
        check(await until(600) { chat()?.phase == .ready }, "chat reaches ready")
        guard let c = chat() else { return }
        c.send(text: "Use the AskUserQuestion tool to ask me which color I prefer, with exactly two options: Red and Blue. "
               + "After I answer, reply with exactly the color I picked and nothing else.", attachments: [])
        check(await until(180) { c.question != nil }, "the agent's question shows in the chat")
        guard let q = c.question else { return snapshot(window, "question-missing") }
        log("question: \(q.message) fields \(q.fields.map(\.id))")
        snapshot(window, "question")
        guard let form = tree.surfaces.chats[s.id]?.debugQuestionForm, form.question == q else {
            return check(false, "the question has a form")
        }
        check(ws.runtime(s.id)?.isWaiting == true, "the session's row says it's waiting for you")
        guard let (_, options) = form.singleChoice, let blue = options.firstIndex(where: { $0.value.contains("Blue") }) else {
            return check(false, "a single choice with Blue (\(q.fields.map(\.kind)))")
        }
        check(!form.canSubmit || q.questions.allSatisfy { !$0.required }, "nothing picked yet")
        form.pick(blue)
        check(form.canSubmit, "picking an option makes it answerable")
        form.submit()
        check(c.question == nil, "answering clears the question")
        check(ws.runtime(s.id)?.isWaiting == false, "and the row stops waiting")
        check(c.items.contains { if case .notice(_, let t, false) = $0 { t.contains("Blue") } else { false } },
              "the transcript keeps the answer")
        check(await until(180) {
            c.phase == .ready && c.items.contains { if case .agentText(_, let t) = $0 { t.contains("Blue") } else { false } }
        }, "the reply uses the answer")
        snapshot(window, "question-answered")
        ws.closeSession(s.id)
    }

    /// Two windows on one folder (Duplicate Window): one copy of the folder's
    /// state and config, and a session runs in one of them. Fixture: `files`.
    private static func twoWindows(_ window: MainWindowController) async {
        guard let tree = window.paneTree, let a = window.workspaceController,
              let app = NSApp.delegate as? AppDelegate else { return log("no window") }
        guard let first = a.orderedSessions.first, let folder = a.folders.first else { return log("need a session") }
        a.selection = .session(first.id)
        check(await until(90) { tree.surfaces.terminals[first.id] != nil || tree.surfaces.chats[first.id] != nil },
              "the session runs in the first window")

        guard let second = app.createWindow(root: a.rootURL), let b = second.workspaceController,
              let treeB = second.paneTree else { return check(false, "a second window opens") }
        if let w = second.window { w.alphaValue = 0; w.ignoresMouseEvents = true; w.orderBack(nil) }
        await wait(1)

        // A session added in B shows in A; a rename in A doesn't drop it.
        let added = b.addSession(folderID: folder.id, agent: .shell, name: "From window B \(UUID().uuidString.prefix(4))")
        check(added != nil, "window B adds a session")
        check(await until(3) { a.orderedSessions.contains { $0.id == added?.id } }, "window A lists it")
        a.autoName(first.id, from: "Renamed in window A")
        await wait(0.5)
        let saved = (try? String(contentsOf: WorkspaceState.controlDir(root: a.rootURL).appendingPathComponent("state.json"),
                                 encoding: .utf8)) ?? ""
        check(saved.contains(added?.name ?? "?") && saved.contains("Renamed in window A"),
              "state.json keeps both windows' changes")
        check(b.orderedSessions.first { $0.id == first.id }?.name == "Renamed in window A", "window B sees the rename")

        // Config: a change in B is A's too (and survives A's next save).
        let primary = a.primaryAgent
        let other: AgentKind = primary == .codex ? .claude : .codex
        b.setPrimaryAgent(other)
        check(await until(3) { a.primaryAgent == other }, "window A takes window B's config change")
        a.setPrimaryAgent(primary)
        check(await until(3) { b.primaryAgent == primary }, "and the other way round")

        // The running session isn't started (and its agent reaped) by B.
        b.selection = .session(first.id)
        await wait(3)
        check(treeB.surfaces.terminals[first.id] == nil && treeB.surfaces.chats[first.id] == nil,
              "window B doesn't start the session running in window A")
        check(tree.surfaces.terminals[first.id] != nil || tree.surfaces.chats[first.id] != nil,
              "it keeps running in window A")
        snapshot(second, "two-windows-b")

        if let added { b.closeSession(added.id) }
        check(await until(3) { !a.orderedSessions.contains { $0.id == added?.id } }, "a session closed in B leaves A")
        second.window?.close()
        await wait(0.5)
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

    // MARK: Search

    /// Expects the workspace's state.json to hold (most recent first) a claude
    /// chat "Zebra chat" resuming transcript `zebraID`, a shell "deploy notes"
    /// and a shell "alpha build". Past conversations are fixtures in a fake
    /// home under the output dir, with a private search cache.
    static let zebraID = "11111111-1111-4111-8111-111111111111"

    private static func search(_ window: MainWindowController) async {
        guard let ws = window.workspaceController, let tree = window.paneTree else { return log("no window") }
        let root = ws.rootURL.path
        let sessions = ws.orderedSessions
        guard sessions.map(\.name) == ["Zebra chat", "deploy notes", "alpha build"] else {
            return log("unexpected sessions \(sessions.map(\.name))")
        }
        let (chat, deploy, alpha) = (sessions[0], sessions[1], sessions[2])
        check(chat.isChat && chat.transcriptID == zebraID, "chat session resumes the zebra transcript")

        // Cache: tiers, original-case snippets, LIKE wildcards taken literally.
        let base = URL(fileURLWithPath: out).appendingPathComponent("search-fixtures")
        try? FileManager.default.removeItem(at: base)
        if let cache = HistoryCache(directory: base.appendingPathComponent("unit-cache")) {
            func put(_ path: String, _ title: String, _ cwd: String, _ text: String) {
                cache.upsert(url: URL(fileURLWithPath: path), mtime: Date(),
                             record: .init(id: path, agent: .claude, title: title, cwd: cwd,
                                           messageCount: 1, date: Date(), sessionID: nil),
                             searchText: text)
            }
            put("/u/title", "Alpha plan", "/w", "nothing")
            put("/u/cwd", "plan", "/w/alpha", "nothing")
            put("/u/body", "plan", "/w", String(repeating: "filler words here ", count: 20) + "the Alpha release")
            put("/u/pct", "sale", "/w", "save 50% now")
            put("/u/plain", "sale", "/w", "save 500 now")
            let hits = cache.search(query: "alpha")
            check(hits.map(\.path) == ["/u/title", "/u/cwd", "/u/body"]
                    && hits.map(\.tier) == [.title, .folder, .body], "cache ranks title > folder > body")
            let snip = hits.last?.snippet ?? ""
            log("body snippet: \(snip)")
            check(snip.contains("Alpha release") && snip.hasPrefix("…"), "body snippet keeps case and marks the cut")
            check(cache.search(query: "0%").map(\.path) == ["/u/pct"], "'%' in a query is literal")
        } else {
            check(false, "open unit cache")
        }

        // Fixture transcripts (Claude JSONL) in a fake home.
        let home = base.appendingPathComponent("home")
        // Each in its project folder (the cwd, encoded), as Claude files them.
        func project(_ cwd: String) -> URL {
            let dir = home.appendingPathComponent(".claude/projects/" + TranscriptReader.claudeEncodedDir(for: cwd))
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }
        let ids = (title: "22222222-2222-4222-8222-222222222222", body: "33333333-3333-4333-8333-333333333333",
                   elsewhere: "44444444-4444-4444-8444-444444444444", folder: "55555555-5555-4555-8555-555555555555")
        func transcript(_ id: String, cwd: String, prompt: String, reply: String, age: TimeInterval,
                        entrypoint: String = "cli") {
            func line(_ obj: [String: Any]) -> String {
                String(data: try! JSONSerialization.data(withJSONObject: obj), encoding: .utf8)!
            }
            let text = [
                line(["type": "user", "cwd": cwd, "entrypoint": entrypoint,
                      "message": ["role": "user", "content": prompt]]),
                line(["type": "assistant", "cwd": cwd, "entrypoint": entrypoint,
                      "message": ["role": "assistant", "content": [["type": "text", "text": reply]]]]),
            ].joined(separator: "\n") + "\n"
            let url = project(cwd).appendingPathComponent(id + ".jsonl")
            try? text.write(to: url, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-age)],
                                                   ofItemAtPath: url.path)
        }
        transcript(zebraID, cwd: root, prompt: "Plan the zebra migration",
                   reply: "We should feed the quokka first, then move the herd.", age: 400)
        transcript(ids.title, cwd: root, prompt: "Fix alpha bug in the parser", reply: "Done.", age: 300)
        // A long one: its last words are past what body search used to keep (60 KB).
        transcript(ids.folder, cwd: root + "/alpha-dir", prompt: "Tidy up imports",
                   reply: String(repeating: "filler text ", count: 8_000) + "and finally the narwhal plan.", age: 200)
        transcript(ids.body, cwd: root + "/sub", prompt: "Refactor the lexer",
                   reply: "Refactored it, and updated the Alpha release notes to match.", age: 100)
        transcript(ids.elsewhere, cwd: "/private/tmp/sandshell-search-elsewhere",
                   prompt: "alpha somewhere else", reply: "ok", age: 50)

        let wc = SearchWindowController(workspace: ws, mainWindow: window.window, home: home,
                                        cacheDirectory: base.appendingPathComponent("cache"))
        if let w = wc.window {
            w.alphaValue = 0
            w.ignoresMouseEvents = true
            w.orderBack(nil)
        }
        let store = wc.store
        store.reload()
        check(await until(20) { !store.history.loading && store.history.records.count == 4 },
              "past conversations scanned (4 in this workspace, the one elsewhere left out): \(store.history.records.count)")
        func titles() -> [String] { store.results.map { ($0.isLive ? "live:" : "past:") + $0.title } }
        func settle(_ q: String) async -> Bool {
            store.query = q
            return await until(10) { store.matchedQuery == q && !store.busy }
        }

        check(await settle(""), "empty query settles")
        log("all: \(titles())")
        check(titles() == ["live:Zebra chat", "live:deploy notes", "live:alpha build",
                           "past:Refactor the lexer", "past:Tidy up imports", "past:Fix alpha bug in the parser"],
              "empty query: open sessions in sidebar order, then past newest first; the open chat's own transcript isn't listed twice")
        log("search window content \(wc.window?.contentView?.frame.size ?? .zero)")
        snapshot(wc.window, "search-all")

        check(await settle("alpha"), "query 'alpha' settles")
        log("alpha: \(titles()) tiers \(store.results.map { $0.tier.map { "\($0)" } ?? "-" })")
        check(titles() == ["live:alpha build", "past:Fix alpha bug in the parser",
                           "past:Tidy up imports", "past:Refactor the lexer"],
              "'alpha': open first, then past by title > folder > body (despite body being newest)")
        check(store.results.last?.snippet?.contains("Alpha release") == true, "body match carries its snippet")
        check(store.selectedID == store.results.first?.id, "top hit selected")
        await wait(0.8)
        snapshot(wc.window, "search-alpha")

        store.moveSelection(1)
        check(store.selected?.title == "Fix alpha bug in the parser", "↓ moves to the next result")
        store.moveSelection(-5)
        check(store.selected?.title == "alpha build", "↑ clamps at the first result")

        check(await settle("quokka"), "query 'quokka' settles")
        log("quokka: \(titles())")
        check(titles() == ["live:Zebra chat"] && store.results.first?.tier == .body
                && store.results.first?.snippet?.contains("quokka") == true,
              "a body hit in an open chat's transcript ranks the chat (live), not a duplicate past entry")

        check(await settle("narwhal"), "query 'narwhal' settles")
        check(titles() == ["past:Tidy up imports"], "a body hit 96 KB into a conversation is found (\(titles()))")

        check(await settle("deploy"), "query 'deploy' settles")
        check(titles() == ["live:deploy notes"], "live sessions match by name")

        // Live result: selecting one already shown in another pane focuses that pane.
        func focusedIndex() -> Int? { tree.panes.firstIndex { $0 === tree.focused } }
        func live(_ id: UUID) -> Bool { tree.surfaces.terminals[id] != nil }
        ws.selection = .session(alpha.id)
        check(await until(120) { live(alpha.id) }, "alpha shell launches")
        window.splitRight()
        await wait()
        ws.selection = .session(deploy.id)
        check(await until(90) { live(deploy.id) }, "deploy shell launches in the second pane")
        check(focusedIndex() == 1, "second pane focused")
        check(await settle("alpha"), "query 'alpha' again")
        if let hit = store.results.first(where: { $0.isLive }) {
            wc.open(hit)
            await wait()
            check(ws.selection == .session(alpha.id) && focusedIndex() == 0
                    && tree.panes.map(\.shownSession) == [alpha.id, deploy.id],
                  "opening a live result focuses the pane already showing it (no relaunch, no restore)")
            check(ws.orderedSessions.count == 3, "no session created for a live result")
            check(wc.window?.isVisible == false, "window closes after opening")
        }
        snapshot(window, "search-live-opened")

        // Past result: restored through restoreSession, then selected. Done on a
        // second, window-less workspace so selecting the restored Claude session
        // doesn't launch it (its fixture transcript isn't in the real ~/.claude).
        let otherRoot = base.appendingPathComponent("restore-ws")
        let restoreID = "66666666-6666-4666-8666-666666666666"
        transcript(restoreID, cwd: otherRoot.path, prompt: "Restore me please", reply: "Sure.", age: 10,
                   entrypoint: "claude-desktop")
        guard let ws2 = try? WorkspaceController.open(root: otherRoot) else { return check(false, "open restore-ws") }
        let wc2 = SearchWindowController(workspace: ws2, mainWindow: nil, home: home,
                                         cacheDirectory: base.appendingPathComponent("cache"))
        let store2 = wc2.store
        store2.reload()
        check(await until(20) { !store2.history.loading && store2.history.records.map(\.id) == [restoreID] },
              "the other workspace sees only its own past conversation")
        store2.query = "restore"
        check(await until(10) { store2.matchedQuery == "restore" && !store2.busy }, "query 'restore' settles")
        if let hit = store2.results.first, !hit.isLive, hit.transcriptID == restoreID {
            let before = ws2.orderedSessions.count
            wc2.open(hit)
            let restored = ws2.orderedSessions.first { $0.transcriptID == restoreID }
            check(ws2.orderedSessions.count == before + 1 && restored != nil
                    && ws2.selection == restored.map { .session($0.id) },
                  "opening a past result restores it as a session and selects it")
            check(restored?.workdir == otherRoot.path && restored?.name == "Restore me please",
                  "restored into the conversation's cwd, named for it")
            check(restored?.isChat == true, "a conversation from the Claude app comes back as a chat")
            check(await until(5) { store2.results.map(\.isLive) == [true] },
                  "the restored conversation now lists once, as open")
        } else {
            check(false, "past result for 'restore': \(store2.results.map(\.title))")
        }
    }

    // MARK: Background tasks

    /// A real Claude chat starts a background command; Sandshell must list it
    /// as running, see it finish (the callback), and show it in the list.
    private static func background(_ window: MainWindowController) async {
        guard let tree = window.paneTree, let ws = window.workspaceController else { return log("no window") }
        guard let s = ws.newChatInCurrentContext() else { return log("no folder to start a chat in") }
        func chat() -> ChatSession? { tree.surfaces.chats[s.id]?.session }
        check(await until(600) { chat()?.phase == .ready }, "chat reaches ready")
        guard let chat = chat() else { return }
        chat.send(text: "Use the Bash tool with run_in_background set to true to run exactly: "
                  + "sleep 20; echo sandshell-bg-done — then reply with just the word STARTED. "
                  + "Do not wait for the command or check on it.", attachments: [])
        _ = await until(120) { chat.permission != nil || !ws.backgroundTasks(s.id).isEmpty }
        if let p = chat.permission {
            chat.answerPermission(p, optionID: (p.options.first { $0.kind == "allow_once" } ?? p.options.first)?.id)
        }
        check(await until(120) { ws.runningBackgroundTasks(s.id) == 1 }, "the background command shows as running")
        let task = ws.backgroundTasks(s.id).first
        log("task: \(task?.kind.rawValue ?? "-") “\(task?.title ?? "-")” detail=\(task?.detail ?? "-") output=\(task?.outputPath ?? "-")")
        check(task?.kind == .shell && (task?.detail ?? "").contains("sleep 20"), "it's the shell command Claude launched")
        await wait(1.5)
        snapshot(window, "background-running")
        if let task, let text = await ws.backgroundOutput(s.id, task) {
            log("output so far: \(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))")
        }

        check(await until(120) { ws.backgroundTasks(s.id).first?.state == .completed },
              "it's seen finishing (\(ws.backgroundTasks(s.id).first?.summary ?? "no summary"))")
        log("finished after \(Int(ws.backgroundTasks(s.id).first?.duration() ?? 0))s: \(ws.backgroundTasks(s.id).first?.summary ?? "-")")
        if let task = ws.backgroundTasks(s.id).first, let text = await ws.backgroundOutput(s.id, task) {
            check(text.contains("sandshell-bg-done"), "its output can be read back from the sandbox")
        }

        // Claude Code wakes the agent with the result; the chat shows its reply.
        let replied = await until(60) {
            chat.items.contains { if case .agentText(_, let t) = $0 { t.contains("sandshell-bg-done") || t.contains("exit code 0") } else { false } }
        }
        check(replied, "the chat shows Claude's reply to the finished task")

        // The list, as the popover and Window ▸ Background Tasks render it.
        let list = BackgroundTasksView(controller: ws, sessionIDs: { [s.id] })
        let host = NSHostingView(rootView: list.frame(width: 420, height: 300))
        host.frame = NSRect(x: 0, y: 0, width: 420, height: 300)
        host.appearance = NSAppearance(named: .aqua)
        host.layoutSubtreeIfNeeded()
        await wait(0.5)
        if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out + "/background-list.png"))
            log("snapshot background-list.png")
        }
        window.showBackgroundTasks()
        await wait(0.5)
        check(NSApp.windows.contains { $0.title.hasPrefix("Background Tasks") && $0.isVisible }, "Window ▸ Background Tasks opens")
    }

    // MARK: Pane buttons

    /// The title strip's Split Right / Split Down / Files / Close buttons and an
    /// empty pane's Show Files / Close Pane, pressed like a user would.
    private static func paneButtons(_ window: MainWindowController) async {
        guard let tree = window.paneTree, let ws = window.workspaceController else { return log("no window") }
        guard let a = ws.orderedSessions.first(where: { $0.agent == .shell })?.id else { return log("need a shell session") }
        func button(_ id: String, in pane: TerminalStackController) -> NSButton? {
            func find(_ v: NSView) -> NSButton? {
                if let b = v as? NSButton, b.accessibilityIdentifier() == id { return b }
                for s in v.subviews { if let b = find(s) { return b } }
                return nil
            }
            return find(pane.view)
        }
        func press(_ id: String, _ pane: TerminalStackController) -> Bool {
            guard let b = button(id, in: pane), !b.isHiddenOrHasHiddenAncestor else { return false }
            b.performClick(nil)
            return true
        }
        ws.selection = .session(a)
        check(await until(90) { tree.surfaces.terminals[a] != nil }, "session launches")
        let first = tree.panes[0]
        check(button("pane-files", in: first).map { !$0.isHiddenOrHasHiddenAncestor } ?? false
              && button("pane-split-right", in: first) != nil && button("pane-split-down", in: first) != nil,
              "title strip shows Files / Split Right / Split Down")
        check(button("pane-close", in: first)?.isHidden ?? false, "Close is hidden with a single pane")
        await wait(0.6)
        snapshot(window, "pane-buttons-single")

        check(press("pane-split-right", first), "Split Right pressed")
        await wait()
        check(tree.panes.count == 2 && tree.panes[1].shownSession == nil, "an empty pane opens on the right")
        guard tree.panes.count == 2 else {
            return log("panes after Split Right: \(tree.panes.map { ($0.shownSession != nil, $0.shownFiles != nil) })")
        }
        let empty = tree.panes[1]
        check(button("empty-pane-files", in: empty).map { !$0.isHiddenOrHasHiddenAncestor } ?? false,
              "the empty pane offers Show Files")
        check(button("empty-pane-close", in: empty).map { !$0.isHiddenOrHasHiddenAncestor } ?? false,
              "the empty pane offers Close Pane")
        check(button("empty-pane-new", in: empty).map { !$0.isHiddenOrHasHiddenAncestor } ?? false,
              "the empty pane offers New Session")
        await wait(0.4)
        snapshot(window, "pane-buttons-empty")

        check(press("empty-pane-files", empty), "Show Files pressed in the empty pane")
        await wait(0.6)
        let b = empty.shownSession
        check(b != nil && b != a, "the empty pane takes a session first")
        check(tree.panes.count == 3 && tree.panes.contains { $0.shownFiles?.session == b },
              "Files opens beside it instead of replacing it")
        snapshot(window, "pane-buttons-empty-files")

        check(press("pane-split-down", first), "Split Down pressed")
        await wait()
        check(tree.panes.count == 4, "Split Down adds a pane")
        if let added = tree.panes.first(where: { $0.shownSession == nil && $0.shownFiles == nil }) {
            check(press("empty-pane-close", added), "Close Pane pressed")
            await wait()
        }
        check(tree.panes.count == 3, "the empty pane closes")

        // The workspace Files pane isn't this session's: Files opens one beside it.
        check(press("pane-files", first), "Files pressed on the session's pane")
        await wait(0.6)
        check(tree.panes.contains { $0.shownFiles?.session == a }, "Files for the session opens beside it")
        let count = tree.panes.count
        _ = press("pane-files", first)
        await wait(0.4)
        check(tree.panes.count == count, "pressing Files again focuses it instead of opening another")
        await wait(0.6)
        snapshot(window, "pane-buttons-final")

        // New Session is the sidebar's + menu; what's picked opens in that pane.
        tree.split(first, edge: .bottom, showing: nil)
        await wait()
        if let fresh = tree.panes.first(where: { $0.shownSession == nil && $0.shownFiles == nil }),
           let menu = fresh.newSessionMenu?() {
            let titles = menu.items.map(\.title)
            log("empty pane New Session menu: \(titles)")
            check(titles == window.sidebarList?.newSessionMenu().items.map(\.title), "the same menu as the sidebar's +")
            if let i = menu.items.firstIndex(where: { $0.title == "New Shell" }) {
                tree.focus(fresh)
                let before = Set(ws.orderedSessions.map(\.id))
                menu.performActionForItem(at: i)
                await wait(0.6)
                let added = ws.orderedSessions.first { !before.contains($0.id) }
                check(added != nil && fresh.shownSession == added?.id, "picking New Shell opens it in the empty pane")
                if let added { ws.closeSession(added.id) }
            } else { check(false, "the menu has New Shell") }
        } else { check(false, "the empty pane has the New Session menu") }

        // Leave only a Files pane (what an earlier build could save) for `files-alone`.
        while let session = tree.panes.first(where: { $0.shownFiles == nil }), tree.panes.count > 1 {
            tree.close(session)
            await wait(0.2)
        }
        while tree.panes.count > 1, let extra = tree.panes.last { tree.close(extra); await wait(0.2) }
        await wait(1.0)
        log("left \(tree.panes.count) pane(s): files=\(tree.panes.first?.shownFiles != nil)")
    }

    /// Relaunch after `pane-buttons`: a saved Files-only layout gets a session
    /// pane back on its leading side.
    private static func filesAlone(_ window: MainWindowController) async {
        guard let tree = window.paneTree else { return log("no window") }
        await wait(0.8)
        check(tree.panes.count == 2, "two panes after restoring a Files-only layout (got \(tree.panes.count))")
        check(tree.panes.first?.shownSession != nil && tree.panes.last?.shownFiles != nil,
              "a session on the left, Files on the right")
        await wait(0.6)
        snapshot(window, "files-alone")
    }

    // MARK: Sandbox access

    /// Files says whose files these are: the sandbox, read-write, and its mounts.
    private static func sandboxAccess(_ window: MainWindowController) async {
        guard let tree = window.paneTree, let ws = window.workspaceController,
              let a = ws.orderedSessions.first else { return log("need a session") }
        ws.selection = .session(a.id)
        check(await until(90) { tree.surfaces.terminals[a.id] != nil }, "session launches")
        window.openFilesInSplit()
        await wait(0.8)
        guard let files = tree.panes.compactMap(\.filesPane).first else { return check(false, "Files pane opens") }
        let access = files.tree.sandboxAccess
        log("sandbox line: \(access?.summary ?? "none"); mount=\(access?.mount?.path ?? "-"); fs=\(access?.hostFileSystem ?? "-") volume=\(access?.volumeName ?? "-")")
        log("mounts: \(access?.mounts.map { "\($0.path)\($0.readOnly ? ":ro" : "")" } ?? [])")
        check(access?.mode == .readWrite, "the session's folder reads as read-write in its sandbox")
        check(access?.sandbox == ws.containerName(for: a.containerAgentKind), "it names the session's sandbox")
        check(access?.hostFileSystem == "APFS", "it knows the Mac side is APFS")
        // A source file: the gutter's numbers and change bars stay inside the text area.
        files.open(ws.rootURL.appendingPathComponent("src/app.py"))
        await wait(1.0)
        snapshot(window, "sandbox-access")
        if let access {
            let host = NSHostingView(rootView: SandboxAccessView(access: access))
            host.appearance = NSAppearance(named: .aqua)
            host.frame = NSRect(origin: .zero, size: host.fittingSize)
            host.layoutSubtreeIfNeeded()
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out + "/sandbox-access-popover.png"))
                log("snapshot sandbox-access-popover.png")
            }
        }
    }

    // MARK: Launch failure

    /// A workspace whose kit doesn't exist: the session says so and offers to
    /// edit the kits — and doesn't retry `sbx create` on its own.
    private static func launchFailure(_ window: MainWindowController) async {
        guard let tree = window.paneTree, let ws = window.workspaceController,
              let a = ws.orderedSessions.first else { return log("need a session") }
        ws.selection = .session(a.id)
        check(await until(120) { tree.surfaces.launchFailures[a.id] != nil }, "the launch fails")
        log("failure: \(tree.surfaces.launchFailures[a.id] ?? "-")")
        func creates() -> Int {
            let log = (try? String(contentsOf: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Logs/Sandshell/Sandshell.log"), encoding: .utf8)) ?? ""
            let name = ws.containerName(for: a.containerAgentKind)
            return log.components(separatedBy: "creating “\(name)”").count - 1
        }
        let before = creates()
        await wait(15)
        check(creates() == before, "no automatic retries (\(creates() - before) more creates in 15 s)")
        check(tree.surfaces.launchFailures[a.id]?.contains("kit") == true, "the message names the kit problem")
        snapshot(window, "launch-failure")
    }

    // MARK: Fork

    /// Two replies; hover the first (Copy / Fork bar), fork there: the new chat
    /// resumes with the first reply and without the second.
    private static func fork(_ window: MainWindowController) async {
        guard let tree = window.paneTree, let ws = window.workspaceController else { return log("no window") }
        guard let s = ws.newChatInCurrentContext() else { return log("no folder to start a chat in") }
        func chat(_ id: UUID) -> ChatSession? { tree.surfaces.chats[id]?.session }
        func said(_ c: ChatSession) -> String {
            c.items.compactMap { if case .agentText(_, let t) = $0 { t } else { nil } }.joined(separator: "\n")
        }
        check(await until(600) { chat(s.id)?.phase == .ready }, "chat reaches ready")
        guard let c = chat(s.id) else { return }
        c.send(text: "Reply with exactly the word ALPHA-ONE and nothing else.", attachments: [])
        check(await until(180) { c.phase == .ready && said(c).contains("ALPHA-ONE") }, "first reply")
        c.send(text: "Reply with exactly the word BETA-TWO and nothing else.", attachments: [])
        check(await until(180) { c.phase == .ready && said(c).contains("BETA-TWO") }, "second reply")

        if let view = tree.surfaces.chats[s.id] {
            view.debugTranscript.debugHoverFirstReply()
            await wait(0.4)
            check(view.debugTranscript.debugReplyActionsShown && view.debugTranscript.debugForkShown,
                  "hovering a reply shows Copy / Fork")
            snapshot(window, "fork-hover")
        }
        let first = c.items.compactMap { if case .agentText(_, let t) = $0 { t } else { nil } }.first { $0.contains("ALPHA-ONE") } ?? "ALPHA-ONE"
        guard let forked = ws.forkChat(s.id, upTo: first) else { return check(false, "fork created") }
        check(forked.name.hasPrefix("Fork of"), "fork created (\(forked.name))")
        check(await until(300) { chat(forked.id)?.phase == .ready }, "the fork resumes as a chat")
        await wait(1.0)
        if let f = chat(forked.id) {
            check(said(f).contains("ALPHA-ONE") && !said(f).contains("BETA-TWO"),
                  "the fork has the first reply and not the second (\(said(f).prefix(80)))")
        }
        snapshot(window, "fork-final")
    }

    // MARK: Open Quickly

    /// The match list's selected row: an accent bar with light text.
    private static func openQuickly() async {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("sandshell-oq-\(UUID().uuidString.prefix(6))")
        for name in ["src/app.py", "src/apply.swift", "README.md"] {
            let url = dir.appendingPathComponent(name)
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? "x".write(to: url, atomically: true, encoding: .utf8)
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        let indexed = await WorkspaceFileIndex.shared.files(under: dir.path)
        check(Set(indexed) == ["README.md", "src/app.py", "src/apply.swift"],
              "the file index reads a folder under /var (a symlink) correctly (\(indexed))")
        let finder = OpenQuicklyController(root: dir)
        let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 360), styleMask: [.borderless],
                            backing: .buffered, defer: false)
        host.isReleasedWhenClosed = false
        host.alphaValue = 0
        host.contentViewController = finder
        _ = await until(5) { finder.search("apy"); return !finder.results.isEmpty }
        await wait(0.4)
        check(finder.results.first == "src/app.py", "“apy” finds src/app.py first (\(finder.results.prefix(3)))")
        snapshot(finder.view, "open-quickly")
        guard let rep = finder.view.bitmapImageRepForCachingDisplay(in: finder.view.bounds) else { return }
        finder.view.cacheDisplay(in: finder.view.bounds, to: rep)
        // The first row sits under the search field (~63 pt from the top); the
        // bitmap is in pixels, top-left origin.
        let scale = CGFloat(rep.pixelsHigh) / finder.view.bounds.height
        let color = rep.colorAt(x: Int(14 * scale), y: Int(63 * scale))
        log("selected row color: \(String(describing: color))")
        if let c = color?.usingColorSpace(.sRGB) {
            check(c.brightnessComponent > 0.25 && c.saturationComponent > 0.2, "the selected row is accent-colored, not black")
        }
        host.close()
    }

    // MARK: Pasting an image into a terminal

    /// An image pasted into a terminal session goes into the sandbox's /tmp
    /// (where Claude Code can read it), not the project. Needs a shell session.
    private static func paste(_ window: MainWindowController) async {
        guard let tree = window.paneTree, let ws = window.workspaceController,
              let s = ws.orderedSessions.first(where: { !$0.isChat }) else { return log("need a terminal session") }
        ws.selection = .session(s.id)
        check(await until(120) { tree.surfaces.terminals[s.id] != nil }, "the session launches")
        await wait(1)
        let projectPastes = { (try? FileManager.default.contentsOfDirectory(atPath: s.workdir + "/.sbx"))?
            .filter { $0.hasPrefix("paste-") }.count ?? 0 }
        let before = projectPastes()
        // A private pasteboard: the user's clipboard stays theirs.
        let board = NSPasteboard(name: .init("sandshell-selftest-\(UUID().uuidString)"))
        board.clearContents()
        let image = NSImage(size: NSSize(width: 8, height: 8), flipped: false) { r in
            NSColor.systemTeal.setFill(); r.fill(); return true
        }
        board.writeObjects([image])
        guard let pane = tree.panes.first(where: { $0.shownSession == s.id }) else { return check(false, "a pane shows it") }
        check(pane.debugPaste(board), "the paste is taken")
        let container = ws.containerName(for: s.containerAgentKind)
        func sandboxPastes() async -> String {
            await Task.detached {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: PathFixer.sbxPath())
                p.arguments = ["exec", container, "sh", "-c", "ls -1 \(SbxClient.pasteDirectory) 2>/dev/null"]
                let pipe = Pipe()
                p.standardOutput = pipe
                p.standardError = FileHandle.nullDevice
                guard (try? p.run()) != nil else { return "" }
                let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                p.waitUntilExit()
                return text
            }.value
        }
        var listing = ""
        for _ in 0..<20 {
            listing = await sandboxPastes()
            if listing.contains("paste-") { break }
            await wait(1)
        }
        log("sandbox pastes: \(listing.split(separator: "\n"))")
        check(listing.contains("paste-"), "the image is in the sandbox's \(SbxClient.pasteDirectory)")
        check(projectPastes() == before, "and nothing new in the project's .sbx/")
        board.releaseGlobally()
    }

    // MARK: Kits per agent

    /// A kit made for one agent (code-server needs claude) stays out of other
    /// agents' sandboxes instead of failing them. Expects the workspace's kits
    /// to include docker.io/sbx/code-server-kit:latest.
    private static func kitAgents(_ window: MainWindowController) async {
        guard let ws = window.workspaceController, let tree = window.paneTree else { return log("no window") }
        let codeServer = "docker.io/sbx/code-server-kit:latest"
        check(KitStore.kits([codeServer, "/some/kit"], for: .codex) == ["/some/kit"]
              && KitStore.kits([codeServer, "/some/kit"], for: .claude) == [codeServer, "/some/kit"],
              "code-server is for Claude's sandbox only")
        // An agent kit (kind: sandbox) is its own agent's, never another's --kit.
        let droid = "git+https://example.invalid/kits.git#dir=selftest-droid"
        AgentProfileStore.upsert(AgentProfile(agent: "selftest-droid", displayName: "Droid", icon: "cpu",
                                              colorHex: "8b5cf6", kitRef: droid))
        check(KitStore.kits([droid, "/some/kit"], for: .codex) == ["/some/kit"]
              && KitStore.kits([droid], for: AgentKind(rawValue: "selftest-droid")) == [droid],
              "an agent's own kit stays with that agent")
        AgentProfileStore.remove("selftest-droid")
        check(ws.kits.contains(codeServer), "the workspace has code-server")
        let name = await ws.ensureContainerReady(for: .codex)
        check(name != nil, "the Codex sandbox builds (\(ws.lastError ?? "ok"))")
        if let name {
            let kits = await SbxClient.shared.inspect(name)?.kits ?? []
            log("codex sandbox kits: \(kits)")
            check(!kits.contains { $0.contains("code-server") }, "without code-server")
            await wait(2)
            check(ws.kitDrift[.codex] == nil, "and no kit drift is reported for it")
        }
        // A long failure wraps inside the pane.
        if let pane = tree.panes.first {
            pane.debugShowLaunchFailure("✓ OpenAI — using stored OAuth credentials\nerror: request failed: 400 Bad Request: "
                + "kit_artifacts: compose: kit \"code-server\" requires base agent \"claude\" but was composed with \"codex\"")
            await wait(0.5)
            snapshot(window, "kit-agents-failure")
        }
    }

    // MARK: Chat model

    /// A Claude chat runs the workspace's model (even one the adapter's own
    /// list lacks), shows the title-strip readout, and picking a model there
    /// relaunches it on that model with the conversation. Two tiny turns.
    private static func chatModel(_ window: MainWindowController) async {
        guard let tree = window.paneTree, let ws = window.workspaceController else { return log("no window") }
        ws.setClaudeModel("claude-sonnet-5-5")
        guard let s = ws.newChatInCurrentContext() else { return log("no folder to start a chat in") }
        func chat() -> ChatSession? { tree.surfaces.chats[s.id]?.session }
        func said(_ c: ChatSession) -> String {
            c.items.compactMap { if case .agentText(_, let t) = $0 { t } else { nil } }.joined(separator: "\n")
        }
        check(await until(600) { chat()?.phase == .ready }, "chat reaches ready")
        guard let first = chat() else { return }
        first.send(text: "Remember the word HERON. Reply with exactly the word OK.", attachments: [])
        check(await until(180) { first.phase == .ready && said(first).contains("OK") }, "first reply")
        check(await until(10) { first.liveModel != nil }, "the chat reports its model")
        log("live model: \(first.liveModel ?? "-"), usage \(String(describing: first.usage))")
        check(first.liveModel.map { ClaudePriceBook.normalize($0) } == "claude-sonnet-5-5",
              "it answers on the workspace's model, Sonnet 5.5")
        guard let pane = tree.panes.first(where: { $0.shownSession == s.id }) else { return check(false, "a pane shows the chat") }
        check(pane.debugReadoutShown, "the title strip shows the Claude readout for the chat")
        log(pane.debugReadoutFitting)
        snapshot(window, "chat-model-sonnet")

        pane.debugPickModel("claude-haiku-4-5")
        check(ws.claudeModel == "claude-haiku-4-5", "the pick is the workspace's model")
        check(await until(180) { chat() !== first && chat()?.phase == .ready }, "the chat relaunches")
        guard let second = chat() else { return }
        second.send(text: "What word did I ask you to remember? Reply with just the word.", attachments: [])
        check(await until(180) { second.phase == .ready && said(second).contains("HERON") }, "with its conversation")
        check(await until(10) { second.liveModel.map { ClaudePriceBook.normalize($0).hasPrefix("claude-haiku-4-5") } ?? false },
              "and answers on Haiku 4.5 (\(second.liveModel ?? "-"))")
        snapshot(window, "chat-model-haiku")
        ws.setClaudeModel(nil)
    }

    // MARK: Reconnect

    /// A chat whose agent dies on its own (as over a long sleep) comes back by
    /// itself with its conversation; a second death within the minute waits
    /// for the Reconnect button. Uses the signed-in account (two tiny turns).
    private static func reconnect(_ window: MainWindowController) async {
        guard let tree = window.paneTree, let ws = window.workspaceController else { return log("no window") }
        guard let s = ws.newChatInCurrentContext() else { return log("no folder to start a chat in") }
        func view() -> ChatSessionView? { tree.surfaces.chats[s.id] }
        func chat() -> ChatSession? { view()?.session }
        func said(_ c: ChatSession) -> String {
            c.items.compactMap { if case .agentText(_, let t) = $0 { t } else { nil } }.joined(separator: "\n")
        }
        check(await until(600) { chat()?.phase == .ready }, "chat reaches ready")
        guard let first = chat() else { return }
        first.send(text: "Remember the word OTTER. Reply with exactly the word OK.", attachments: [])
        check(await until(180) { first.phase == .ready && said(first).contains("OK") }, "first reply")
        let container = ws.containerName(for: s.containerAgentKind)
        func killAgent() async {
            await SbxClient.reapSessionProcessesAndWait(container: container, match: "SANDSHELL_SESSION=\(s.id.uuidString)")
        }

        await killAgent()
        check(await until(30) { if case .closed = first.phase { true } else { false } }, "killing the agent closes the chat")
        check(await until(120) { chat() !== first && chat()?.phase == .ready }, "the shown chat reconnects by itself")
        guard let second = chat() else { return }
        check(said(second).contains("OK"), "the reconnected chat has its conversation")
        second.send(text: "What word did I ask you to remember? Reply with just the word.", attachments: [])
        check(await until(180) { second.phase == .ready && said(second).contains("OTTER") }, "and the agent remembers it")

        await killAgent()
        check(await until(30) { if case .closed = second.phase { true } else { false } }, "a second death closes it again")
        await wait(5)
        check(chat() === second && second.needsReconnect, "within the minute it waits for Reconnect")
        snapshot(window, "reconnect-button")
        view()?.onReconnect?()
        check(await until(120) { chat() !== second && chat()?.phase == .ready }, "Reconnect brings it back")
        snapshot(window, "reconnect-final")
    }

    // MARK: Following another app

    /// A chat whose conversation another app keeps writing: its turns appear
    /// here, and the next prompt reloads the agent so the reply knows them.
    /// Uses the signed-in account (two tiny turns).
    private static func follow(_ window: MainWindowController) async {
        // The parser on its own: prompts, replies, tools; wrappers and meta skipped.
        let fixture = [
            #"{"type":"user","message":{"role":"user","content":"hello there"},"entrypoint":"claude-desktop"}"#,
            #"{"type":"user","isMeta":true,"message":{"role":"user","content":[{"type":"text","text":"[Image #1]"}]}}"#,
            #"{"type":"user","message":{"role":"user","content":"<task-notification>x</task-notification>"}}"#,
            #"{"type":"assistant","message":{"id":"m1","content":[{"type":"thinking","thinking":"","signature":"s"}],"stop_reason":"tool_use"}}"#,
            #"{"type":"assistant","message":{"id":"m1","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"ls -la"}}],"stop_reason":"tool_use"}}"#,
            #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"a\nb","is_error":false}]}}"#,
            #"{"type":"assistant","isSidechain":true,"message":{"id":"m9","content":[{"type":"text","text":"subagent"}]}}"#,
            #"{"type":"assistant","message":{"id":"m2","content":[{"type":"text","text":"Done."}],"stop_reason":"end_turn"}}"#,
        ].joined(separator: "\n")
        let batch = ClaudeTranscriptTail.parse(fixture)
        log("parsed: \(batch.events)")
        check(batch.events.count == 4, "parse: prompt, tool use, tool result, reply (got \(batch.events.count))")
        check(batch.events.first == .user("hello there"), "parse: the prompt, not the wrappers")
        check(batch.working == false && batch.entrypoint == "claude-desktop", "parse: turn finished, written by the Claude app")
        // Reading from mid-line (even mid-character, after an in-place rewrite)
        // skips to the next whole line instead of getting stuck.
        let tailFile = FileManager.default.temporaryDirectory.appendingPathComponent("sandshell-tail-\(UUID().uuidString).jsonl")
        try? Data("{\"a\":\"x—y\"}\n{\"b\":1}\n".utf8).write(to: tailFile)
        let mid = ClaudeTranscriptTail.readLines(tailFile, from: 9)   // inside "—"
        check(mid?.0 == "{\"b\":1}\n" && mid?.1 == ClaudeTranscriptTail.fileSize(tailFile),
              "tail: a read from mid-character skips to the next line (\(String(describing: mid)))")
        let whole = ClaudeTranscriptTail.readLines(tailFile, from: 0)
        let edge = ClaudeTranscriptTail.readLines(tailFile, from: UInt64("{\"a\":\"x—y\"}\n".utf8.count))
        check(whole?.0.split(separator: "\n").count == 2 && edge?.0 == "{\"b\":1}\n", "tail: line-boundary reads are whole")
        try? FileManager.default.removeItem(at: tailFile)
        let own = ClaudeTranscriptTail.parse(
            #"{"type":"user","entrypoint":"sdk-ts","message":{"role":"user","content":"<task-notification>done</task-notification>"}}"#,
            skippingEntrypoint: "sdk-ts")
        check(!own.sawConversation, "parse: the chat's own agent's lines (sdk-ts) are skipped")
        check(TranscriptReader.claudeEncodedDir(for: "/Users/Zoë/a.b c") == "-Users-Zo--a-b-c",
              "project folder names match Claude Code's (ASCII letters and digits only)")

        // The session registry (~/.claude/sessions), on a scratch copy: who's live.
        let me = ProcessInfo.processInfo.processIdentifier
        let started = ClaudeSessionRegistry.processStart(me) ?? ""
        let registry = URL(fileURLWithPath: out).appendingPathComponent("registry")
        let sessionsDir = registry.appendingPathComponent(".claude/sessions")
        try? FileManager.default.removeItem(at: registry)
        try? FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        func register(pid: Int32, sid: String, entrypoint: String, status: String, domain: String = "darwin",
                      procStart: String? = nil, file: String? = nil, ago: TimeInterval = 0) {
            let ms = (Date().timeIntervalSince1970 - ago) * 1000
            var o: [String: Any] = ["pid": pid, "sessionId": sid, "entrypoint": entrypoint, "status": status,
                                    "pidDomain": domain, "updatedAt": ms, "statusUpdatedAt": ms]
            if let procStart { o["procStart"] = procStart }
            try? JSONSerialization.data(withJSONObject: o).write(to: sessionsDir.appendingPathComponent("\(file ?? "\(pid)").json"))
        }
        let fake = "00000000-0000-0000-0000-000000000001"
        register(pid: 999_999, sid: fake, entrypoint: "cli", status: "busy", procStart: started, file: "dead")
        register(pid: me, sid: fake, entrypoint: "cli", status: "busy", procStart: "Mon Jan 1 00:00:00 2001", file: "reused")
        register(pid: 7, sid: fake, entrypoint: "sdk-ts", status: "busy", domain: "linux::pid:[1]", file: "own")
        check(ClaudeSessionRegistry.otherWriter(home: registry.path, sessionID: fake) == nil,
              "registry: a dead pid, a reused pid and our own sandboxed agent aren't other writers")
        register(pid: 8, sid: fake, entrypoint: "cli", status: "busy", domain: "linux::pid:[1]", file: "sandbox-cli")
        check(ClaudeSessionRegistry.otherWriter(home: registry.path, sessionID: fake)?.entrypoint == "cli",
              "registry: a terminal in a sandbox, heard from just now, is")
        register(pid: me, sid: fake, entrypoint: "claude-desktop", status: "busy", procStart: started, file: "live")
        check(ClaudeSessionRegistry.otherWriter(home: registry.path, sessionID: fake)?.entrypoint == "claude-desktop",
              "registry: a live process on this Mac (pid + start time) is, busiest first")
        for f in ["dead", "reused", "own", "sandbox-cli", "live"] {
            try? FileManager.default.removeItem(at: sessionsDir.appendingPathComponent("\(f).json"))
        }

        guard let tree = window.paneTree, let ws = window.workspaceController else { return log("no window") }
        guard let s = ws.newChatInCurrentContext() else { return log("no folder to start a chat in") }
        func chat() -> ChatSession? { tree.surfaces.chats[s.id]?.session }
        func said(_ c: ChatSession) -> String {
            c.items.compactMap { if case .agentText(_, let t) = $0 { t } else { nil } }.joined(separator: "\n")
        }
        check(await until(600) { chat()?.phase == .ready }, "chat reaches ready")
        guard let c = chat() else { return }
        c.send(text: "Reply with exactly the word PONG and nothing else.", attachments: [])
        check(await until(180) { c.phase == .ready && said(c).contains("PONG") }, "first reply")
        await wait(4)   // past our own turn's grace period

        // Another app continues the conversation in the same transcript.
        guard let sid = ws.session(id: s.id)?.transcriptID else { return check(false, "transcript id known") }
        let url = ws.home.appendingPathComponent(
            ".claude/projects/\(TranscriptReader.claudeEncodedDir(for: c.workdir))/\(sid).jsonl")
        // Claude Code rewrites its trailing cost-state line in place a while after
        // a turn: append only once the file has been still for a few seconds.
        var lastSize = ClaudeTranscriptTail.fileSize(url), stillSince = Date()
        _ = await until(60) {
            let size = ClaudeTranscriptTail.fileSize(url)
            if size != lastSize { lastSize = size; stillSince = Date() }
            return Date().timeIntervalSince(stillSince) >= 6
        }
        let lines = (try? String(contentsOf: url, encoding: .utf8))?.split(separator: "\n") ?? []
        // Chain onto the conversation's last node, as another Claude app would:
        // messages and their attachments (not sidechains, not bookkeeping lines).
        let last = lines.reversed().lazy.compactMap { line -> String? in
            guard let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  ["user", "assistant", "attachment", "system"].contains(o["type"] as? String ?? ""),
                  o.keys.contains("parentUuid"), o["isSidechain"] as? Bool != true else { return nil }
            return o["uuid"] as? String
        }.first
        check(last != nil, "transcript at \(url.path) has turns")
        // Real lines from this transcript as templates (every field Claude Code
        // writes), re-addressed: what another Claude app's turn looks like.
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let userID = UUID().uuidString.lowercased(), replyID = UUID().uuidString.lowercased()
        func line(_ o: [String: Any]) -> String {
            String(data: try! JSONSerialization.data(withJSONObject: o), encoding: .utf8)! + "\n"
        }
        func template(_ type: String) -> [String: Any] {
            lines.reversed().lazy.compactMap { l -> [String: Any]? in
                guard let o = try? JSONSerialization.jsonObject(with: Data(l.utf8)) as? [String: Any],
                      o["type"] as? String == type, o["isMeta"] as? Bool != true,
                      (o["message"] as? [String: Any])?["content"] != nil else { return nil }
                return o
            }.first ?? [:]
        }
        var user = template("user")
        user.merge(["parentUuid": last ?? NSNull(), "uuid": userID, "type": "user", "entrypoint": "claude-desktop",
                    "isSidechain": false, "timestamp": iso.string(from: Date()),
                    "message": ["role": "user", "content": "Remember this codeword: ZEBRA-42. Reply OK."]]) { $1 }
        user.removeValue(forKey: "promptId")
        var reply = template("assistant")
        var message = reply["message"] as? [String: Any] ?? [:]
        message.merge(["id": "msg_selftest_\(replyID.prefix(8))", "content": [["type": "text", "text": "OK, noted."]],
                       "stop_reason": "end_turn"]) { $1 }
        reply.merge(["parentUuid": userID, "uuid": replyID, "type": "assistant", "entrypoint": "claude-desktop",
                     "isSidechain": false, "timestamp": iso.string(from: Date().addingTimeInterval(1)),
                     "message": message, "requestId": "req_selftest_\(replyID.prefix(8))"]) { $1 }
        func inject() {
            guard let fh = try? FileHandle(forWritingTo: url) else { return }
            // Claude Code may leave its last line (cost-state) without a newline.
            let endsWithNewline = (try? Data(contentsOf: url))?.last == 0x0A
            fh.seekToEndOfFile()
            fh.write(Data(((endsWithNewline ? "" : "\n") + line(user) + line(reply)).utf8))
            try? fh.close()
        }
        /// Both injected lines are there, whole (a cost-state rewrite in place
        /// by our own still-running agent can land on top of them).
        func injectedIntact() -> Bool {
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            let ids = text.split(separator: "\n").compactMap { l -> String? in
                (try? JSONSerialization.jsonObject(with: Data(l.utf8)) as? [String: Any])?["uuid"] as? String
            }
            return ids.contains(userID) && ids.contains(replyID)
        }
        inject()
        for _ in 0..<3 {
            await wait(8)
            if injectedIntact() { break }
            log("injected turn was overwritten (cost-state rewrite); writing it again")
            inject()
        }
        check(injectedIntact(), "the other app's turn is in the transcript")
        check(await until(10) {
            c.items.contains { if case .user(_, let t, _) = $0 { t.contains("ZEBRA-42") } else { false } }
                && said(c).contains("OK, noted.")
        }, "the other app's turn appears in the chat")
        check(c.items.contains { if case .notice(_, let t, _) = $0 { t == "Continued in the Claude app" } else { false } },
              "with a 'Continued in the Claude app' notice")
        check(!c.otherAppIsWorking, "the other app's turn is finished")
        snapshot(window, "follow-external")

        log("before sending: injected turn intact = \(injectedIntact())")
        // Sending now reloads the agent first, so it knows the codeword.
        c.send(text: "What codeword did I ask you to remember? Reply with just the codeword.", attachments: [])
        check(c.isCatchingUp, "sending reloads the agent first")
        check(await until(300) { c.phase == .ready && said(c).contains("ZEBRA-42") && !c.isCatchingUp },
              "the reply knows the other app's turn (\(said(c).suffix(80)))")
        check(said(c).contains("PONG"), "the reloaded transcript still has the first reply")
        check(injectedIntact(), "the reload left the other app's turn intact (the old agent didn't write over it)")
        snapshot(window, "follow-final")

        // Another app mid-turn (per the registry): the message waits, then goes.
        guard let view = tree.surfaces.chats[s.id], let sid2 = c.sessionID else { return }
        c.registryHome = registry.path
        register(pid: me, sid: sid2, entrypoint: "cli", status: "busy", procStart: started)
        check(await until(6) { c.otherAppIsWorking }, "the registry says another app is working here")
        log("other writer: \(String(describing: c.otherWriter)) as “\(c.otherWriterName)”")
        view.debugSetDraft("Reply with exactly the word DONE and nothing else.")
        view.sendWhenOtherAppIdles()
        await wait(4)
        check(!said(c).contains("DONE") && c.phase == .ready, "the message waits while it's busy")
        register(pid: me, sid: sid2, entrypoint: "cli", status: "idle", procStart: started)
        check(await until(180) { c.phase == .ready && said(c).contains("DONE") }, "then sends once it's idle")

        // A terminal Claude in a sandbox killed mid-turn: its entry still says
        // busy, but its pid isn't in any sandbox — the chat stops waiting on it.
        c.registryProbeAfter = 0
        register(pid: 999_999, sid: sid2, entrypoint: "cli", status: "busy", domain: "linux::pid:[1]",
                 procStart: "987654321", ago: 300)
        check(await until(6) { c.otherAppIsWorking }, "a quiet busy writer in a sandbox counts as working at first")
        check(await until(60) { !c.otherAppIsWorking }, "until the sandboxes say its process is gone")
        // One whose process is there (the sandbox's pid 1, by its start time) still counts.
        let start1 = (await SbxClient.shared.exec(inSandbox: c.containerName, script: "awk '{print $22}' /proc/1/stat"))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        check(start1.map { Int($0) != nil } == true, "the sandbox reports pid 1's start time (\(start1 ?? "nil"))")
        register(pid: 1, sid: sid2, entrypoint: "cli", status: "busy", domain: "linux::pid:[1]", procStart: start1, ago: 300)
        check(await until(6) { c.otherAppIsWorking }, "a quiet busy writer whose process is there counts as working")
        await wait(8)   // past its probe
        check(c.otherAppIsWorking, "and keeps counting after the sandbox confirms it")
        try? FileManager.default.removeItem(at: registry)
        ws.closeSession(s.id)
    }

    // MARK: Sea

    /// The empty chat's sea at rest and stirred by a click, light and dark;
    /// with a window, the real empty chat too.
    private static func sea(_ window: MainWindowController) async {
        if let ws = window.workspaceController, let tree = window.paneTree, let s = ws.newChatInCurrentContext() {
            _ = await until(180) { tree.surfaces.chats[s.id] != nil }
            await wait(2)
            snapshot(window, "sea-empty-chat")
            // The empty state mustn't hold the window open: it resizes freely.
            if let w = window.window, let chat = tree.surfaces.chats[s.id] {
                log("chat fitting \(chat.fittingSize)")
                check(chat.fittingSize.height < 600, "an empty chat asks for no great height")
                var frame = w.frame
                frame.size.height = 560
                w.setFrame(frame, display: true)
                await wait(0.3)
                check(abs(w.frame.height - 560) < 2, "the window shrinks to 560 pt (got \(Int(w.frame.height)))")
            }
            ws.closeSession(s.id)   // leave the fixture as it was
        }
        for (name, look) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            for splash in [nil, CGPoint(x: 200, y: 84)] as [CGPoint?] {
                let host = NSHostingView(rootView: SeaBackdrop(initialSplash: splash) {
                        Text("What should Claude work on?").font(.title3.weight(.medium)).foregroundStyle(.secondary)
                    }
                    .background(Color(nsColor: .textBackgroundColor)))
                host.appearance = NSAppearance(named: look)
                host.frame = NSRect(x: 0, y: 0, width: 520, height: 300)
                let w = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                w.isReleasedWhenClosed = false
                w.alphaValue = 0
                w.contentView = host
                w.orderBack(nil)
                for (i, delay) in (splash == nil ? [0.3] : [0.12, 0.2, 0.4, 1.4]).enumerated() {
                    await wait(delay)
                    snapshot(host, "sea-\(name)-\(splash == nil ? "rest" : "splash\(i)")")
                }
                w.close()
            }
        }
        // A narrow pane: the hint wraps inside it instead of being cut off.
        let narrow = NSHostingView(rootView: SeaBackdrop {
                Text("It works in msdgc, inside its sandbox. Type / for commands, @ to mention a file, or drop files here.")
                    .font(.callout).multilineTextAlignment(.center).frame(maxWidth: 360)
                    .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 24)
            }
            .background(Color(nsColor: .textBackgroundColor)))
        narrow.sizingOptions = []
        narrow.frame = NSRect(x: 0, y: 0, width: 260, height: 360)
        let nw = NSWindow(contentRect: narrow.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        nw.isReleasedWhenClosed = false
        nw.alphaValue = 0
        nw.contentView = narrow
        await wait(0.3)
        snapshot(narrow, "sea-narrow")
        nw.close()
        check(true, "rendered")
    }

    // MARK: Tool groups

    /// Consecutive tool calls read as one quiet line that opens to the cards.
    private static func toolGroups() async {
        typealias Call = ChatItem.ToolCall
        func call(_ id: String, _ kind: String, _ title: String, _ input: String, _ status: String = "completed",
                  output: String = "") -> ChatItem {
            .tool(Call(id: id, title: title, kind: kind, status: status, output: output, diffs: [], input: input))
        }
        let items: [ChatItem] = [
            .user(id: UUID(), text: "What changed?", attachments: []),
            call("t1", "execute", "`git status`", "git status --short", output: " M Sandshell/App/SelfTest.swift"),
            .agentText(id: "a1", text: "One file changed. Let me look closer."),
            call("t2", "execute", "`git diff`", "git diff --stat"),
            call("t3", "read", "Read SelfTest.swift", "/Users/me/repo/Sandshell/App/SelfTest.swift"),
            call("t4", "execute", "`swift build`", "swift build", "failed", output: "error: no Package.swift"),
            .agentText(id: "a2", text: "The build failed; here is why."),
            call("t5", "execute", "`sed -n 1,40p Sandshell/Chat/ChatTranscriptView.swift`",
                 "sed -n 1,40p Sandshell/Chat/ChatTranscriptView.swift | head -20", "in_progress"),
        ]
        let view = ChatTranscriptView(frame: NSRect(x: 0, y: 0, width: 640, height: 520))
        let host = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        host.isReleasedWhenClosed = false
        host.alphaValue = 0
        host.contentView = view
        view.update(items)
        await wait(0.4)
        let text = view.debugText
        log("collapsed:\n\(text)")
        check(text.contains("Ran git status --short  ›"), "one command reads as “Ran git status --short ›”")
        check(text.contains("Ran 2 commands and read a file  ›  · 1 failed"), "a mixed run is summed up, with its failure")
        check(text.contains("Running sed -n 1,40p Sandshell/Chat/ChatTranscriptVie…  ›"), "a running command says Running, cut short")
        check(!text.contains("M Sandshell/App/SelfTest.swift") && !text.contains("no Package.swift"),
              "cards stay closed until asked")
        snapshot(view, "tool-groups-collapsed")
        view.debugToggle("group-t2")
        await wait(0.3)
        let open = view.debugText
        check(open.contains("Ran 2 commands and read a file  ⌄") && open.contains("no Package.swift"),
              "clicking a group opens its cards")
        check(!open.contains("M Sandshell/App/SelfTest.swift"), "other groups stay closed")
        snapshot(view, "tool-groups-open")
        host.close()
    }

    // MARK: Chat extras (Undo, background tasks, MCP)

    /// Through the adapter wrapper: a turn's file edits are listed and undone,
    /// a background command is stopped, and MCP status comes back. Uses the
    /// signed-in account (a few tiny turns) and Auto mode (no prompts).
    private static func chatExtras(_ window: MainWindowController) async {
        guard let tree = window.paneTree, let ws = window.workspaceController,
              let s = ws.newChatInCurrentContext() else { return log("no window") }
        func chat() -> ChatSession? { tree.surfaces.chats[s.id]?.session }
        check(await until(600) { chat()?.phase == .ready }, "chat starts")
        guard let c = chat() else { return }
        let name = "extras-\(Int(Date().timeIntervalSince1970)).txt"
        let file = URL(fileURLWithPath: c.workdir).appendingPathComponent(name)
        c.send(text: "Use the Write tool to create the file \(name) containing exactly the word hello. Then reply DONE.", attachments: [])
        check(await until(240) { c.phase == .ready && FileManager.default.fileExists(atPath: file.path) }, "Claude writes \(name)")
        let changes = await until(20) {
            c.items.contains { if case .fileChanges(_, let p, false) = $0 { p.contains { $0.hasSuffix(name) } } else { false } }
        }
        check(changes, "the turn lists the file it changed")
        if let turn = c.items.compactMap({ if case .fileChanges(let t, _, _) = $0 { t } else { nil } }).last {
            do {
                let preview = try await c.previewRewind(turn)
                log("rewind preview: can \(preview.canRewind) files \(preview.files) +\(preview.insertions) −\(preview.deletions)")
                check(preview.canRewind && preview.files.contains { $0.hasSuffix(name) }, "Undo previews putting it back")
                check(FileManager.default.fileExists(atPath: file.path), "a preview changes nothing")
                let done = try await c.rewind(turn)
                check(done.canRewind && !FileManager.default.fileExists(atPath: file.path), "Undo removes the file it created")
                check(c.items.contains { if case .fileChanges(turn, _, true) = $0 { true } else { false } }, "and the line says Restored")
            } catch {
                check(false, "rewind: \(error.localizedDescription)")
            }
        }
        snapshot(window, "extras-undo")

        // MCP: what Claude Code sees.
        do {
            try await c.refreshMCP()
            log("mcp: \((c.mcpServers ?? []).map { "\($0.name)=\($0.status) tools \($0.tools.count)" })")
            check(c.mcpServers != nil, "MCP status comes back")
        } catch { check(false, "MCP status: \(error.localizedDescription)") }

        // A background command, stopped from here.
        c.send(text: "Run the shell command `sleep 300` with the Bash tool's run_in_background option, then reply STARTED. Don't wait for it.", attachments: [])
        check(await until(240) { c.phase == .ready && c.backgroundTasks.values.contains { $0.isRunning } },
              "the background command is listed (\(c.backgroundTasks.values.map { "\($0.name):\($0.state)" }))")
        if let task = c.backgroundTasks.values.first(where: { $0.isRunning }) {
            let stopped = await c.stopBackgroundTask(task.id)
            log("stopped \(task.id) (\(task.description)): \(stopped), now \(c.backgroundTasks[task.id]?.state ?? "?")")
            check(stopped, "Stop stops it")
        }
        try? FileManager.default.removeItem(at: file)
        ws.closeSession(s.id)
    }

    // MARK: Queue

    /// A message sent while a turn runs isn't lost: it queues (the composer
    /// keeps nothing, the footer says so) and goes when the turn ends. Uses
    /// the signed-in account (two tiny turns).
    private static func queueWhileWorking(_ window: MainWindowController) async {
        guard let tree = window.paneTree, let ws = window.workspaceController,
              let s = ws.newChatInCurrentContext() else { return log("no window") }
        func chat() -> ChatSession? { tree.surfaces.chats[s.id]?.session }
        check(await until(600) { chat()?.phase == .ready }, "chat starts")
        guard let c = chat() else { return }
        func said() -> String { c.items.compactMap { if case .agentText(_, let t) = $0 { t } else { nil } }.joined(separator: "\n") }
        c.send(text: "Count from 1 to 40, one number per line, nothing else.", attachments: [])
        check(await until(60) { c.phase == .running }, "a turn is running")
        check(c.submit(text: "Now reply with exactly the word QUEUED and nothing else.", attachments: []),
              "a message sent mid-turn is taken")
        check(c.hasQueued, "and waits its turn")
        check(await until(240) { c.phase == .ready && said().contains("QUEUED") }, "then goes when the turn ends")
        check(!c.hasQueued, "and nothing is left waiting")
        ws.closeSession(s.id)
    }

    // MARK: Sandshell kits

    /// A new workspace gets Sandshell's own kits; its Claude sandbox is created
    /// with sandshell-claude, so chats have Undo and MCP. Turned off, a rebuilt
    /// sandbox runs chats plain and those features hide. Needs a fresh folder.
    private static func kitExtras(_ window: MainWindowController) async {
        guard let ws = window.workspaceController, let tree = window.paneTree else { return log("no window") }
        check(ws.kits.contains("sandshell-claude") && ws.kits.contains("sandshell-codex"),
              "the workspace lists Sandshell's kits (\(ws.kits))")
        check(KitStore.resolve("sandshell-claude").hasSuffix("Contents/Resources/kits/sandshell-claude"),
              "they resolve to the app's bundled copies")
        guard let a = ws.newChatInCurrentContext() else { return check(false, "a chat") }
        func chat(_ id: UUID) -> ChatSession? { tree.surfaces.chats[id]?.session }
        check(await until(900) { chat(a.id)?.phase == .ready }, "the chat starts (sandbox created with the kit)")
        check(chat(a.id)?.hasExtras == true, "its agent runs under the kit's wrapper")
        if let c = chat(a.id) {
            let mcp = await until(20) { c.mcpServers != nil }
            check(mcp, "MCP status loads by itself")
            // The /context breakdown, through the wrapper (Session Details' Context card).
            await c.refreshContextUsage()
            let usage = c.contextUsage
            log("context: \(usage.map { "\($0.percentage)% of \($0.maxTokens), \($0.categories.map(\.name))" } ?? c.contextUsageUnavailable ?? "nil")")
            check(usage.map { $0.maxTokens > 0 && $0.categories.contains { $0.kind == .used && $0.tokens > 0 } } == true,
                  "the context breakdown comes back with used categories")
            check(usage?.categories.contains { $0.kind == .free } == true, "and the free space")
        }
        // The full Undo / Stop / MCP round trip.
        ws.closeSession(a.id)
        await chatExtras(window)

        // Off: the sandbox is rebuilt without it, and chats run plain.
        ws.applyKits(ws.kits.filter { $0 != "sandshell-claude" })
        guard let b = ws.newChatInCurrentContext() else { return check(false, "a chat after turning it off") }
        check(await until(900) { chat(b.id)?.phase == .ready }, "a chat starts in the rebuilt sandbox")
        check(chat(b.id)?.hasExtras == false, "without the kit there's no wrapper, so no Undo or MCP")
        ws.closeSession(b.id)
        ws.applyKits(ws.kits + ["sandshell-claude"])   // leave it as a new workspace would be
    }

    // MARK: Warm chats

    /// After one chat starts, the next like it claims a spare agent that's
    /// already up and through `initialize`, and is ready sooner — and works.
    private static func warmChats(_ window: MainWindowController) async {
        guard let tree = window.paneTree, let ws = window.workspaceController,
              let a = ws.newChatInCurrentContext() else { return log("no window") }
        func chat(_ id: UUID) -> ChatSession? { tree.surfaces.chats[id]?.session }
        check(await until(600) { chat(a.id)?.phase == .ready }, "the first chat starts")
        await wait(6)   // the spare comes up behind it
        guard let b = ws.newChatInCurrentContext() else { return check(false, "a second chat") }
        check(await until(120) { chat(b.id)?.phase == .ready }, "the second chat starts")
        let first = chat(a.id)?.readyAfter ?? 0, second = chat(b.id)?.readyAfter ?? 0
        log(String(format: "ready after: first %.2fs (warm %@), second %.2fs (warm %@)", first,
                   "\(chat(a.id)?.startedWarm ?? false)", second, "\(chat(b.id)?.startedWarm ?? false)"))
        check(chat(b.id)?.startedWarm == true, "the second claims the warm spare")
        check(second < first, "and is ready sooner")
        if let c = chat(b.id) {
            c.send(text: "Reply with exactly the word PONG and nothing else.", attachments: [])
            check(await until(180) {
                c.phase == .ready && c.items.contains { if case .agentText(_, let t) = $0 { t.contains("PONG") } else { false } }
            }, "the warm chat answers")
        }
        ws.closeSession(a.id)
        ws.closeSession(b.id)
    }

    // MARK: Commits

    /// Files' Commits list: a branch's commits since its base, and picking a
    /// commit lists only its files (+/- counts) with its diff in the editor.
    /// Needs the `files` fixture (a git repo whose history includes "init").
    private static func commitsView(_ window: MainWindowController) async {
        // History logic on a scratch repo: a feature branch off main.
        let scratch = URL(fileURLWithPath: out).appendingPathComponent("commits-repo")
        try? FileManager.default.removeItem(at: scratch)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        func sh(_ args: String...) { _ = GitStatus.git(["-C", scratch.path, "-c", "user.name=T", "-c", "user.email=t@t"] + args) }
        func write(_ name: String, _ text: String) { try? text.write(to: scratch.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        sh("init", "-q", "-b", "main")
        write("a.txt", "one\n"); sh("add", "."); sh("commit", "-qm", "base")
        sh("checkout", "-qb", "feature")
        write("a.txt", "one\ntwo\n"); write("b.txt", "bee\n"); sh("add", "."); sh("commit", "-qm", "feature work")
        write("c.txt", "new\n")   // untracked
        let history = GitHistory.commits(repo: scratch.path)
        check(history.base != nil && history.commits.map(\.subject) == ["feature work"],
              "a feature branch lists its own commits since main (\(history.commits.map(\.subject)))")
        if let base = history.base {
            let all = GitHistory.files(repo: scratch.path, scope: .all(base: base), untracked: [scratch.path + "/c.txt"])
            check(all.map { ($0.path as NSString).lastPathComponent } == ["a.txt", "b.txt", "c.txt"]
                  && all.first?.added == 1 && all.first?.removed == 0,
                  "All changes: the branch's files plus untracked, with counts")
        }
        if let c = history.commits.first {
            let files = GitHistory.files(repo: scratch.path, scope: .commit(c))
            check(files.map { ($0.path as NSString).lastPathComponent } == ["a.txt", "b.txt"]
                  && files.last?.change == .added, "a commit lists just its files (b.txt added)")
        }

        // The Files UI on the fixture.
        window.toggleFiles()
        guard await until(10, { window.inspectorFiles?.tree.git.repoRoot != nil }),
              let files = window.inspectorFiles else { return check(false, "Files shows the fixture repo") }
        let tree = files.tree
        check(await until(10) { !tree.commits.isHidden && tree.commits.rows.count >= 2 }, "the Commits section lists history")
        log("commit rows: \(tree.commits.rows)")
        guard let i = tree.commits.rows.firstIndex(where: { if case .commit(let c) = $0 { c.subject == "init" } else { false } }) else {
            return check(false, "the init commit is listed")
        }
        tree.commits.debugPick(i)
        check(await until(10) { tree.changedOnly && !tree.debugListRows.isEmpty }, "picking a commit shows its files")
        let rows = tree.debugListRows
        log("init commit rows: \(rows)")
        check(rows.contains { $0.hasPrefix("src/app.py +") } && !rows.contains { $0.contains("·") },
              "its files show +/- counts (src/app.py among them)")
        if let row = rows.firstIndex(where: { $0.hasPrefix("src/app.py") }) {
            tree.debugOpenRow(row)
            check(await until(10) { files.editor.previewText?.string.contains("+def f0():") == true },
                  "opening one shows the commit's diff")
            check(tree.debugChangedTitle.hasSuffix("files in ea0f97b") || tree.debugChangedTitle.contains("files in"),
                  "the toggle says whose files these are (\(tree.debugChangedTitle))")
            // Line numbers in the gutter; one clicked asks the agent for a change there.
            check(files.editor.previewText?.string.contains("    1 +def f0():") == true, "diff lines carry their line numbers")
            var asked: String?
            let keep = files.onAskAgent
            files.onAskAgent = { asked = $0 }
            check(files.editor.debugAsk(line: 1, "Rename f0 to first."), "line 1's number opens the ask box")
            log("asked: \(asked ?? "nil")")
            check(asked?.contains("line 1 of `src/app.py`") == true && asked?.contains("def f0():") == true
                  && asked?.hasSuffix("Rename f0 to first.") == true, "the agent gets the file, line, its code and the ask")
            files.onAskAgent = keep
            await wait(0.8)
            snapshot(files.view, "commits-init")
        }
        // Back to Uncommitted: the working tree's changes again.
        if let u = tree.commits.rows.firstIndex(of: .uncommitted) {
            tree.commits.debugPick(u)
            check(await until(10) { tree.scope == .uncommitted && tree.debugListRows.contains { $0.hasPrefix("src/app.py +") } },
                  "Uncommitted changes lists the working tree's edits")
        }
    }

    // MARK: Codex chat

    /// A Codex chat signs in through sbx's proxy like `sbx run codex` does,
    /// even in a sandbox `sbx run` never started. Uses the workspace's root folder.
    private static func codexChat(_ window: MainWindowController) async {
        guard let ws = window.workspaceController, let tree = window.paneTree,
              let folder = ws.rootFolder?.id ?? ws.folders.first?.id else { return log("no window") }
        guard let s = ws.addSession(folderID: folder, agent: .codex, chat: true) else { return log("no session") }
        ws.selection = .session(s.id)
        func chat() -> ChatSession? { tree.surfaces.chats[s.id]?.session }
        let ready = await until(600) { chat()?.phase == .ready || { if case .closed = chat()?.phase { true } else { false } }() }
        log("codex chat phase: \(String(describing: chat()?.phase)) models: \(chat()?.models.count ?? 0)")
        check(ready && chat()?.phase == .ready, "a Codex chat reaches ready (signed in through sbx)")
        if let c = chat(), c.phase == .ready {
            // Codex's own default model can be one a ChatGPT sign-in can't use:
            // the chat moves to one it can and the prompt still gets its answer.
            c.send(text: "Reply with exactly the word PONG and nothing else.", attachments: [])
            let answered = await until(300) {
                c.phase == .ready && c.items.contains { if case .agentText(_, let t) = $0 { t.contains("PONG") } else { false } }
            }
            let notes = c.items.compactMap { if case .notice(_, let t, _) = $0 { t } else { nil } }
            log("codex model \(c.currentModel ?? "-"), notices \(notes)")
            check(answered, "a Codex prompt gets its answer")
        }
        snapshot(window, "codex-chat")
        ws.closeSession(s.id)
    }

    // MARK: Tables

    /// Markdown tables: a small one is a grid in the prose face; a wide one
    /// becomes a record per row. Either way, no stray ** or table pipes.
    private static func tables() async {
        let small = """
            | Size | Price | Note |
            |------|------:|------|
            | S | $1 | **cheap** |
            | XL | $120 | `big` |
            """
        let wide = """
            What each one is

            | | **Unsloth Studio** | **Hatch** (`feat/approval-gate`) |
            |---|---|---|
            | **Problem** | A local model runs shell and Python tool calls on the user's machine. Contain the blast radius. | A sandboxed agent (Docker `sbx`) needs host-native tools (xcodebuild, GUI automation, screen capture). Control what crosses the boundary. |
            | **Where the boundary sits** | Around the tool process, on the same machine as the user's files. | Between the sandbox and the host, at the MCP `tools/call` layer. |
            | **Default posture** | Run, but confined. | Ask, except for inspect-only tools. If no approver answers within 120 s, deny. |
            | **Escaped \\| pipe** | a \\| b | |
            """
        let view = ChatTranscriptView(frame: NSRect(x: 0, y: 0, width: 720, height: 560))
        let host = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        host.isReleasedWhenClosed = false
        host.alphaValue = 0
        host.contentView = view
        view.update([.agentText(id: "s", text: small), .agentText(id: "w", text: wide)])
        await wait(0.4)
        let text = view.debugText
        log("rendered:\n\(text)")
        check(!text.contains("**") && !text.contains("|---"), "no raw Markdown in tables")
        check(text.contains("S\t$1\tcheap") && text.contains("Size\tPrice\tNote"), "a small table is a grid on tab stops")
        check(text.contains("Problem\nUnsloth Studio\tA local model runs"), "a wide table reads as records: heading, then labelled values")
        check(text.contains("Hatch (feat/approval-gate)\tA sandboxed agent"), "labels keep their inline code")
        check(text.contains("Escaped | pipe") && text.contains("a | b"), "escaped pipes stay in their cell")
        snapshot(view, "tables")
        host.close()
    }

    // MARK: Title strip

    /// A Claude readout beside the context chips: as the window narrows the
    /// readout drops its optional pieces before the folder chip loses its name.
    /// (Uses a shell session with a fake status; the strip doesn't care.)
    private static func titleStrip(_ window: MainWindowController) async {
        guard let tree = window.paneTree, let ws = window.workspaceController,
              let a = ws.orderedSessions.first(where: { $0.agent == .shell }), let w = window.window else { return log("need a shell session") }
        ws.selection = .session(a.id)
        check(await until(300) { tree.surfaces.terminals[a.id] != nil }, "session launches")
        await wait(1.0)
        let json = #"""
            {"model":{"id":"claude-opus-5-5","display_name":"Opus 5.5"},"effort":{"level":"high"},
             "context_window":{"total_input_tokens":1234567,"total_output_tokens":456789,
                               "context_window_size":1000000,"used_percentage":42},
             "cost":{"total_cost_usd":12.34}}
            """#
        let status = try? JSONDecoder().decode(ClaudeSessionStatus.self, from: Data(json.utf8))
        check(status?.model != nil, "fake status decodes")
        guard let pane = tree.panes.first else { return check(false, "a pane") }
        pane.debugShowClaudeReadout(status)
        func measure(_ name: String, folderAtLeast: CGFloat? = nil) async {
            await wait(0.6)
            let m = pane.debugTitleStripWidths
            log("\(name): strip \(Int(m.strip)) folder \(Int(m.folder))/\(Int(m.folderWanted)) readout \(Int(m.readout)) budget \(m.budget > 99999 ? "∞" : "\(Int(m.budget))")")
            log(pane.debugReadoutFitting)
            check(m.readout <= max(m.budget, 16) + 1, "\(name): the readout stays within its budget")
            check(m.folderWanted > 60 && m.folder >= (folderAtLeast ?? m.folderWanted - 1), "\(name): the folder chip keeps its name")
            snapshot(window, "title-strip-\(name)")
        }
        for width in [1400.0, 1100, 900] {
            var frame = w.frame
            frame.size.width = width
            w.setFrame(frame, display: true)
            await measure("window-\(Int(width))")
            let t = window.debugToolbarWidths
            log("  toolbar at \(Int(width)): identity \(Int(t.identity)) status \(Int(t.status)) visible \(t.visible)/\(t.items)")
            check(t.visible == t.items && t.identity >= 199 && t.identity <= 361,
                  "at \(Int(width)) the toolbar fits every item; the identity flexes within 200–360")
        }
        // A long session name truncates inside the identity item instead of
        // drawing over the status and buttons beside it.
        for width in [1000.0, 1300] {
            var frame = w.frame
            frame.size.width = width
            w.setFrame(frame, display: true)
            _ = window.debugToolbarName("New Claude Session with a long name, longer than the toolbar has room for")
            await wait(0.8)
            let long = window.debugToolbarName("New Claude Session with a long name, longer than the toolbar has room for")
            log("long name at \(Int(width)): label ends at \(Int(long.label)) of \(Int(long.identity))")
            check(long.label <= long.identity + 1 && long.identity <= 361, "at \(Int(width)) a long session name stays inside the identity item")
            check(long.label >= long.identity - 4 && long.identity >= 199,
                  "at \(Int(width)) the name uses the identity's whole width (\(Int(long.label)) of \(Int(long.identity)))")
            // A name that fits isn't cut short to the subtitle's width.
            _ = window.debugToolbarName("New Claude Session", subtitle: "msdgc · ~/Code/msdgc")
            await wait(0.8)
            _ = window.debugToolbarName("New Claude Session", subtitle: "msdgc · ~/Code/msdgc")
            check(window.debugToolbarNameFits, "at \(Int(width)) “New Claude Session” shows whole")
        }
        // A narrow split pane: the readout is down to its model chooser.
        tree.split(pane, edge: .trailing, showing: nil)
        await measure("split", folderAtLeast: 80)
        check(pane.debugTitleStripWidths.readout < 24, "split: the readout is down to ⓘ")
    }

    // MARK: Links

    /// Paths that exist (relative or absolute, with :line) and URLs become links.
    private static func links() {
        let view = ChatTranscriptView()
        view.workdir = FileManager.default.currentDirectoryPath
        view.debugApplyNow([.agentText(id: "a", text:
            "See Sandshell/Chat/ChatSessionView.swift:12, the docs at https://example.com/x, "
            + "/usr/bin/git and /no/such/thing.swift.")])
        let links = view.debugLinks
        log("links: \(links.map { "\($0.0) → \($0.1)" })")
        check(links.contains { $0.0 == "Sandshell/Chat/ChatSessionView.swift" && $0.1.hasSuffix("ChatSessionView.swift#L12") },
              "a relative path with :line links to the file at that line")
        check(links.contains { $0.0 == "https://example.com/x" }, "a URL is a link")
        check(links.contains { $0.0 == "/usr/bin/git" }, "an absolute path that exists is a link")
        check(!links.contains { $0.0.contains("no/such") }, "a path that doesn't exist isn't")

        // No fork handler here (as in a subagent's window): the hover bar is Copy alone.
        view.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        view.layoutSubtreeIfNeeded()
        view.debugHoverFirstReply()
        check(view.debugReplyActionsShown && !view.debugForkShown, "a transcript that can't fork hovers Copy alone")

        // Paths with spaces: quoted, backslash-escaped, or bare.
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("sandshell-links-\(UUID().uuidString.prefix(6))")
        let file = dir.appendingPathComponent("My Folder/Read Me.txt")
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? "hi".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: dir) }
        let spaced = ChatTranscriptView()
        spaced.workdir = dir.path
        spaced.debugApplyNow([.agentText(id: "b", text:
            "Quoted `My Folder/Read Me.txt:3`, escaped My\\ Folder/Read\\ Me.txt, and bare \(file.path), done. "
            + "Not `My Folder/Nope.txt`.")])
        let spacedLinks = spaced.debugLinks
        log("spaced links: \(spacedLinks.map { "\($0.0) → \($0.1)" })")
        check(spacedLinks.contains { $0.0 == "My Folder/Read Me.txt" && $0.1.hasSuffix("#L3") },
              "a quoted path with spaces links, with its line")
        check(spacedLinks.contains { $0.0 == "My\\ Folder/Read\\ Me.txt" }, "a backslash-escaped path links")
        check(spacedLinks.contains { $0.0 == file.path }, "a bare absolute path with spaces links whole")
        check(!spacedLinks.contains { $0.0.contains("Nope") }, "a quoted path that doesn't exist doesn't")
    }
}
#endif
