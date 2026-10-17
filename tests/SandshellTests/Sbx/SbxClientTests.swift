import Foundation
import Testing
@testable import Sandshell

// Tests for the parts of `SbxClient` (Sbx/SbxClient.swift) that run without
// `sbx`: reading a command's output pipes, and whether a sandbox can be rebuilt.

// MARK: - Output pipes

/// `DataBox.drain` is what `run` reads a command's stdout and stderr with,
/// from the readability handler and once more after the command exits.
struct SbxClientPipeDrainTests {
    @Test("Reads what the pipe holds without waiting for the writer to close it", .timeLimit(.minutes(1)))
    func readsBufferedBytesWhileTheWriterIsOpen() throws {
        let pipe = Pipe()
        let box = SbxClient.DataBox()
        try pipe.fileHandleForWriting.write(contentsOf: Data(#"[{"name":"ws-claude"}]"#.utf8))

        let open = box.drain(pipe.fileHandleForReading)

        #expect(open, "A daemon holding the write end open mustn't read as end of file")
        #expect(box.data == Data(#"[{"name":"ws-claude"}]"#.utf8), "The last chunk isn't dropped at exit")
    }

    @Test("Reports end of file once the writer has closed and the pipe is empty", .timeLimit(.minutes(1)))
    func reportsEndOfFile() throws {
        let pipe = Pipe()
        let box = SbxClient.DataBox()
        try pipe.fileHandleForWriting.write(contentsOf: Data("done\n".utf8))
        try pipe.fileHandleForWriting.close()

        #expect(box.drain(pipe.fileHandleForReading) == false)
        #expect(box.data == Data("done\n".utf8), "Bytes written before the close are still read")
        #expect(box.drain(pipe.fileHandleForReading) == false, "Draining again at end of file adds nothing")
        #expect(box.data == Data("done\n".utf8))
    }

    @Test("Successive drains append in order", .timeLimit(.minutes(1)))
    func drainsAccumulate() throws {
        let pipe = Pipe()
        let box = SbxClient.DataBox()

        #expect(box.drain(pipe.fileHandleForReading), "An empty pipe whose writer is open has nothing yet")
        try pipe.fileHandleForWriting.write(contentsOf: Data("first ".utf8))
        box.drain(pipe.fileHandleForReading)
        try pipe.fileHandleForWriting.write(contentsOf: Data("second".utf8))
        box.drain(pipe.fileHandleForReading)

        #expect(String(data: box.data, encoding: .utf8) == "first second")
    }
}

// MARK: - Lifecycle socket

/// An HTTP server on a unix socket in the temporary directory that answers
/// one request with `body`, standing in for sbx's lifecycle socket.
fileprivate final class OneShotSocketServer: Sendable {
    let path: String
    private let listener: Int32

    init(body: String) throws {
        path = FileManager.default.temporaryDirectory
            .appending(path: "sbx-\(UUID().uuidString.prefix(8)).sock").path(percentEncoded: false)
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        try #require(listener >= 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        try #require(pathBytes.count < MemoryLayout.size(ofValue: address.sun_path), "Socket path too long: \(path)")
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: pathBytes) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        try #require(bound == 0 && listen(listener, 1) == 0)

        let response = Array(("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n"
            + "Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n" + body).utf8)
        Thread.detachNewThread { [listener] in
            var ready = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            guard poll(&ready, 1, 30_000) == 1 else { return }
            let client = accept(listener, nil, nil)
            guard client >= 0 else { return }
            defer { close(client) }
            var request = [UInt8](repeating: 0, count: 4096)
            _ = read(client, &request, request.count)   // curl's GET fits in one read
            var sent = 0
            while sent < response.count {
                let n = response[sent...].withUnsafeBytes { write(client, $0.baseAddress, $0.count) }
                guard n > 0 else { return }
                sent += n
            }
        }
    }

    deinit {
        close(listener)
        unlink(path)
    }
}

/// `inspectExecLifecycle` / `activeExecIDs` read sbx's lifecycle socket with
/// `curl`, awaiting it rather than blocking the actor.
struct SbxClientLifecycleSocketTests {
    @Test("An exec's state is read from the socket", .timeLimit(.minutes(1)))
    func execStateIsRead() async throws {
        let server = try OneShotSocketServer(body: #"{"ID":"e1","Running":true,"Pid":42,"ExitCode":0}"#)

        let state = try #require(await SbxClient().inspectExecLifecycle(id: "e1", socketPath: server.path))

        #expect(state.id == "e1")
        #expect(state.running)
        #expect(state.pid == 42)
    }

    @Test("A response bigger than a pipe's buffer is read whole", .timeLimit(.minutes(1)))
    func largeResponseIsReadWhole() async throws {
        let padding = String(repeating: "x", count: 256 * 1024)
        let server = try OneShotSocketServer(body: #"{"ExecIDs":["e1","e2"],"Padding":"\#(padding)"}"#)

        let ids = await SbxClient().activeExecIDs(containerName: "ws-claude", socketPath: server.path)

        #expect(ids == ["e1", "e2"])
    }

    @Test("No socket, no answer", .tags(.edgeCase))
    func missingSocketIsNil() async {
        let path = FileManager.default.temporaryDirectory.appending(path: "sbx-missing-\(UUID().uuidString).sock")
        #expect(await SbxClient().inspectExecLifecycle(id: "e1", socketPath: path.path(percentEncoded: false)) == nil)
    }
}

// MARK: - Rebuilding

struct SbxClientRecreateTests {
    @Test("A builtin agent's sandbox can always be recreated", arguments: AgentKind.builtins)
    func builtinsCanBeRecreated(agent: AgentKind) {
        #expect(SbxClient.cannotRecreate(agent, sandbox: "ws-\(agent.rawValue)") == nil)
    }

    @Test("A custom agent whose kit isn't registered can't be recreated, so its sandbox is kept")
    func unregisteredCustomAgentCannotBeRecreated() throws {
        let agent = AgentKind(rawValue: "sandshell-test-\(UUID().uuidString.lowercased())")

        let error = try #require(SbxClient.cannotRecreate(agent, sandbox: "ws-custom"))

        let message = try #require(error.errorDescription)
        #expect(message.contains("“ws-custom”"))
        #expect(message.contains("“\(agent.rawValue)”"))
        #expect(message.contains("Settings ▸ Agents"), "Says where to register the kit")
    }
}
