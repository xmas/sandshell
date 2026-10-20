import Foundation
import Testing
@testable import Sandshell

/// Items and statuses for the suites in this file.
fileprivate enum Wire {
    static let session = UUID(uuidString: "6F1C2E0A-1B2C-4D5E-8F90-0123456789AB")!

    static func text(_ id: String, _ text: String) -> RemoteWire.Item {
        RemoteWire.Item(id: id, kind: .text, text: text)
    }

    static func status(_ phase: RemoteWire.Phase = .ready, queued: Int = 0) -> RemoteWire.Status {
        RemoteWire.Status(phase: phase, closedReason: nil, permission: nil, question: nil, modes: [],
                          currentMode: nil, usage: nil, queued: queued)
    }

    static func patch(_ old: [RemoteWire.Item], _ new: [RemoteWire.Item],
                      _ oldStatus: RemoteWire.Status? = status(), _ newStatus: RemoteWire.Status = status()) -> RemoteWire.Patch? {
        RemoteWire.patch(session: session, from: old, to: new, oldStatus: oldStatus, newStatus: newStatus)
    }
}

// MARK: - Patches

struct RemoteWirePatchTests {
    @Test func nothingChangedIsNoPatch() {
        let items = [Wire.text("a", "hi")]
        #expect(Wire.patch(items, items) == nil)
    }

    @Test func appendedItemsAreUpsertsWithoutAnOrder() throws {
        let patch = try #require(Wire.patch([Wire.text("a", "hi")], [Wire.text("a", "hi"), Wire.text("b", "there")]))
        #expect(patch.upserts.map(\.id) == ["b"])
        #expect(patch.order == nil)
        #expect(patch.status == nil)
    }

    @Test func streamedTextChangesOneItem() throws {
        let patch = try #require(Wire.patch([Wire.text("a", "Hel")], [Wire.text("a", "Hello")]))
        #expect(patch.upserts == [Wire.text("a", "Hello")])
        #expect(patch.order == nil)
    }

    @Test(arguments: [
        // An item went.
        (["a", "b", "c"], ["a", "c"]),
        // One was put in before the end.
        (["a", "c"], ["a", "b", "c"]),
        // Everything's different.
        (["a"], ["b"]),
    ])
    func anyOtherOrderIsSentWhole(old: [String], new: [String]) throws {
        let patch = try #require(Wire.patch(old.map { Wire.text($0, $0) }, new.map { Wire.text($0, $0) }))
        #expect(patch.order == new)
    }

    @Test func statusAloneIsAPatch() throws {
        let items = [Wire.text("a", "hi")]
        let patch = try #require(Wire.patch(items, items, Wire.status(.ready), Wire.status(.running)))
        #expect(patch.upserts.isEmpty)
        #expect(patch.status?.phase == .running)
    }

    @Test func aFirstStatusIsAlwaysSent() throws {
        let patch = try #require(Wire.patch([], [], nil, Wire.status()))
        #expect(patch.status == Wire.status())
    }
}

// MARK: - From the chat's items

struct RemoteWireItemTests {
    @Test func imagesBecomeAddresses() {
        let id = UUID()
        let item = RemoteWire.item(from: .image(id: id, data: Data([1, 2, 3])), session: Wire.session)
        #expect(item.kind == .image)
        #expect(item.image == "/api/sessions/\(Wire.session.uuidString)/images/image-\(id.uuidString)/0")
    }

    @Test func aToolKeepsItsDiffsAndImageAddresses() throws {
        let call = ChatItem.ToolCall(id: "t1", title: "Edit a.swift", kind: "edit", status: "completed", output: "ok",
                                     diffs: [.init(path: "/a.swift", oldText: "x", newText: "y")],
                                     images: [Data([1]), Data([2])], input: "/a.swift")
        let item = RemoteWire.item(from: .tool(call), session: Wire.session)
        let tool = try #require(item.tool)
        #expect(item.id == "tool-t1")
        #expect(tool.diffs == [RemoteWire.Diff(path: "/a.swift", oldText: "x", newText: "y")])
        #expect(tool.images.count == 2)
        #expect(tool.images.last?.hasSuffix("/images/tool-t1/1") == true)
    }

    @Test func imageLooksUpByAddress() {
        let id = UUID()
        let call = ChatItem.ToolCall(id: "t1", title: "Read", kind: "read", status: "completed", output: "",
                                     diffs: [], images: [Data([9])])
        let items: [ChatItem] = [.image(id: id, data: Data([7])), .tool(call)]
        #expect(RemoteWire.image(in: items, item: "image-\(id.uuidString)", index: 0) == Data([7]))
        #expect(RemoteWire.image(in: items, item: "tool-t1", index: 0) == Data([9]))
        #expect(RemoteWire.image(in: items, item: "tool-t1", index: 1) == nil)
        #expect(RemoteWire.image(in: items, item: "nope", index: 0) == nil)
    }

    @Test(.tags(.edgeCase)) func longTextIsCutShort() {
        let long = String(repeating: "x", count: RemoteWire.textLimit * 2)
        let clipped = RemoteWire.clip(long)
        #expect(clipped.hasSuffix("(cut short)"))
        #expect(clipped.filter { $0 == "x" }.count == RemoteWire.textLimit)
        #expect(RemoteWire.clip("short") == "short")
    }

    @Test func aPermissionKeepsItsRequestID() throws {
        let p = PendingPermission(id: .number(7), title: "Run `ls`?",
                                  options: [.init(id: "allow_once", name: "Allow", kind: "allow_once")])
        let wire = try #require(RemoteWire.permission(p))
        #expect(wire.id == JSONValue.number(7).compactString)
        #expect(wire.options.map(\.id) == ["allow_once"])
    }

    @Test(arguments: [("accept", true), ("decline", true), ("cancel", true), ("maybe", false)])
    func answerActions(action: String, known: Bool) {
        #expect((RemoteWire.answer(action, content: nil) != nil) == known)
    }

    @Test func stateRoundTripsAsJSON() throws {
        let state = RemoteWire.State(
            session: .init(id: Wire.session, name: "Fix the build", agent: "claude", agentName: "Claude", folder: "~/code",
                           phase: .running, waiting: nil, isCheck: false),
            status: Wire.status(.running, queued: 1), items: [Wire.text("a", "hi")], omitted: 3)
        let data = try JSONEncoder().encode(state)
        #expect(try JSONDecoder().decode(RemoteWire.State.self, from: data) == state)
    }
}

// MARK: - The session's switch

struct RemoteSessionFlagTests {
    @Test func offIsNotWritten() throws {
        let s = Session(folderID: UUID(), agent: .claude, name: "x", order: 0, workdir: "/w", isChat: true)
        let json = String(decoding: try JSONEncoder().encode(s), as: UTF8.self)
        #expect(!json.contains("\"remote\""))
    }

    @Test func onRoundTrips() throws {
        var s = Session(folderID: UUID(), agent: .claude, name: "x", order: 0, workdir: "/w", isChat: true)
        s.isRemote = true
        let back = try JSONDecoder().decode(Session.self, from: try JSONEncoder().encode(s))
        #expect(back.isRemote)
    }
}
