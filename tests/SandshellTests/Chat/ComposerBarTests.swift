import AppKit
import Testing
@testable import Sandshell

/// The composer: its readout (`$0.47 · 38%`), the choosers' titles, which
/// controls a chat shows, and the pill with its Send/Stop button.
@MainActor
struct ComposerBarTests {
    // MARK: Readout

    @Test func theReadoutIsCostThenContext() {
        let text = ClaudeReadout.text(cost: 0.47, percent: 38)
        #expect(text == "\(ClaudeStatsFormat.usd(0.47)) · \(38.formatted(.percent))")
    }

    @Test func theReadoutShowsWhicheverHalfItHas() {
        #expect(ClaudeReadout.text(cost: nil, percent: 38) == 38.formatted(.percent))
        #expect(ClaudeReadout.text(cost: 1.5, percent: nil) == ClaudeStatsFormat.usd(1.5))
        #expect(ClaudeReadout.text(cost: nil, percent: nil).isEmpty)
    }

    @Test(arguments: [
        (380, 1000, 38),
        (999, 1000, 99),     // rounded down, like the strip's
        (0, 200_000, 0),
        (250_000, 200_000, 125),
    ])
    func contextPercent(used: Int, size: Int, percent: Int) {
        #expect(ClaudeReadout.percent(used: used, size: size) == percent)
    }

    @Test(.tags(.edgeCase))
    func noContextWindowHasNoPercent() {
        #expect(ClaudeReadout.percent(used: 10, size: 0) == nil)
    }

    @Test func thePricedConversationBeatsThisRunsCost() {
        let convo = ClaudeUsageTotals(messages: 12, costUSD: 2.25)
        #expect(ClaudeReadout.cost(conversation: convo, run: 0.4) == 2.25)
    }

    @Test(arguments: [nil, ClaudeUsageTotals(messages: 0, costUSD: 0)])
    func withoutAPricedConversationItsThisRun(conversation: ClaudeUsageTotals?) {
        #expect(ClaudeReadout.cost(conversation: conversation, run: 0.4) == 0.4)
        #expect(ClaudeReadout.cost(conversation: conversation, run: nil) == nil)
    }

    // MARK: Chooser titles

    @Test func choosersNameTheirDefaults() {
        #expect(ClaudeReadout.modelTitle(nil) == "Default model")
        #expect(ClaudeReadout.modelTitle("") == "Default model")
        #expect(ClaudeReadout.effortTitle(nil) == "Default effort")
    }

    @Test func choosersNameTheirPicks() {
        #expect(ClaudeReadout.effortTitle("high") == "High")
        #expect(ClaudeReadout.modelTitle("claude-opus-5-5") == "Opus 5.5")
        #expect(ClaudeReadout.modelTitle("claude-opus-5-5[1m]") == "Opus 5.5", "Claude Code's 1M suffix is the same model")
    }

    // MARK: Which controls

    @Test func aClaudeChatHasItsChoosersAndADetailsReadoutFromTheStart() {
        let pieces = ComposerPieces.for(agent: .claude, hasModels: true, hasModes: true, hasExtras: true, hasUsage: false)
        #expect(pieces == ComposerPieces(claudeChoosers: true, agentModel: false, mode: true, mcp: true,
                                         readout: true, readoutOpensDetails: true))
    }

    @Test func otherAgentsUseTheirOwnModelsAndShowUsageOnlyOnceTheyHaveIt() {
        let before = ComposerPieces.for(agent: .codex, hasModels: true, hasModes: true, hasExtras: false, hasUsage: false)
        #expect(before == ComposerPieces(claudeChoosers: false, agentModel: true, mode: true, mcp: false,
                                         readout: false, readoutOpensDetails: false))
        let after = ComposerPieces.for(agent: .codex, hasModels: true, hasModes: true, hasExtras: false, hasUsage: true)
        #expect(after.readout && !after.readoutOpensDetails)
    }

    @Test func mcpShowsOnlyThroughTheAdapterWrapper() {
        #expect(!ComposerPieces.for(agent: .claude, hasModels: false, hasModes: false, hasExtras: false, hasUsage: true).mcp)
    }

    @Test func nothingToChooseHidesTheChooser() {
        let pieces = ComposerPieces.for(agent: .gemini, hasModels: false, hasModes: false, hasExtras: false, hasUsage: false)
        #expect(!pieces.agentModel && !pieces.mode && !pieces.readout)
    }

    // MARK: The pill

    @Test func thePillIsFortyEightPointsWithTheRoundButtonInside() throws {
        let composer = ChatComposerView(frame: NSRect(x: 0, y: 0, width: 600, height: 48))
        composer.layoutSubtreeIfNeeded()
        #expect(composer.fittingSize.height == ChatComposerView.minHeight)
        #expect(composer.layer?.cornerRadius == 24)
        #expect(composer.layer?.shadowOpacity == 0, "no drop shadow")
        let button = composer.sendButton.frame
        #expect(button.size == NSSize(width: 24, height: 24))
        #expect(composer.bounds.contains(button), "inside the pill")
        #expect(abs(button.midY - composer.bounds.midY) <= 0.5, "centred on one line")
        #expect(abs(composer.bounds.maxX - button.maxX - 13) <= 0.5, "14 pt in from the right, less the border")
    }

    @Test(arguments: [
        (ComposerSendButton.Mode.send, "Send"),
        (.stop, "Stop"),
        (.reconnect, "Reconnect"),
    ])
    func theRoundButtonSaysWhatItDoes(mode: ComposerSendButton.Mode, label: String) {
        let button = ComposerSendButton()
        button.mode = mode
        #expect(button.accessibilityLabel() == label)
        #expect(button.accessibilityIdentifier() == "chat-send-stop")
    }
}
