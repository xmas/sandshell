import Foundation

/// Remote Control's HTTP API and the web client's files:
///
///     GET  /                              the web client (remote/web)
///     GET  /api/info                      this Mac, and the sessions it shares
///     GET  /api/events[?session=<id>]     event stream: hello, sessions, state, patch, gone
///     GET  /api/sessions/<id>/images/<item>/<n>
///     POST /api/sessions/<id>/send        {text, images: [{name, mimeType, data(base64)}]}
///     POST /api/sessions/<id>/cancel
///     POST /api/sessions/<id>/permission  {permission, option (null: cancel)}
///     POST /api/sessions/<id>/question    {question, action: accept|decline|cancel, content}
///     POST /api/sessions/<id>/mode        {mode}
///     POST /api/check                     a device's /check results; GET /api/checks lists them
///
/// Requests must name this server in `Host` (a DNS-rebinding page can't), and
/// POSTs must carry `X-Sandshell: 1` (another site's page can't send that
/// without a CORS preflight, which is never allowed).
@MainActor
final class RemoteRoutes {
    private unowned let hub: RemoteHub
    /// The port the server took (for the Host check).
    var port: UInt16 = RemoteHub.defaultPort

    init(hub: RemoteHub) { self.hub = hub }

    func handle(_ request: HTTPServer.Request) -> HTTPServer.Reply {
        guard hostAllowed(request.headers["host"]) else {
            Log.info(.app, "remote: refused \(request.method) \(request.path) for Host \(request.headers["host"] ?? "-")")
            return .response(.error(403, "Unknown host"))
        }
        let parts = request.segments
        guard parts.first == "api" else { return .response(file(request)) }
        switch (request.method, Array(parts.dropFirst())) {
        case ("GET", ["info"]):
            return .response(.json(RemoteHub.Hello(host: RemoteHub.hostName, sessions: hub.summaries)))
        case ("GET", ["events"]):
            let session = request.query["session"].flatMap(UUID.init(uuidString:))
            return .events { [hub] stream in hub.attach(stream, following: session) }
        case ("GET", let p) where p.count == 5 && p[0] == "sessions" && p[2] == "images":
            guard let id = UUID(uuidString: p[1]), let index = Int(p[4]),
                  let data = hub.image(id, item: p[3], index: index) else { return .response(.error(404, "No such image")) }
            return .response(HTTPServer.Response(status: 200, headers: ["Content-Type": Self.imageType(data),
                                                                         "Cache-Control": "private, max-age=86400"],
                                                 body: data))
        case ("GET", ["checks"]):
            return .response(.json(hub.checkReports))
        case ("POST", ["check"]):
            guard request.headers["x-sandshell"] == "1" else { return .response(.error(403, "Missing X-Sandshell header")) }
            guard let report = try? JSONDecoder().decode(RemoteHub.CheckReport.self, from: request.body) else {
                return .response(.error(400, "Expected {device, userAgent, results}"))
            }
            hub.record(report, from: request.peer)
            return .response(.json(["ok": true]))
        case ("POST", let p) where p.count == 3 && p[0] == "sessions":
            guard request.headers["x-sandshell"] == "1" else { return .response(.error(403, "Missing X-Sandshell header")) }
            guard let id = UUID(uuidString: p[1]) else { return .response(.error(404, "No such session")) }
            return .response(command(p[2], session: id, body: request.body))
        case (_, let p) where !p.isEmpty:
            return .response(.error(request.method == "GET" ? 404 : 405, "No such endpoint"))
        default:
            return .response(.error(404, "No such endpoint"))
        }
    }

    // MARK: Commands

    private struct SendBody: Decodable {
        struct Image: Decodable { let name: String?; let mimeType: String; let data: String }
        let text: String?
        let images: [Image]?
    }
    private struct PermissionBody: Decodable { let permission: String; let option: String? }
    private struct QuestionBody: Decodable { let question: String; let action: String; let content: [String: JSONValue]? }
    private struct ModeBody: Decodable { let mode: String }

