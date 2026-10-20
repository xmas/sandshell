#if DEBUG
import AppKit
import SwiftUI

/// `remote`: Remote Control end to end, as a device sees it — over HTTP on
/// loopback against this app's own server, with the fake ACP agent (no
/// sandbox, no tokens). Any workspace will do: the window's own sessions are
/// only used to check the per-session switch, with a fake chat put in place.
extension SelfTest {
    static func remote(_ window: MainWindowController) async {
        let defaults = UserDefaults.standard
        // Any free port: the user's own Sandshell may hold the usual one.
        defaults.set(0, forKey: "SandshellRemotePort")
        defer { defaults.removeObject(forKey: "SandshellRemotePort") }
        let hub = RemoteHub.shared
        hub.setCheckSession(true)
        defer { hub.setCheckSession(false) }
        guard await until(10, { hub.port != nil }), let base = hub.localURL else {
            return check(false, "the server starts when there's something to serve")
        }
        check(true, "the server starts for the check session (\(base.absoluteString))")
        let client = RemoteTestClient(base: base)

        // Info, files, guards.
        let info = try? await client.json("api/info")
        let sessions = info?["sessions"]?.array ?? []
        let checkID = hub.checkSessionID
        check(sessions.contains { $0["id"]?.string == checkID.uuidString && $0["isCheck"]?.bool == true },
              "/api/info lists the check session")
        let page = await client.get("")
        check(page.status == 200 && String(decoding: page.body, as: UTF8.self).contains("app.js"), "/ serves the web client")
        check(await client.get("s/\(checkID.uuidString)").status == 200, "a chat's own address serves the client too")
        check(await client.get("app.js").status == 200, "the client's script is served")
        check(await client.get("../Info.plist").status == 404, "nothing outside the web folder is served")
        check(await client.post("api/sessions/\(checkID.uuidString)/send", ["text": "hi"], marked: false).status == 403,
              "a POST without X-Sandshell is refused")
        check(await client.get("api/info", host: "evil.example").status == 403, "a request for another host name is refused")

        // Follow the check session as a device would.
        let device = RemoteTestDevice(base: base, session: checkID)
        defer { device.stop() }
        check(await until(15) { device.hello != nil && device.state != nil }, "the event stream says hello, then the session's state")
        check(await until(30) { device.status?.phase == .ready }, "the fake agent comes up (ready)")
        check(device.status?.modes.map(\.id) == ["default", "plan"], "its modes come with it")

        func send(_ text: String, images: [[String: String]] = []) async -> Int {
            await client.post("api/sessions/\(checkID.uuidString)/send", ["text": .string(text),
                "images": .array(images.map { .object($0.mapValues(JSONValue.string)) })]).status
        }
        func reply(_ test: @escaping (String) -> Bool) async -> Bool {
            await until(15) { device.texts.contains(where: test) }
        }
        func ready() async -> Bool {
            await until(15) { device.status?.phase == .ready && device.status?.permission == nil && device.status?.question == nil }
        }

        check(await send("hello from the self-test") == 200, "send is accepted")
        check(await reply { $0.contains("pong: hello from the self-test") }, "the reply streams back as patches")
        check(device.items.contains { $0.kind == .user && $0.text == "hello from the self-test" }, "the prompt is in the transcript")
        check(device.status?.usage != nil, "usage comes with the turn")
        _ = await ready()

        _ = await send("show me an image")
        check(await until(15) { device.items.contains { $0.kind == .image } }, "an image item arrives")
        if let path = device.items.first(where: { $0.kind == .image })?.image {
            let image = await client.get(String(path.dropFirst()))
            check(image.status == 200 && image.headers["content-type"] == "image/png" && NSImage(data: image.body) != nil,
                  "its address serves the PNG")
        }
        _ = await ready()

        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!
        check(await send("", images: [["name": "dot.png", "mimeType": "image/png", "data": png.base64EncodedString()]]) == 200,
              "an image-only message is accepted")
        check(await reply { $0.contains("I got 1 image") }, "the agent gets the image")
        check(await send("", images: [["name": "notes.txt", "mimeType": "text/plain", "data": "aGk="]]) == 415,
              "a file that isn't an image is refused")
        _ = await ready()

        _ = await send("ask permission")
        check(await until(15) { device.status?.permission != nil }, "a permission prompt reaches the device")
        if let p = device.status?.permission {
            check(p.options.map(\.id) == ["allow_once", "allow_always", "reject_once"], "with its options")
            check(await client.post("api/sessions/\(checkID.uuidString)/permission",
                                    ["permission": "not-this-one", "option": "allow_once"]).status == 409,
                  "an answer to another prompt is refused as stale")
            check(await client.post("api/sessions/\(checkID.uuidString)/permission",
                                    ["permission": .string(p.id), "option": "allow_once"]).status == 200, "Allow is accepted")
            check(await reply { $0.contains("Permission: allow_once") }, "the agent got Allow")
            check(await until(5) { device.status?.permission == nil }, "the prompt goes away")
        }
        _ = await ready()

        _ = await send("ask a question")
        check(await until(15) { device.status?.question != nil }, "a question reaches the device")
        if let q = device.status?.question {
            check(q.fields.first?.kind == "choice" && q.fields.first?.options?.map(\.id) == ["red", "green", "blue"],
                  "as a choice with its options")
            check(await client.post("api/sessions/\(checkID.uuidString)/question",
                                    ["question": .string(q.id), "action": "accept", "content": ["colour": "green"]]).status == 200,
                  "the answer is accepted")
            check(await reply { $0.contains("Answer: accept green") }, "the agent got the answer")
        }
        _ = await ready()

        check(await client.post("api/sessions/\(checkID.uuidString)/mode", ["mode": "plan"]).status == 200, "a mode change is accepted")
        check(await until(5) { device.status?.currentMode == "plan" }, "the mode change comes back")
        check(await client.post("api/sessions/\(checkID.uuidString)/mode", ["mode": "nope"]).status == 400, "an unknown mode is refused")

        _ = await send("slow")
        check(await until(10) { device.status?.phase == .running }, "a slow turn runs")
        check(await client.post("api/sessions/\(checkID.uuidString)/cancel", [:]).status == 200, "Stop is accepted")
        check(await until(10) { device.status?.phase == .ready }, "the turn stops")

        _ = await send("long")
        check(await reply { $0.contains("the end.") }, "a long streamed reply arrives whole")
        let longText = device.texts.first { $0.contains("A long reply") } ?? ""
        check(longText.contains("word120") && longText.contains("word240"), "with every chunk, in order")
        check(device.patches > 5, "as patches, not a state per change (\(device.patches) patches)")
        _ = await ready()

        // A second device joining mid-way sees the same transcript.
        let late = RemoteTestDevice(base: base, session: checkID)
        defer { late.stop() }
        check(await until(10) { late.state != nil }, "a second device gets the state")
        check(late.items.map(\.id) == device.items.map(\.id), "the same items, in the same order")
        _ = await send("both see this")
        check(await until(15) { late.texts.contains { $0.contains("pong: both see this") } && device.texts.contains { $0.contains("pong: both see this") } },
              "both devices get the patches")

        // The check report endpoint.
        check(await client.post("api/check", ["device": "SelfTest", "userAgent": "selftest",
                                              "results": [["name": "x", "ok": true, "detail": ""]]]).status == 200,
              "a device's check report is accepted")
        check(hub.checkReports.contains { $0.device == "SelfTest" && $0.passed }, "and kept")

        await perSessionSwitch(window, hub: hub, base: base)
        stripSwitch()
        await popoverPlacement()

        // Off: devices following it are told.
        hub.setCheckSession(false)
        check(await until(5) { device.gone }, "a device following a session that goes away is told")
        check(await until(5) { hub.port == nil }, "the server stops when there's nothing to serve")
    }

