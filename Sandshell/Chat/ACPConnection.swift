import Foundation

/// One JSON-RPC 2.0 connection to an ACP (Agent Client Protocol) agent over the
/// stdio of a child process — here `sbx exec -i … claude-agent-acp` running in
/// the session's sandbox.
///
/// Lines are read with blocking `read(2)` on a dedicated thread (FileHandle's
/// readability batching stalls under load — see Agate's ProcessRunner) and
/// delivered in order through `incoming`. Responses resolve the matching
/// `request` continuation directly on the reader thread.
final class ACPConnection: @unchecked Sendable {
    enum Incoming: Sendable {
        /// Agent → client notification (e.g. `session/update`).
        case notification(method: String, params: JSONValue)
        /// Agent → client request that needs `respond` (e.g. `session/request_permission`).
        case request(id: JSONValue, method: String, params: JSONValue)
        /// A stderr line from the adapter (diagnostics only).
        case stderr(String)
        /// The process exited.
        case closed(status: Int32)
    }

    struct RPCError: LocalizedError, Sendable {
        let code: Int
        let message: String
        var errorDescription: String? { message }
    }

    let incoming: AsyncStream<Incoming>
    private let yield: AsyncStream<Incoming>.Continuation

    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()

    private let lock = NSLock()
    private var nextID = 0
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private var isClosed = false
    /// The process has exited (its pipes may still be held open by another).
    private var hasExited = false
    /// Writes to the agent's stdin, in order, off the caller's thread: a
    /// prompt with pasted images is megabytes, and a blocking write on the
    /// main thread, under `lock`, beachballed the app while sbx exec relayed it
    /// (for good if it stalled), and kept the reader from resolving anything.
    private let writer = DispatchQueue(label: "ACPConnection.stdin")
    /// stdin closed (only touched on `writer`).
    nonisolated(unsafe) private var stdinClosed = false

    init(executable: String, arguments: [String]) {
        (incoming, yield) = AsyncStream.makeStream(of: Incoming.self)
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
    }

    func start() throws {
        // A write after the agent exited (an Allow click as it dies) must fail,
        // not SIGPIPE the app.
        _ = fcntl(stdinPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        process.terminationHandler = { [weak self] _ in
            guard let self else { return }
            self.lock.lock(); self.hasExited = true; self.lock.unlock()
        }
        try process.run()
        let out = stdoutPipe.fileHandleForReading.fileDescriptor
        let err = stderrPipe.fileHandleForReading.fileDescriptor
        // Close only after stdout is drained, so no trailing message is lost.
        // The readers keep the connection (and so its pipes and fds) alive
        // until they're done; close reports only after stderr is drained too,
        // so its last line (often the reason it exited) isn't lost.
        // A reader stops at EOF, or once the process has exited and its pipe
        // has nothing more: a process it started (sbx's daemon, started by
        // this `sbx exec`) can hold the pipe open for good, and waiting for
        // EOF left the chat never hearing its agent had gone.
        let stderrDone = DispatchSemaphore(value: 0)
        let exited: @Sendable () -> Bool = { [weak self] in
            guard let self else { return true }
            self.lock.lock(); defer { self.lock.unlock() }
            return self.hasExited
        }
        Thread.detachNewThread {
            Self.readLines(fd: out, until: exited) { self.handleLine($0) }
            self.process.waitUntilExit()
            _ = stderrDone.wait(timeout: .now() + 2)
            self.didClose(status: self.process.terminationStatus)
        }
        Thread.detachNewThread {
            Self.readLines(fd: err, until: exited) { line in
                self.yield.yield(.stderr(String(decoding: line, as: UTF8.self)))
            }
            stderrDone.signal()
        }
    }

    /// Send a request and await its `result` (throws on a JSON-RPC `error`).
    func request(_ method: String, _ params: JSONValue) async throws -> JSONValue {
        try await withCheckedThrowingContinuation { cont in
            lock.lock()
            if isClosed {
                lock.unlock()
                cont.resume(throwing: RPCError(code: -1, message: "The agent process has exited."))
                return
            }
            nextID += 1
            let id = nextID
            pending[id] = cont
            lock.unlock()
            write(["jsonrpc": "2.0", "id": .number(Double(id)), "method": .string(method), "params": params])
        }
    }

    func notify(_ method: String, _ params: JSONValue) {
        write(["jsonrpc": "2.0", "method": .string(method), "params": params])
    }

    func respond(id: JSONValue, result: JSONValue) {
        write(["jsonrpc": "2.0", "id": id, "result": result])
    }

    func respondError(id: JSONValue, code: Int, message: String) {
        write(["jsonrpc": "2.0", "id": id, "error": ["code": .number(Double(code)), "message": .string(message)]])
    }

    /// The agent process is up and its pipes open.
    var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return !isClosed && process.isRunning
    }

