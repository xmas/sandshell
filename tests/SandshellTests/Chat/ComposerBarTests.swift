import AppKit
import Testing
@testable import Sandshell

/// The composer: its readout (`$0.47 · 38%`), the choosers' titles, which
/// controls a chat shows, and the pill with its Send/Stop button.
@MainActor
struct ComposerBarTests {
    // MARK: Readout

    @Test func theReadoutIsContextThenCost() {
        let text = ClaudeReadout.text(cost: 0.47, percent: 38)
        #expect(text == "\(38.formatted(.percent)) context · \(ClaudeStatsFormat.usd(0.47))")
    }

    @Test func theReadoutShowsWhicheverHalfItHas() {
        #expect(ClaudeReadout.text(cost: nil, percent: 38) == "\(38.formatted(.percent)) context")
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

    /// The composer and its controls (and messages queued above it) never
    /// hold a pane wide: a chat goes down to 380 pt, the controls giving way
    /// in turn. In a wide pane the composer takes the readable width, queue
    /// or no queue.
    @Test(arguments: [(CGFloat(380), false), (300, true), (1200, false), (1200, true)])
    func aChatGoesNarrow(width: CGFloat, queued: Bool) {
        let session = ChatSession(title: "Claude", containerName: "test-sandbox", workdir: "/nonexistent/work",
                                  home: "/nonexistent/home", mcpURL: nil)
        if queued {
            // Not started: it waits, as it would behind a turn.
            session.sendWhenReady(text: "A long queued message " + String(repeating: "that goes on ", count: 40), attachments: [])
        }
        let view = ChatSessionView(session: session)
        view.debugTranscript.debugApplyNow([
            .user(id: UUID(), text: "A question with a_very_long_unbreakable_identifier_in_it_that_goes_on_and_on", attachments: []),
            .agentText(id: "a", text: "An answer.\n\n```\nlet code = \"a long line of code that would like to be wide\"\n```"),
        ])
        // Held to the width only as firmly as a split view holds its panes.
        let pane = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 600))
        view.translatesAutoresizingMaskIntoConstraints = false
        pane.addSubview(view)
        let held = view.widthAnchor.constraint(equalToConstant: width)
        held.priority = .init(250)
        NSLayoutConstraint.activate([
            held,
            view.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
            view.topAnchor.constraint(equalTo: pane.topAnchor),
            view.heightAnchor.constraint(equalToConstant: 600),
        ])
        pane.layoutSubtreeIfNeeded()
        #expect(view.frame.width == width, "nothing in it insists on more")
        let bar = view.debugBarFrame
        #expect(bar.minX >= 0 && bar.maxX <= width, "the controls stay inside (\(bar))")
        #expect(view.debugComposer.frame.maxX <= width)
        let composer = view.debugComposer.frame.width
        if width > ChatTranscriptView.readableWidth + 32 {
            #expect(composer == ChatTranscriptView.readableWidth, "the readable width, less its margins (\(composer))")
        }
        if queued {
            #expect(!view.debugQueuedView.isHidden)
            #expect(view.debugQueuedView.debugCards.allSatisfy { $0.frame.width == composer }, "cards as wide as the composer")
        }
    }

    /// Every control, at a width: what still shows fits, in the shedding order.
    @Test(arguments: [
        (700, ["chat-attach", "chat-mcp", "chat-model", "chat-effort", "chat-mode", "chat-details"]),
        (260, ["chat-attach", "chat-mcp", "chat-model", "chat-details"]),
        (120, ["chat-attach", "chat-details"]),
    ] as [(CGFloat, [String])])
    func theControlsGiveWayInTurn(width: CGFloat, shown: [String]) {
        let bar = ComposerBar(frame: NSRect(x: 0, y: 0, width: width, height: 24))
        bar.modePopup.set([.init(id: "default", title: "Ask"), .init(id: "auto", title: "Auto")], current: "auto")
        bar.showMCP(count: 3, failing: [])
        bar.claude.showModel(title: "Opus 5.5", id: "claude-opus-5-5", color: .labelColor)
        bar.claude.showEffort(title: "Extra High", id: "xhigh", color: .secondaryLabelColor)
        bar.pieces = ComposerPieces(claudeChoosers: true, mode: true, mcp: true, readout: true, readoutOpensDetails: true)
        bar.readoutText = "$12.47 · 38%"
        bar.layoutSubtreeIfNeeded()
        #expect(bar.debugShown == shown)
        #expect(bar.debugShownFrames.allSatisfy { $0.maxX <= width + 0.5 }, "\(bar.debugShownFrames)")
    }

    #if DEBUG
    // MARK: Keys in the composer

    private static let up = #selector(NSResponder.moveUp(_:))
    private static let down = #selector(NSResponder.moveDown(_:))
    private static let tab = #selector(NSResponder.insertTab(_:))
    private static let escape = #selector(NSResponder.cancelOperation(_:))

    @Test func upAndDownWalkWhatWasSent() {
        let composer = ChatComposerView(frame: NSRect(x: 0, y: 0, width: 600, height: 48))
        composer.sentHistory = { ["first", "second"] }
        composer.debugCommand(Self.up)
        #expect(composer.debugText == "second")
        composer.debugCommand(Self.up)
        #expect(composer.debugText == "first")
        composer.debugCommand(Self.down)
        #expect(composer.debugText == "second")
        composer.debugCommand(Self.down)
        #expect(composer.debugText.isEmpty, "past the newest: the empty draft again")
    }

    @Test func escapeLeavesTheHistory() {
        let composer = ChatComposerView(frame: NSRect(x: 0, y: 0, width: 600, height: 48))
        composer.sentHistory = { ["first"] }
        var escaped = false
        composer.onEscape = { escaped = true; return true }
        composer.debugCommand(Self.up)
        composer.debugCommand(Self.escape)
        #expect(composer.debugText.isEmpty)
        #expect(!escaped, "⎋ went to the history, not the chat (it would stop a turn)")
    }

    @Test func upInADraftIsTheCaretsNotTheHistorys() {
        let composer = ChatComposerView(frame: NSRect(x: 0, y: 0, width: 600, height: 48))
        composer.sentHistory = { ["first"] }
        composer.setDraft("my draft")
        composer.debugCommand(Self.up)
        #expect(composer.debugText == "my draft")
    }

    @Test func anEditedRecallStopsTheWalk() {
        let composer = ChatComposerView(frame: NSRect(x: 0, y: 0, width: 600, height: 48))
        composer.sentHistory = { ["first", "second"] }
        composer.debugCommand(Self.up)
        composer.debugType("second, edited")
        composer.debugCommand(Self.up)
        #expect(composer.debugText == "second, edited")
    }

    @Test func theSuggestionIsThePlaceholderAndTabTakesIt() {
        let composer = ChatComposerView(frame: NSRect(x: 0, y: 0, width: 600, height: 48))
        #expect(composer.debugPlaceholder.hasPrefix("Message Claude…"))
        composer.suggestion = "Run the tests"
        #expect(composer.debugPlaceholder == "Run the tests")
        composer.debugCommand(Self.tab)
        #expect(composer.debugText == "Run the tests")
        composer.suggestion = nil
        #expect(composer.debugPlaceholder.hasPrefix("Message Claude…"))
    }

    @Test func editingAQueuedMessagePutsItAheadOfTheDraft() {
        let composer = ChatComposerView(frame: NSRect(x: 0, y: 0, width: 600, height: 48))
        composer.setDraft("typed")
        composer.edit(QueuedPrompt(text: "queued"))
        #expect(composer.debugText == "queued\n\ntyped")
    }

    /// Stop's arc orbits only in a window, while a turn runs.
    @Test func theOrbitRunsOnlyForStopInAWindow() {
        let button = ComposerSendButton()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(button)
        #expect(!button.debugOrbiting, "Send doesn't orbit")
        button.mode = .stop
        #expect(button.debugOrbiting == !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        button.mode = .send
        #expect(!button.debugOrbiting)
        button.mode = .stop
        button.removeFromSuperview()
        #expect(!button.debugOrbiting, "out of the window it stops")
    }
    #endif

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