    /// The pane strip's switch: hidden but for a chat, then off or on.
    private static func stripSwitch() {
        let strip = PaneStripView(frame: NSRect(x: 0, y: 0, width: 900, height: 34))
        let host = NSWindow(contentRect: strip.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        host.isReleasedWhenClosed = false
        host.alphaValue = 0
        host.contentView = strip
        defer { host.close() }
        func button() -> NSButton? {
            strip.descendants.compactMap { $0 as? NSButton }.first { $0.accessibilityIdentifier() == "pane-remote" }
        }
        strip.layoutSubtreeIfNeeded()
        check(button()?.isHidden == true, "the strip shows no Remote Control switch until it's a chat")
        strip.setSessionControls(stop: nil, restart: true)
        strip.setRemote(false)
        strip.layoutSubtreeIfNeeded()
        check(button().map { !$0.isHidden && $0.frame.width > 0 } == true && button()?.accessibilityValue() as? String == "off",
              "a chat's strip shows the switch, off")
        snapshot(strip, "remote-switch-off")
        strip.setRemote(true)
        strip.layoutSubtreeIfNeeded()
        check(button()?.accessibilityValue() as? String == "on" && button()?.contentTintColor == .controlAccentColor,
              "turned on, it reads on, in the accent colour")
        snapshot(strip, "remote-switch-on")

        // Its popover, off and then on (the server's up: the check session runs).
        let id = UUID()
        for on in [false, true] {
            var flipped: Bool?
            let popover = NSHostingView(rootView: RemoteControlPopover(hub: .shared, sessionID: id, isOn: on) { flipped = $0 })
            popover.frame.size = popover.fittingSize
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: popover.frame.size), styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.alphaValue = 0
            window.contentView = popover
            snapshot(popover, on ? "remote-popover-on" : "remote-popover-off")
            check(flipped == nil, "showing the popover changes nothing")
            window.close()
        }
        check(RemoteHub.shared.localURL(for: id)?.absoluteString.hasSuffix("/s/\(id.uuidString)") == true,
              "the popover's address is the chat's own page")
    }

