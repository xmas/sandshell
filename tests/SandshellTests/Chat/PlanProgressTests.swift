import Testing
@testable import Sandshell

/// How far a plan is (Sandshell/Chat/PlanProgress.swift): the counts the
/// pinned plan and the sidebar row show, and the pinned plan's collapsed line.
struct PlanProgressTests {
    static func plan(_ statuses: [String]) -> [ChatItem.PlanEntry] {
        statuses.enumerated().map { ChatItem.PlanEntry(content: "Step \($0.offset + 1)", status: $0.element) }
    }

    static let halfway = plan(["completed", "completed", "completed", "in_progress", "pending", "pending"])

    @Test func countsWhatsDoneOfTheWhole() throws {
        let progress = try #require(PlanProgress(Self.halfway))
        #expect(progress.done == 3 && progress.total == 6)
        #expect(progress.count == "3 of 6")
        #expect(progress.compact == "3/6")
        #expect(progress.accessibilityLabel == "Plan: 3 of 6 done")
        #expect(!progress.isComplete)
    }

    @Test(.tags(.edgeCase))
    func anEmptyPlanHasNoProgress() {
        #expect(PlanProgress([]) == nil)
    }

    struct Headline: Sendable, CustomTestStringConvertible {
        let statuses: [String]
        let line: String
        let state: ChatItem.PlanEntry.State
        var testDescription: String { statuses.joined(separator: ",") }
    }

    static let headlines: [Headline] = [
        // What it's on now, with the spinner.
        Headline(statuses: ["completed", "in_progress", "pending"], line: "Step 2", state: .inProgress),
        // The first one in progress, when there are two.
        Headline(statuses: ["in_progress", "in_progress"], line: "Step 1", state: .inProgress),
        // Between entries: what's next, on an empty ring.
        Headline(statuses: ["completed", "pending", "pending"], line: "Step 2", state: .pending),
        Headline(statuses: ["pending"], line: "Step 1", state: .pending),
        // Every one done.
        Headline(statuses: ["completed", "completed"], line: "All done", state: .completed),
    ]

    @Test(arguments: headlines)
    func theCollapsedLineSaysWhatItsOn(_ c: Headline) throws {
        let progress = try #require(PlanProgress(Self.plan(c.statuses)))
        #expect(progress.headline == c.line)
        #expect(progress.headlineState == c.state)
    }

    @Test(.tags(.edgeCase))
    func aMultilineEntryHeadlinesOnOneLine() throws {
        let progress = try #require(PlanProgress([.init(content: "Fix\nthe build", status: "in_progress")]))
        #expect(progress.headline == "Fix the build")
    }

    @Test(arguments: [("completed", ChatItem.PlanEntry.State.completed), ("in_progress", .inProgress),
                      ("pending", .pending), ("", .pending), ("cancelled", .pending)])
    func statusReadsAsAState(status: String, state: ChatItem.PlanEntry.State) {
        #expect(ChatItem.PlanEntry(content: "x", status: status).state == state)
    }
}