    func terminate() {
        // Closed after what's queued is written (and never under a write):
        // ending the process unblocks one stuck on a full pipe.
        writer.async { [self] in
            stdinClosed = true
            try? stdinPipe.fileHandleForWriting.close()
        }
        if process.isRunning { process.terminate() }
    }

    // MARK: - Private

    private func write(_ message: JSONValue) {
        guard var data = try? JSONEncoder().encode(message) else { return }
        data.append(0x0A)
        lock.lock()
        let closed = isClosed
        lock.unlock()
        guard !closed else { return }
        let line = data
        writer.async { [self] in
            guard !stdinClosed else { return }
            try? stdinPipe.fileHandleForWriting.write(contentsOf: line)
        }
    }

    private func handleLine(_ line: Data) {
        guard let msg = try? JSONDecoder().decode(JSONValue.self, from: line) else {
            yield.yield(.stderr("non-JSON stdout: " + String(decoding: line, as: UTF8.self)))
            return
        }
        if let method = msg["method"]?.string {
            if let id = msg["id"] {
                yield.yield(.request(id: id, method: method, params: msg["params"] ?? .null))
            } else {
                yield.yield(.notification(method: method, params: msg["params"] ?? .null))
            }
            return
        }
        guard let id = msg["id"]?.int else { return }
        lock.lock()
        let cont = pending.removeValue(forKey: id)
        lock.unlock()
        if let error = msg["error"] {
            cont?.resume(throwing: RPCError(code: error["code"]?.int ?? 0,
                                            message: error["message"]?.string ?? "Unknown error"))
        } else {
            cont?.resume(returning: msg["result"] ?? .null)
        }
    }

    private func didClose(status: Int32) {
        lock.lock()
        isClosed = true
        let waiting = pending.values
        pending.removeAll()
        lock.unlock()
        for cont in waiting { cont.resume(throwing: RPCError(code: -1, message: "The agent process exited (\(status)).")) }
        yield.yield(.closed(status: status))
        yield.finish()
    }

    /// Newline-delimited reader; returns at EOF, or when `done()` and nothing
    /// arrived for a moment (it's asked twice a second while the pipe's quiet).
    static func readLines(fd: Int32, until done: () -> Bool = { false }, _ onLine: (Data) -> Void) {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            var ready = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let polled = poll(&ready, 1, 500)
            if polled < 0, errno == EINTR { continue }
            if polled == 0 {
                if done() { break }
                continue
            }
            let n = read(fd, &chunk, chunk.count)
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { break }
            buffer.append(contentsOf: chunk[0..<n])
            // Only what just arrived can hold a newline not seen yet (a line of
            // megabytes — an image, a big file — was rescanned from its start on
            // every read), and what's left is moved down once, not per line.
            var start = buffer.startIndex
            var from = buffer.endIndex - n
            while let nl = buffer[from...].firstIndex(of: 0x0A) {
                let line = buffer[start..<nl]
                if !line.isEmpty { onLine(Data(line)) }
                start = nl + 1
                from = start
            }
            if start > buffer.startIndex { buffer = buffer.subdata(in: start..<buffer.endIndex) }
        }
        if !buffer.isEmpty { onLine(buffer) }
    }
}