    /// The popover opens right under the antenna, on and off (a popover whose
    /// content sizes itself late gets slid away from its arrow).
    private static func popoverPlacement() async {
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 900, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        let strip = PaneStripView(frame: NSRect(x: 0, y: 700 - 34, width: 900, height: 34))
        strip.autoresizingMask = [.width, .minYMargin]
        window.contentView?.addSubview(strip)
        window.orderBack(nil)
        defer { window.close() }
        strip.setSessionControls(stop: nil, restart: true)
        guard let button = strip.descendants.compactMap({ $0 as? NSButton }).first(where: { $0.accessibilityIdentifier() == "pane-remote" })
        else { return check(false, "the strip's Remote Control button") }
        for on in [true, false] {
            strip.setRemote(on)
            strip.layoutSubtreeIfNeeded()
            var slot: NSPopover?
            let view = RemoteControlPopover(hub: .shared, sessionID: UUID(), isOn: on) { _ in }
            let popover = NSPopover.toggle(&slot, below: button, behavior: .applicationDefined) {
                RemoteControlPopover.controller(view)
            }
            popover?.contentViewController?.view.window?.alphaValue = 0
            await wait(0.6)
            let anchor = button.window?.convertToScreen(button.convert(button.bounds, to: nil)) ?? .zero
            let frame = popover?.contentViewController?.view.window?.frame ?? .zero
            let gap = anchor.minY - frame.maxY
            log("popover (\(on ? "on" : "off")): anchor \(anchor), popover \(frame), gap \(gap)")
            check(frame.height > 60 && gap > -4 && gap < 30 && abs(frame.midX - anchor.midX) < frame.width / 2,
                  "the popover (\(on ? "on" : "off")) opens right under the antenna")
            popover?.close()
        }
    }

    /// A window session shows up only while Remote Control is on for it.
    private static func perSessionSwitch(_ window: MainWindowController, hub: RemoteHub, base: URL) async {
        guard let tree = window.paneTree, let ws = window.workspaceController, let folder = ws.folders.first,
              let s = ws.addSession(folderID: folder.id, agent: .claude, chat: true) else {
            return check(false, "a chat session in the window")
        }
        // A fake chat where its real one would be (no sandbox).
        let dir = FileManager.default.temporaryDirectory.appending(path: "sandshell-remote-switch")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let chat = ChatSession(title: "Fake", agent: .claude, containerName: "remote-switch", workdir: dir.path,
                               home: dir.path, mcpURL: nil, sessionID: s.id)
        if let script = RemoteHub.fakeAgentScript { chat.launchOverride = ("/usr/bin/python3", ["-I", script.path]) }
        let view = ChatSessionView(session: chat)
        tree.surfaces.chats[s.id] = view
        ws.setLive(s.id, true)
        chat.start()
        defer {
            chat.close()
            tree.surfaces.chats[s.id] = nil
            ws.setLive(s.id, false)
            ws.closeSession(s.id)
        }
        await wait(0.3)
        check(!hub.summaries.contains { $0.id == s.id }, "a chat with Remote Control off isn't listed")
        ws.setRemote(s.id, true)
        check(ws.session(id: s.id)?.isRemote == true, "the switch is saved on the session")
        check(await until(5) { hub.summaries.contains { $0.id == s.id } }, "turned on, it's listed")
        let device = RemoteTestDevice(base: base, session: s.id)
        defer { device.stop() }
        check(await until(30) { device.status?.phase == .ready }, "a device can follow it")
        ws.setRemote(s.id, false)
        check(await until(5) { !hub.summaries.contains { $0.id == s.id } }, "turned off, it's gone from the list")
        check(await until(5) { device.gone }, "and the device following it is told")
        let refused = await RemoteTestClient(base: base).post("api/sessions/\(s.id.uuidString)/send", ["text": "hi"])
        check(refused.status == 404, "and can't send to it any more")
    }
}

