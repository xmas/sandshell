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
