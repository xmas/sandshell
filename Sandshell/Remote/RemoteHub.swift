import AppKit
import Combine
import Foundation

/// Remote Control's view of the app: the chats devices may see (every open
/// window's chats with Remote Control on, plus the DEBUG check session), each
/// device's event stream, and the commands devices send — which call the same
/// `ChatSession` methods the window does. Runs the server while there's
/// anything to serve.
@MainActor
final class RemoteHub: ObservableObject {
    static let shared = RemoteHub()

    /// The port devices use (`SandshellRemotePort` overrides it; 0: any free one).
    static let defaultPort: UInt16 = 47820

    /// One chat a device can open.
    private struct Source {
        let chat: ChatSession
        let summary: () -> RemoteWire.SessionSummary
    }

    /// One device's event stream, following one session (or none: just the list).
    private final class Subscriber {
        let stream: HTTPServer.EventStream
        let session: UUID?
        /// The paired device it belongs to (nil: this Mac).
        let device: UUID?
        init(stream: HTTPServer.EventStream, session: UUID?, device: UUID?) {
            self.stream = stream
            self.session = session
            self.device = device
        }
    }

    private var sources: [UUID: Source] = [:]
    private var refreshScheduled = false
    private var subscribers: [ObjectIdentifier: Subscriber] = [:]
    private var lastSummaries: [RemoteWire.SessionSummary] = []

    private var server: HTTPServer?
    private var serverStarting = false
    /// Where devices reach the server, once it's up (nil: not serving).
    @Published private(set) var port: UInt16?
    /// The server came up or went down.
    var onServing: ((UInt16?) -> Void)?
    /// Something wants the server up (a session with Remote Control on, a
    /// pairing, the check session).
    private var servingWanted = false
    /// Remote Control at all (Settings ▸ General): off, nothing is served, no
    /// chat shows its antenna, and sessions' switches are left as they were.
    @Published private(set) var isEnabled = UserDefaults.standard.object(forKey: "remoteControlEnabled") as? Bool ?? true
    /// Posted when `isEnabled` changes (panes show or hide the antenna).
    static let enabledChanged = Notification.Name("SandshellRemoteControlEnabledChanged")
    /// Listen on the home network too (paired devices only), not just this Mac.
    @Published private(set) var homeNetwork = UserDefaults.standard.bool(forKey: "remoteHomeNetwork")
    /// Answer on the tailnet too (paired devices only): reach a chat from anywhere.
    @Published private(set) var tailscaleOn = UserDefaults.standard.bool(forKey: "remoteTailscale")
    /// This Mac on Tailscale, last read (nil: not installed, or not read yet).
    @Published private(set) var tailscale: Tailscale.Status?
    /// The tailnet's names for this Mac, while Tailscale is on and connected.
    var tailnetNames: [String] { tailscaleOn ? tailscale?.hosts ?? [] : [] }
    private var tailscaleTimer: Timer?
    private var routes: RemoteRoutes?

    #if DEBUG
    /// The check session: a fake agent a device's /check page drives.
    private(set) var checkChat: ChatSession?
    private let checkID = UUID()
    #endif

    // MARK: Sources

