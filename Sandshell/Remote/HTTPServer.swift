import Foundation
import Network

/// A small HTTP/1.1 server on Network.framework for Remote Control: requests
/// in, one response out (then the connection closes), or a Server-Sent Events
/// stream that stays open. Everything runs on the main queue — a handful of
/// devices, and every handler talks to main-actor chat state anyway.
@MainActor
final class HTTPServer {
    struct Request: Sendable {
        let method: String
        /// The path without its query, percent-decoded.
        let path: String
        let query: [String: String]
        /// Header names lowercased.
        let headers: [String: String]
        let body: Data
        /// The peer's address ("127.0.0.1", "fe80::1%en0").
        let peer: String

        /// The path's segments: "/api/sessions/x" → ["api", "sessions", "x"].
        var segments: [String] { path.split(separator: "/").map(String.init) }
    }

    struct Response {
        var status: Int
        var headers: [String: String] = [:]
        var body = Data()

        static func json(_ value: some Encodable, status: Int = 200) -> Response {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let body = (try? encoder.encode(value)) ?? Data("null".utf8)
            return Response(status: status, headers: ["Content-Type": "application/json; charset=utf-8"], body: body)
        }

        static func text(_ text: String, status: Int) -> Response {
            Response(status: status, headers: ["Content-Type": "text/plain; charset=utf-8"], body: Data(text.utf8))
        }

        static func error(_ status: Int, _ message: String) -> Response {
            .json(["error": message], status: status)
        }
    }

    enum Reply {
        case response(Response)
        /// Open an event stream; the closure gets it once its headers are out.
        case events((EventStream) -> Void)
    }

    /// One open `text/event-stream` response.
    @MainActor
    final class EventStream {
        private let connection: NWConnection
        private(set) var isOpen = true
        /// The device went away (or the stream was closed here).
        var onClose: (() -> Void)?
        let peer: String

        fileprivate init(connection: NWConnection, peer: String) {
            self.connection = connection
            self.peer = peer
        }

        /// Send one event: `event: <name>` and its JSON as `data:`.
        func send(_ event: String, _ value: some Encodable) {
            guard isOpen, let json = try? JSONEncoder().encode(value) else { return }
            var chunk = Data("event: \(event)\ndata: ".utf8)
            chunk.append(json)
            chunk.append(Data("\n\n".utf8))
            write(chunk)
        }

        /// A comment line: keeps proxies (and iOS) from timing the stream out.
        func ping() { write(Data(": ping\n\n".utf8)) }

        func close() {
            guard isOpen else { return }
            isOpen = false
            connection.cancel()
            onClose?()
            onClose = nil
        }

        private func write(_ data: Data) {
            guard isOpen else { return }
            connection.send(content: data, completion: .contentProcessed { [weak self] error in
                guard error != nil else { return }
                MainActor.assumeIsolated { self?.close() }
            })
        }