private extension NSView {
    /// Every view under this one.
    var descendants: [NSView] { subviews + subviews.flatMap(\.descendants) }
}

/// Plain HTTP calls against the server.
@MainActor
struct RemoteTestClient {
    let base: URL
    struct Reply { var status: Int; var headers: [String: String]; var body: Data }

    func get(_ path: String, host: String? = nil) async -> Reply {
        var request = URLRequest(url: base.appending(path: path))
        if let host { request.setValue(host, forHTTPHeaderField: "Host") }
        return await perform(request)
    }

    func json(_ path: String) async throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: await get(path).body)
    }

    func post(_ path: String, _ body: JSONValue, marked: Bool = true) async -> Reply {
        var request = URLRequest(url: base.appending(path: path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if marked { request.setValue("1", forHTTPHeaderField: "X-Sandshell") }
        request.httpBody = try? JSONEncoder().encode(body)
        return await perform(request)
    }

    private func perform(_ request: URLRequest) async -> Reply {
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else { return Reply(status: 0, headers: [:], body: Data()) }
        var headers: [String: String] = [:]
        for (k, v) in http.allHeaderFields { headers[String(describing: k).lowercased()] = String(describing: v) }
        return Reply(status: http.statusCode, headers: headers, body: data)
    }
}

/// A device following one session over the event stream, keeping the
/// transcript the way the web client does.
@MainActor
final class RemoteTestDevice {
    private(set) var hello: JSONValue?
    private(set) var state: RemoteWire.State?
    private(set) var items: [RemoteWire.Item] = []
    private(set) var status: RemoteWire.Status?
    private(set) var patches = 0
    private(set) var gone = false
    private var task: Task<Void, Never>?

    var texts: [String] { items.filter { $0.kind == .text }.compactMap(\.text) }

    init(base: URL, session: UUID) {
        var components = URLComponents(url: base.appending(path: "api/events"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "session", value: session.uuidString)]
        let url = components.url!
        task = Task { [weak self] in
            do {
                let (bytes, _) = try await URLSession.shared.bytes(from: url)
                var event = "message"
                // One `data:` line per event, right after its `event:` line.
                for try await line in bytes.lines {
                    if line.hasPrefix("event: ") { event = String(line.dropFirst(7)) }
                    else if line.hasPrefix("data: ") {
                        self?.receive(event, Data(line.dropFirst(6).utf8))
                        event = "message"
                    }
                }
            } catch {}
        }
    }

    func stop() { task?.cancel() }

    private func receive(_ event: String, _ data: Data) {
        let decoder = JSONDecoder()
        switch event {
        case "hello": hello = try? decoder.decode(JSONValue.self, from: data)
        case "state":
            guard let s = try? decoder.decode(RemoteWire.State.self, from: data) else { return }
            state = s
            items = s.items
            status = s.status
        case "patch":
            guard let p = try? decoder.decode(RemoteWire.Patch.self, from: data) else { return }
            patches += 1
            for item in p.upserts {
                if let i = items.firstIndex(where: { $0.id == item.id }) { items[i] = item } else { items.append(item) }
            }
            if let order = p.order {
                let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
                items = order.compactMap { byID[$0] }
            }
            if let s = p.status { status = s }
        case "gone": gone = true
        default: break
        }
    }
}
#endif