    /// Re-read which chats devices may see (soon, once for a burst of changes).
    func setNeedsRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshScheduled = false
            self.refresh()
        }
    }

    /// Turn Remote Control on or off for the whole app. Off: the server stops
    /// now (devices are cut off), pairing ends; each chat's switch keeps its
    /// state for when it's back on.
    func setEnabled(_ on: Bool) {
        guard on != isEnabled else { return }
        isEnabled = on
        UserDefaults.standard.set(on, forKey: "remoteControlEnabled")
        Log.info(.app, "remote: Remote Control \(on ? "enabled" : "disabled")")
        if !on {
            RemotePairing.shared.cancel()
            refresh()
            stopServer()
        } else {
            refresh()
        }
        NotificationCenter.default.post(name: Self.enabledChanged, object: self)
    }

    func refresh() {
        var found: [UUID: Source] = [:]
        var anyRemote = false
        for surfaces in SessionSurfaces.live where isEnabled {
            let controller = surfaces.controller
            anyRemote = anyRemote || !controller.remoteSessions.isEmpty
            for (id, view) in surfaces.chats {
                guard let session = controller.session(id: id), session.isRemote else { continue }
                let chat = view.session
                found[id] = Source(chat: chat, summary: { [weak controller, weak chat] in
                    let session = controller?.session(id: id) ?? session
                    return RemoteWire.SessionSummary(
                        id: id, name: controller?.displayName(of: session) ?? session.displayName,
                        agent: session.agent.rawValue, agentName: session.agent.displayName,
                        folder: session.workdir.tildeAbbreviated,
                        phase: chat.map { .init($0.phase) } ?? .closed, waiting: chat?.waitingFor, isCheck: false)
                })
            }
        }
        #if DEBUG
        if let checkChat, isEnabled {
            let id = checkID
            found[id] = Source(chat: checkChat, summary: { [weak checkChat] in
                RemoteWire.SessionSummary(id: id, name: "Remote check", agent: AgentKind.claude.rawValue,
                                          agentName: "Fake agent", folder: "(no sandbox)",
                                          phase: checkChat.map { .init($0.phase) } ?? .closed,
                                          waiting: checkChat?.waitingFor, isCheck: true)
            })
        }
        #endif
        for id in Set(sources.keys).subtracting(found.keys) {
            sources[id]?.chat.feed.stopListening(self)
            for sub in subscribers.values where sub.session == id { sub.stream.send("gone", ["session": id]) }
        }
        var restarted: [UUID] = []
        for (id, source) in found where sources[id]?.chat !== source.chat {
            sources[id]?.chat.feed.stopListening(self)
            // What changed, to the devices following it (`ChatFeed`).
            source.chat.feed.listen(self) { hub, event in hub.forward(event, of: id) }
            if sources[id] != nil { restarted.append(id) }
        }
        sources = found
        // The session's chat was relaunched (a new one): its followers start over.
        for id in restarted {
            guard let source = sources[id] else { continue }
            let first = state(id, source)
            for sub in subscribers.values where sub.session == id { sub.stream.send("state", first) }
        }
        broadcastSummaries()
        servingWanted = isEnabled && (!found.isEmpty || anyRemote || RemotePairing.shared.current != nil)
        setServing(servingWanted)
    }

    var summaries: [RemoteWire.SessionSummary] {
        sources.values.map { $0.summary() }.sorted {
            $0.isCheck != $1.isCheck ? !$0.isCheck : $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    /// An agent's note (`sandshell-notify`): to every device listening, if
    /// its session is one they may see.
    func alert(session: UUID, title: String, message: String) {
        guard sources[session] != nil else { return }
        let alert = RemoteWire.Alert(session: session, title: title, message: message)
        for sub in subscribers.values { sub.stream.send("alert", alert) }
    }

    private func broadcastSummaries() {
        let now = summaries
        guard now != lastSummaries else { return }
        lastSummaries = now
        for sub in subscribers.values { sub.stream.send("sessions", now) }
    }

    // MARK: Changes

    /// A chat's change, to the devices following it; the list's summaries too
    /// (its phase, what it waits for).
    private func forward(_ event: ChatFeed.Event, of id: UUID) {
        guard let source = sources[id] else { return }
        let followers = subscribers.values.filter { $0.session == id }
        if !followers.isEmpty {
            switch event {
            case .state(let now):
                let state = state(of: source, now)
                for sub in followers { sub.stream.send("state", state) }
            case .patch(let patch):
                for sub in followers { sub.stream.send("patch", patch) }
            }
        }
        broadcastSummaries()
    }

    /// A session's state as a device first sees it: the base of the next
    /// patch (`ChatFeed.state` sends what's pending to those following first).
    private func state(_ id: UUID, _ source: Source) -> RemoteWire.State {
        state(of: source, source.chat.feed.state())
    }

    private func state(of source: Source, _ now: ChatFeed.Snapshot) -> RemoteWire.State {
        let shown = now.items.suffix(RemoteWire.initialItemLimit)
        return RemoteWire.State(session: source.summary(), status: now.status, items: Array(shown),
                                omitted: now.items.count - shown.count, rev: now.rev)
    }

    func state(_ id: UUID) -> RemoteWire.State? {
        sources[id].map { state(id, $0) }
    }

    // MARK: Devices

    struct Hello: Encodable {
        var version = RemoteWire.version
        let host: String
        let sessions: [RemoteWire.SessionSummary]
        /// The paired device asking, by name (nil: this Mac).
        var device: String?
    }

    static var hostName: String { Host.current().localizedName ?? "Mac" }

    func hello(for caller: RemoteRoutes.Caller) -> Hello {
        Hello(host: Self.hostName, sessions: summaries,
              device: caller.deviceID.flatMap { id in RemoteDevices.shared.devices.first { $0.id == id }?.name })
    }

    /// A device opened an event stream (following `session`, if it named one).
    func attach(_ stream: HTTPServer.EventStream, following session: UUID?, caller: RemoteRoutes.Caller = .thisMac) {
        // Its first state, before it's following: what's pending goes to those
        // already following first, so they keep their place (not to it).
        let first = session.flatMap { id in sources[id].map { state(id, $0) } }
        let sub = Subscriber(stream: stream, session: session, device: caller.deviceID)
        let key = ObjectIdentifier(sub)
        subscribers[key] = sub
        let previous = stream.onClose
        stream.onClose = { [weak self] in
            previous?()
            self?.subscribers[key] = nil
            Log.info(.app, "remote: \(stream.peer) stopped following\(session.map { " \($0)" } ?? " the list")")
        }
        Log.info(.app, "remote: \(stream.peer) following\(session.map { " \($0)" } ?? " the list")")
        stream.send("hello", hello(for: caller))
        guard let session else { return }
        if let first {
            stream.send("state", first)
        } else {
            stream.send("gone", ["session": session])
        }
    }

    /// Unpair a device: its token stops working and its open streams close.
    func revoke(_ device: UUID) {
        RemoteDevices.shared.revoke(device)
        for sub in subscribers.values where sub.device == device { sub.stream.close() }
    }

    /// Open pairing (the server comes up for it while it's open): the offer
    /// a device answers.
    @discardableResult
    func startPairing() -> RemotePairing.Offer {
        let offer = RemotePairing.shared.start()
        refresh()
        // Once it runs out, nothing needs the server for it.
        DispatchQueue.main.asyncAfter(deadline: .now() + RemotePairing.lifetime + 1) { [weak self] in self?.refresh() }
        return offer
    }

    func cancelPairing() {
        RemotePairing.shared.cancel()
        refresh()
    }

    // MARK: Commands

    enum CommandError: Error {
        /// No such session (or Remote Control is off for it).
        case notFound
        /// The chat is closed.
        case closed
        /// What was answered isn't being asked any more.
        case stale
        case invalid(String)
    }

    private func chat(_ id: UUID) throws(CommandError) -> ChatSession {
        guard let chat = sources[id]?.chat else { throw .notFound }
        return chat
    }

    func chatToDrive(_ id: UUID) throws(CommandError) -> ChatSession { try chat(id) }

    func send(_ id: UUID, text: String, images: [ChatAttachment]) throws(CommandError) {
        try Self.send(chat(id), text: text, images: images)
    }

    static func send(_ chat: ChatSession, text: String, images: [ChatAttachment]) throws(CommandError) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !images.isEmpty else {
            throw .invalid("Nothing to send")
        }
        guard chat.submit(text: text, attachments: images) else { throw .closed }
    }

    func cancel(_ id: UUID) throws(CommandError) {
        try chat(id).cancel()
    }

    func answerPermission(_ id: UUID, permission: String, option: String?) throws(CommandError) {
        try Self.answerPermission(chat(id), permission: permission, option: option)
    }

    static func answerPermission(_ chat: ChatSession, permission: String, option: String?) throws(CommandError) {
        guard let p = chat.permission, p.id.compactString == permission else { throw .stale }
        if let option, !p.options.contains(where: { $0.id == option }) { throw .invalid("No such option") }
        chat.answerPermission(p, optionID: option)
    }

    func answerQuestion(_ id: UUID, question: String, answer: AgentQuestion.Answer) throws(CommandError) {
        try Self.answerQuestion(chat(id), question: question, answer: answer)
    }

    static func answerQuestion(_ chat: ChatSession, question: String, answer: AgentQuestion.Answer) throws(CommandError) {
        guard let q = chat.question, q.id == question else { throw .stale }
        chat.answerQuestion(q, answer)
    }

    func setMode(_ id: UUID, mode: String) throws(CommandError) {
        try Self.setMode(chat(id), mode: mode)
    }

    static func setMode(_ chat: ChatSession, mode: String) throws(CommandError) {
        guard chat.modes.contains(where: { $0.id == mode }) else { throw .invalid("No such mode") }
        chat.setMode(mode)
    }

    func image(_ id: UUID, item: String, index: Int) -> Data? {
        sources[id].flatMap { RemoteWire.image(in: $0.chat.items, item: item, index: index) }
    }

    // MARK: Check reports

    /// What a device's /check page found.
    struct CheckReport: Codable, Sendable {
        struct Result: Codable, Sendable { let name: String; let ok: Bool; let detail: String? }
        let device: String
        let userAgent: String
        let results: [Result]
        var peer: String?
        var at: Date?
        var passed: Bool { results.allSatisfy(\.ok) }
    }

    /// The latest report from each device (by browser), newest last.
    private(set) var checkReports: [CheckReport] = []

    func record(_ report: CheckReport, from peer: String) {
        var report = report
        report.peer = peer
        report.at = .now
        checkReports.removeAll { $0.userAgent == report.userAgent }
        checkReports.append(report)
        let failed = report.results.filter { !$0.ok }
        Log.info(.app, "remote: check from \(report.device) (\(peer)): "
                 + (failed.isEmpty ? "all \(report.results.count) passed"
                                   : "\(failed.count) of \(report.results.count) failed — "
                                     + failed.map(\.name).joined(separator: "; ")))
    }

    // MARK: Server

    private func setServing(_ wanted: Bool) {
        if wanted {
            stopping?.cancel()
            stopping = nil
            guard server == nil, !serverStarting else { return }
            serverStarting = true
            Task { await startServer() }
        } else if server != nil, stopping == nil {
            // A moment's grace: devices hear why their session went, and a
            // switch turned straight back on keeps the same server.
            let stop = DispatchWorkItem { [weak self] in self?.stopServer() }
            stopping = stop
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: stop)
        }
    }
    private var stopping: DispatchWorkItem?

    private func stopServer() {
        stopping = nil
        guard let server else { return }
        server.stop()
        self.server = nil
        routes = nil
        subscribers = [:]
        port = nil
        Log.info(.app, "remote: stopped serving")
        onServing?(nil)
    }

    /// Let paired devices on the home network in (or keep it to this Mac):
    /// a running server starts again listening the new way.
    func setHomeNetwork(_ on: Bool) {
        guard on != homeNetwork else { return }
        homeNetwork = on
        UserDefaults.standard.set(on, forKey: "remoteHomeNetwork")
        Log.info(.app, "remote: home network \(on ? "on" : "off")")
        guard server != nil else { return }
        stopServer()
        setServing(servingWanted)
    }

    /// Answer on the tailnet too (or stop): a running server starts again
    /// listening the new way.
    func setTailscale(_ on: Bool) {
        guard on != tailscaleOn else { return }
        tailscaleOn = on
        UserDefaults.standard.set(on, forKey: "remoteTailscale")
        Log.info(.app, "remote: Tailscale \(on ? "on" : "off")")
        refreshTailscale()
        guard server != nil else { return }
        stopServer()
        setServing(servingWanted)
    }

    /// Read Tailscale's state again (and again every half minute while it's on:
    /// it connects and disconnects on its own).
    func refreshTailscale() {
        tailscaleTimer?.invalidate()
        tailscaleTimer = nil
        Task {
            let status = await Tailscale.status()
            guard status != tailscale else { return }
            tailscale = status
            routes?.tailnetNames = tailnetNames
            Log.info(.app, "remote: Tailscale " + (status.map { $0.running ? "connected as \($0.dnsName ?? "?")" : "not connected" }
                                                    ?? "not installed"))
        }
        guard tailscaleOn else { return }
        tailscaleTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshTailscaleQuietly() }
        }
    }

    private func refreshTailscaleQuietly() {
        Task {
            let status = await Tailscale.status()
            guard status != tailscale else { return }
            tailscale = status
            routes?.tailnetNames = tailnetNames
        }
    }

    /// Listen beyond this Mac (the home network, or the tailnet).
    private var listensBeyondLoopback: Bool { homeNetwork || tailscaleOn }

    /// Where devices can open the server now (nil: not serving).
    var addresses: [RemoteAddresses.Address] {
        guard let port else { return [] }
        return RemoteAddresses.current(port: port, homeNetwork: homeNetwork,
                                       tailnet: tailscale?.dnsName.flatMap { tailscaleOn && tailscale?.running == true ? [$0] : nil } ?? [])
    }

    private func startServer() async {
        defer { serverStarting = false }
        // (`integer(forKey:)` also reads a `-SandshellRemotePort 47830` argument, which is text.)
        let defaults = UserDefaults.standard
        let first = defaults.object(forKey: "SandshellRemotePort") == nil ? Self.defaultPort
            : UInt16(clamping: defaults.integer(forKey: "SandshellRemotePort"))
        // Another Sandshell may hold the usual port: take the next one.
        let candidates: [UInt16] = first == 0 ? [0] : (0..<10).map { first &+ $0 } + [0]
        let routes = RemoteRoutes(hub: self)
        let lan = homeNetwork, wide = listensBeyondLoopback
        routes.homeNetwork = lan
        routes.tailnetNames = tailnetNames
        if tailscaleOn, tailscale == nil { refreshTailscale() }
        for candidate in candidates {
            let server = HTTPServer(loopbackOnly: !wide, bonjourName: lan ? Self.hostName : nil) { routes.handle($0) }
            do {
                let port = try await server.start(port: candidate)
                self.server = server
                self.routes = routes
                self.port = port
                routes.port = port
                Log.info(.app, "remote: serving on " + addresses.map(\.url.absoluteString).joined(separator: ", "))
                onServing?(port)
                // Nothing to serve any more (turned off while it started), or
                // the home network was switched meanwhile.
                if !servingWanted || lan != homeNetwork || wide != listensBeyondLoopback {
                    stopServer()
                    setServing(servingWanted)
                }
                return
            } catch {
                server.stop()
                Log.info(.app, "remote: port \(candidate) unavailable (\(error.localizedDescription))")
            }
        }
        Log.error(.app, "remote: couldn't start the server")
    }

    /// The address to open on this Mac, while serving.
    var localURL: URL? { port.map { URL(string: "http://127.0.0.1:\($0)/")! } }

    /// A session's own address on this Mac, while serving.
    func localURL(for session: UUID) -> URL? {
        localURL?.appending(path: "s/\(session.uuidString)")
    }

    // MARK: The check session (DEBUG)

    #if DEBUG
    /// Start or stop the check session: a chat with the fake ACP agent (no
    /// sandbox, no tokens) that a device's /check page drives.
    func setCheckSession(_ on: Bool) {
        if on, checkChat == nil {
            guard let script = Self.fakeAgentScript else {
                Log.error(.app, "remote: the fake agent script isn't in the app bundle")
                return
            }
            let dir = FileManager.default.temporaryDirectory.appending(path: "sandshell-remote-check")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let chat = ChatSession(title: "Fake agent", agent: .claude, containerName: "remote-check",
                                   workdir: dir.path, home: dir.path, sessionID: checkID)
            chat.launchOverride = ("/usr/bin/python3", ["-I", script.path])
            checkChat = chat
            chat.start()
        } else if !on, let chat = checkChat {
            chat.close()
            checkChat = nil
        }
        refresh()
    }

    var checkSessionID: UUID { checkID }

    /// `remote/fake-acp-agent.py` in the app bundle.
    static var fakeAgentScript: URL? {
        Bundle.main.resourceURL.map { $0.appending(path: "remote/fake-acp-agent.py") }
            .flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
    }
    #endif
}