    private func command(_ name: String, session id: UUID, body: Data) -> HTTPServer.Response {
        func decode<T: Decodable>(_ type: T.Type) -> T? { try? JSONDecoder().decode(type, from: body) }
        do throws(RemoteHub.CommandError) {
            switch name {
            case "send":
                guard let b = decode(SendBody.self) else { return .error(400, "Expected {text, images}") }
                var images: [ChatAttachment] = []
                for (i, image) in (b.images ?? []).enumerated() {
                    guard image.mimeType.hasPrefix("image/"), let data = Data(base64Encoded: image.data) else {
                        return .error(415, "Only images can be attached")
                    }
                    images.append(ChatAttachment(kind: .image(data: data, mimeType: image.mimeType,
                                                              name: image.name ?? "Image \(i + 1)")))
                }
                try hub.send(id, text: b.text ?? "", images: images)
            case "cancel":
                try hub.cancel(id)
            case "permission":
                guard let b = decode(PermissionBody.self) else { return .error(400, "Expected {permission, option}") }
                try hub.answerPermission(id, permission: b.permission, option: b.option)
            case "question":
                guard let b = decode(QuestionBody.self), let answer = RemoteWire.answer(b.action, content: b.content) else {
                    return .error(400, "Expected {question, action, content}")
                }
                try hub.answerQuestion(id, question: b.question, answer: answer)
            case "mode":
                guard let b = decode(ModeBody.self) else { return .error(400, "Expected {mode}") }
                try hub.setMode(id, mode: b.mode)
            default:
                return .error(404, "No such command")
            }
        } catch {
            return switch error {
            case .notFound: .error(404, "No such session, or Remote Control is off for it")
            case .closed: .error(409, "The chat is closed")
            case .stale: .error(409, "That isn’t being asked any more")
            case .invalid(let why): .error(400, why)
            }
        }
        return .json(["ok": true])
    }

    // MARK: Files

    /// The web client's folder: the bundle's, or (DEBUG) `SandshellRemoteWebRoot`
    /// — the checkout's `remote/web`, to edit it without rebuilding.
    private var webRoot: URL? {
        #if DEBUG
        if let path = UserDefaults.standard.string(forKey: "SandshellRemoteWebRoot") {
            return URL(filePath: path, directoryHint: .isDirectory)
        }
        #endif
        return Bundle.main.resourceURL?.appending(path: "remote/web", directoryHint: .isDirectory)
    }

    private func file(_ request: HTTPServer.Request) -> HTTPServer.Response {
        guard request.method == "GET" || request.method == "HEAD" else { return .error(405, "Method not allowed") }
        guard let root = webRoot?.standardizedFileURL else { return .error(404, "No web client") }
        var path = request.path
        // The client routes /check and /s/<id> itself.
        if path == "/" || path == "/check" || path.hasPrefix("/s/") { path = "/index.html" }
        let url = root.appending(path: String(path.dropFirst())).standardizedFileURL
        guard url.path.hasPrefix(root.path + "/"), let data = try? Data(contentsOf: url) else {
            return .error(404, "Not found")
        }
        return HTTPServer.Response(status: 200, headers: ["Content-Type": Self.contentType(url.pathExtension),
                                                          "Cache-Control": "no-cache"],
                                   body: request.method == "HEAD" ? Data() : data)
    }

    private func hostAllowed(_ host: String?) -> Bool {
        guard let host else { return false }
        return ["127.0.0.1", "localhost", "[::1]"].contains { host == $0 || host == "\($0):\(port)" }
    }

    static func contentType(_ ext: String) -> String {
        switch ext.lowercased() {
        case "html": "text/html; charset=utf-8"
        case "js", "mjs": "text/javascript; charset=utf-8"
        case "css": "text/css; charset=utf-8"
        case "json", "webmanifest": "application/json"
        case "svg": "image/svg+xml"
        case "png": "image/png"
        case "ico": "image/x-icon"
        default: "application/octet-stream"
        }
    }

    /// An image's type from its first bytes.
    static func imageType(_ data: Data) -> String {
        let b = [UInt8](data.prefix(12))
        if b.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
        if b.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if b.starts(with: [0x47, 0x49, 0x46]) { return "image/gif" }
        if b.count >= 12, b[0...3] == [0x52, 0x49, 0x46, 0x46], b[8...11] == [0x57, 0x45, 0x42, 0x50] { return "image/webp" }
        return "application/octet-stream"
    }
}