        /// Watch for the device hanging up (an event stream sends nothing back).
        fileprivate func watch() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] _, _, isComplete, error in
                MainActor.assumeIsolated {
                    guard let self, self.isOpen else { return }
                    if isComplete || error != nil { self.close() } else { self.watch() }
                }
            }
        }
    }

    private nonisolated static let maxHeader = 64 * 1024
    private nonisolated static let maxBody = 40 * 1024 * 1024

    private var listener: NWListener?
    private var streams: [ObjectIdentifier: EventStream] = [:]
    private var pingTimer: Timer?
    private let handler: (Request) -> Reply
    /// Accept connections only from this Mac.
    let loopbackOnly: Bool
    /// The port it listens on, once it's up.
    private(set) var port: UInt16?

    init(loopbackOnly: Bool, handler: @escaping (Request) -> Reply) {
        self.loopbackOnly = loopbackOnly
        self.handler = handler
    }

    /// Listen on `port` (0: any free one); returns the port once it's ready.
    func start(port: UInt16) async throws -> UInt16 {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        if loopbackOnly { params.requiredInterfaceType = .loopback }
        let listener = try NWListener(using: params, on: port == 0 ? .any : NWEndpoint.Port(rawValue: port) ?? .any)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated { self?.accept(connection) }
        }
        let ready: UInt16 = try await withCheckedThrowingContinuation { cont in
            // Only touched on the main queue (the listener's).
            nonisolated(unsafe) var resumed = false
            listener.stateUpdateHandler = { state in
                MainActor.assumeIsolated {
                    guard !resumed else { return }
                    switch state {
                    case .ready:
                        resumed = true
                        cont.resume(returning: listener.port?.rawValue ?? port)
                    case .failed(let error):
                        resumed = true
                        cont.resume(throwing: error)
                    case .cancelled:
                        resumed = true
                        cont.resume(throwing: CancellationError())
                    default: break
                    }
                }
            }
            listener.start(queue: .main)
        }
        self.port = ready
        pingTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.streams.values.forEach { $0.ping() } }
        }
        return ready
    }

    func stop() {
        pingTimer?.invalidate()
        pingTimer = nil
        listener?.cancel()
        listener = nil
        port = nil
        for stream in streams.values { stream.close() }
        streams = [:]
    }

    // MARK: Connections

    private func accept(_ connection: NWConnection) {
        let peer = Self.address(of: connection.endpoint)
        if loopbackOnly, !Self.isLoopback(connection.endpoint) {
            Log.info(.app, "remote: refused a connection from \(peer) (this Mac only)")
            connection.cancel()
            return
        }
        connection.start(queue: .main)
        receive(connection, peer: peer, buffer: Data())
    }

    private func receive(_ connection: NWConnection, peer: String, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            MainActor.assumeIsolated {
                guard let self else { return connection.cancel() }
                var buffer = buffer
                if let data { buffer.append(data) }
                switch Self.parse(buffer, peer: peer) {
                case .incomplete where isComplete || error != nil:
                    connection.cancel()
                case .incomplete:
                    self.receive(connection, peer: peer, buffer: buffer)
                case .invalid(let status):
                    self.respond(connection, .error(status, "Bad request"))
                case .request(let request):
                    self.handle(request, on: connection)
                }
            }
        }
    }

    private func handle(_ request: Request, on connection: NWConnection) {
        switch handler(request) {
        case .response(let response):
            respond(connection, response)
        case .events(let attach):
            let head = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache, no-store\r\n"
                + "Connection: keep-alive\r\nX-Accel-Buffering: no\r\n\r\n: open\n\n"
            connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in })
            let stream = EventStream(connection: connection, peer: request.peer)
            let key = ObjectIdentifier(stream)
            streams[key] = stream
            stream.onClose = { [weak self] in self?.streams[key] = nil }
            stream.watch()
            attach(stream)
        }
    }

    private func respond(_ connection: NWConnection, _ response: Response) {
        var head = "HTTP/1.1 \(response.status) \(Self.reason(response.status))\r\n"
        var headers = response.headers
        headers["Content-Length"] = String(response.body.count)
        headers["Connection"] = "close"
        headers["Cache-Control"] = headers["Cache-Control"] ?? "no-store"
        headers["X-Content-Type-Options"] = "nosniff"
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) { head += "\(name): \(value)\r\n" }
        head += "\r\n"
        var data = Data(head.utf8)
        data.append(response.body)
        connection.send(content: data, completion: .contentProcessed { _ in connection.cancel() })
    }

    // MARK: Parsing

    enum Parsed {
        case incomplete
        case invalid(Int)
        case request(Request)
    }

    /// A whole request from what's arrived so far, if it's all there.
    nonisolated static func parse(_ buffer: Data, peer: String) -> Parsed {
        let separator = Data("\r\n\r\n".utf8)
        guard let end = buffer.firstRange(of: separator) else {
            return buffer.count > maxHeader ? .invalid(431) : .incomplete
        }
        let head = String(decoding: buffer[buffer.startIndex..<end.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true)
        guard requestLine.count >= 2 else { return .invalid(400) }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] =
                line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? -1
        guard length >= 0 else { return .invalid(400) }
        guard length <= maxBody else { return .invalid(413) }
        let bodyStart = end.upperBound
        guard buffer.count - (bodyStart - buffer.startIndex) >= length else { return .incomplete }
        let body = buffer[bodyStart..<(bodyStart + length)]
        let target = String(requestLine[1])
        let components = URLComponents(string: target)
        var query: [String: String] = [:]
        for item in components?.queryItems ?? [] { query[item.name] = item.value ?? "" }
        let path = components?.percentEncodedPath.removingPercentEncoding ?? target
        return .request(Request(method: String(requestLine[0]).uppercased(), path: path, query: query,
                                headers: headers, body: Data(body), peer: peer))
    }

    nonisolated static func isLoopback(_ endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let address): return address.isLoopback
        case .ipv6(let address): return address.isLoopback || address == .loopback
        case .name(let name, _): return name == "localhost"
        @unknown default: return false
        }
    }

    nonisolated static func address(of endpoint: NWEndpoint) -> String {
        guard case .hostPort(let host, _) = endpoint else { return "\(endpoint)" }
        return "\(host)"
    }

    nonisolated static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 204: "No Content"
        case 400: "Bad Request"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 409: "Conflict"
        case 413: "Payload Too Large"
        case 415: "Unsupported Media Type"
        case 431: "Request Header Fields Too Large"
        default: status < 400 ? "OK" : "Error"
        }
    }
}
