import Foundation
import Testing
@testable import Sandshell

/// The menu bar status: what needs you first, then what works, then what
/// finished unseen; nothing else listed.
struct StatusMenuModelTests {
    private func entry(_ name: String, _ state: SessionRowStatus.State, workspace: String = "app") -> StatusMenuModel.Entry {
        let word = switch state {
        case .needsYou: "Needs you"
        case .working: "Working"
        default: "Finished"
        }
        return .init(id: UUID(), workspace: workspace, name: name, status: .init(state: state, word: word, detail: nil))
    }

    @Test func listsWhatNeedsYouThenWhatWorksThenWhatFinished() {
        let model = StatusMenuModel(entries: [
            entry("done", .finishedUnread), entry("idle", .idle), entry("busy", .working),
            entry("ask", .needsYou), entry("seen", .finishedSeen), entry("busy too", .working), entry("ready", .ready),
        ])
        #expect(model.entries.map(\.name) == ["ask", "busy", "busy too", "done"])
    }

    @Test(arguments: [
        ([SessionRowStatus.State](), "shippingbox", "", "No agents working"),
        ([.working, .working], "shippingbox.fill", "2", "2 working"),
        ([.working, .needsYou, .finishedUnread], "exclamationmark.bubble.fill", "1", "1 needs you · 1 working · 1 finished"),
        ([.needsYou, .needsYou], "exclamationmark.bubble.fill", "2", "2 need you"),
    ])
    func theMenuBarShowsWhatsMostPressing(states: [SessionRowStatus.State], symbol: String, title: String, headline: String) {
        let model = StatusMenuModel(entries: states.enumerated().map { entry("s\($0.offset)", $0.element) })
        #expect(model.symbol == symbol)
        #expect(model.title == title)
        #expect(model.headline == headline)
    }

    @Test func aLineNamesTheWorkspaceOnlyWhenThereAreSeveral() {
        let e = StatusMenuModel.Entry(id: UUID(), workspace: "app", name: "Fix login",
                                      status: .init(state: .working, word: "Working", detail: "3/6"))
        let model = StatusMenuModel(entries: [e])
        #expect(model.line(e, showWorkspace: false) == "Fix login — Working · 3/6")
        #expect(model.line(e, showWorkspace: true) == "app › Fix login — Working · 3/6")
    }
}
