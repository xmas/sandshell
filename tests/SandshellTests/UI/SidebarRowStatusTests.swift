import AppKit
import Foundation
import Testing
@testable import Sandshell

/// The sidebar row's status grammar (Sandshell/UI/SidebarRowStatus.swift):
/// the six states, the order they sort in, the time column, the instruction
/// line, what a waiting agent waits for, and the palette.
struct SidebarRowStatusTests {
    static let now = Date(timeIntervalSince1970: 1_700_000_000)

    /// A runtime in one of the six states (nil: not run since launch).
    static func runtime(_ state: SessionRowStatus.State, model: String? = "Opus 5.5") -> SessionRuntime? {
        var rt = SessionRuntime()
        if let model {
            var status = ClaudeSessionStatus()
            status.model = .init(id: "claude-opus-5-5", displayName: model)
            rt.claudeStatus = status
        }
        switch state {
        case .needsYou:
            rt.status = .working
            rt.workingSince = now.addingTimeInterval(-60)
            rt.isWaiting = true
            rt.waitingFor = "permission to run tests"
            rt.lastActivityAt = now.addingTimeInterval(-360)
        case .working:
            rt.status = .working
            rt.workingSince = now.addingTimeInterval(-252)
        case .finishedUnread:
            rt.workSecondsCompleted = 720
            rt.isUnread = true
        case .finishedSeen:
            rt.workSecondsCompleted = 120
        case .stopped:
            rt.stoppedReason = "exit 1\nmore detail"
        case .ready:
            rt.isLive = true
        case .idle:
            return nil
        }
        return rt
    }
}

// MARK: - A plan's progress

extension SidebarRowStatusTests {
    struct PlanProgressDetail {
        static func working(plan statuses: [String]?) -> SessionRuntime? {
            var rt = SidebarRowStatusTests.runtime(.working)
            if let statuses {
                rt?.planProgress = PlanProgress(statuses.map { ChatItem.PlanEntry(content: "x", status: $0) })
            }
            return rt
        }

        @Test func aWorkingRowSaysHowFarThroughItsPlan() {
            let rt = Self.working(plan: ["completed", "completed", "completed", "in_progress", "pending", "pending"])
            let status = SessionRowStatus.of(rt, agent: .claude)
            #expect(status.word == "Working")
            #expect(status.detail == "3/6")
        }

        @Test func withoutAPlanItKeepsTheModel() {
            #expect(SessionRowStatus.of(Self.working(plan: nil), agent: .claude).detail == "Opus 5.5")
            #expect(SessionRowStatus.of(Self.working(plan: []), agent: .claude).detail == "Opus 5.5")
        }

        @Test(arguments: [SessionRowStatus.State.needsYou, .finishedUnread, .finishedSeen, .ready])
        func onlyWorkingShowsIt(_ state: SessionRowStatus.State) {
            var rt = SidebarRowStatusTests.runtime(state)
            rt?.planProgress = PlanProgress([.init(content: "x", status: "completed")])
            #expect(SessionRowStatus.of(rt, agent: .claude).detail?.contains("1/1") != true)
        }
    }
}

// MARK: - The six states

extension SidebarRowStatusTests {
    struct States {
        struct Case: Sendable, CustomTestStringConvertible {
            let state: SessionRowStatus.State
            let agent: AgentKind
            let word: String
            let detail: String?
            let glyph: SessionRowStatus.Glyph
            let tone: SessionRowStatus.Tone
            var testDescription: String { "\(state) (\(agent.rawValue))" }
        }

        static let cases: [Case] = [
            Case(state: .needsYou, agent: .claude, word: "Needs you", detail: "permission to run tests", glyph: .dot, tone: .needsYou),
            Case(state: .working, agent: .claude, word: "Working", detail: "Opus 5.5", glyph: .spinner, tone: .working),
            Case(state: .finishedUnread, agent: .claude, word: "Finished", detail: "worked 12m 0s · Opus 5.5", glyph: .dot, tone: .fresh),
            Case(state: .finishedSeen, agent: .claude, word: "Finished", detail: "worked 2m 0s · Opus 5.5", glyph: .dimDot, tone: .muted),
            Case(state: .stopped, agent: .claude, word: "Stopped", detail: "exit 1", glyph: .dot, tone: .error),
            Case(state: .ready, agent: .claude, word: "Ready", detail: "Opus 5.5", glyph: .dot, tone: .live),
            Case(state: .ready, agent: .shell, word: "Ready", detail: "Shell", glyph: .dot, tone: .live),
            Case(state: .idle, agent: .claude, word: "Not running", detail: nil, glyph: .dimDot, tone: .muted),
            Case(state: .idle, agent: .shell, word: "Not running", detail: "Shell", glyph: .dimDot, tone: .muted),
        ]

        @Test(arguments: cases)
        func eachStateReadsInOneGrammar(_ c: Case) {
            let status = SessionRowStatus.of(SidebarRowStatusTests.runtime(c.state), agent: c.agent)
            #expect(status.state == c.state)
            #expect(status.word == c.word)
            #expect(status.detail == c.detail)
            #expect(status.glyph == c.glyph)
            #expect(status.tone == c.tone)
        }

        @Test func onlyAnUnreadRowHasASemiboldTitle() {
            for state in SessionRowStatus.State.allCases {
                let status = SessionRowStatus.of(SidebarRowStatusTests.runtime(state), agent: .claude)
                #expect(status.titleIsEmphasized == (state == .finishedUnread), "\(state)")
            }
        }

        @Test func theAgentsNameNeverAppearsForClaude() {
            for state in SessionRowStatus.State.allCases {
                let status = SessionRowStatus.of(SidebarRowStatusTests.runtime(state), agent: .claude)
                #expect(status.detail?.contains("Claude") != true, "\(state)")
            }
        }

        @Test(.tags(.edgeCase))
        func aStoppedSessionIsStoppedWhateverElseItSays() {
            var rt = SidebarRowStatusTests.runtime(.needsYou)
            rt?.stoppedReason = "exit 2"
            #expect(SessionRowStatus.state(of: rt) == .stopped)
        }

        @Test(.tags(.edgeCase))
        func aRunningAgentThatNeverWorkedIsReadyAndAStoppedOneIsNotRunning() {
            var rt = SessionRuntime()
            rt.isLive = true
            rt.lastActivityAt = SidebarRowStatusTests.now
            #expect(SessionRowStatus.state(of: rt) == .ready)
            rt.isLive = false
            #expect(SessionRowStatus.state(of: rt) == .idle)
            #expect(SessionRowStatus.state(of: nil) == .idle)
        }

        @Test(arguments: [
            (SessionRowStatus.State.needsYou, false, true), (.working, false, true), (.ready, false, true),
            (.finishedSeen, true, true), (.finishedSeen, false, false), (.stopped, false, false), (.idle, false, false),
        ])
        func aRowIsRunningWhileItsAgentIs(_ state: SessionRowStatus.State, _ live: Bool, _ running: Bool) {
            let status = SessionRowStatus.of(SidebarRowStatusTests.runtime(state), agent: .claude)
            #expect(status.isRunning(live: live) == running)
        }

        @Test(.tags(.edgeCase))
        func withoutAModelOrWorkTimeTheDetailGoes() {
            let working = SessionRowStatus.of(SidebarRowStatusTests.runtime(.working, model: nil), agent: .codex)
            #expect(working.detail == nil)
            var rt = SessionRuntime()
            rt.isUnread = true
            #expect(SessionRowStatus.of(rt, agent: .codex).detail == nil)
        }

        @Test(arguments: [
            (SessionRowStatus.State.needsYou, SessionRowStatus.TimeTone.status(.needsYou)),
            (.working, .status(.working)),
            (.finishedUnread, .foreground),
            (.finishedSeen, .muted),
            (.stopped, .muted),
            (.ready, .muted),
            (.idle, .muted),
        ])
        func theTimeTakesTheStatusColourWhileItWorksOrWaits(_ state: SessionRowStatus.State,
                                                           _ tone: SessionRowStatus.TimeTone) {
            #expect(SessionRowStatus.of(SidebarRowStatusTests.runtime(state), agent: .claude).timeTone == tone)
        }

        @Test(arguments: [
            (SessionRowStatus.State.needsYou, false, false, true),
            (.working, false, false, true),
            (.finishedUnread, false, false, true),
            (.finishedSeen, false, false, false),
            (.finishedSeen, true, false, true),
            (.idle, false, true, true),
            (.stopped, false, false, false),
        ])
        func theTitleIsFullStrengthWhenLiveUnreadOrSelected(_ state: SessionRowStatus.State, _ selected: Bool,
                                                           _ live: Bool, _ full: Bool) {
            let status = SessionRowStatus.of(SidebarRowStatusTests.runtime(state), agent: .claude)
            #expect(status.titleIsFullStrength(selected: selected, live: live) == full)
        }
    }
}

// MARK: - Order

extension SidebarRowStatusTests {
    struct Order {
        private static let t0 = SidebarRowStatusTests.now

        private static func session(_ name: String) -> Session {
            Session(folderID: UUID(), agent: .claude, name: name, order: 0, workdir: "/w", createdAt: t0.addingTimeInterval(-3600))
        }

        /// Arranged by activity (seconds after t0) with the rows' rank, as names ("fork < top").
        private static func arrange(_ sessions: [Session], activity: [String: TimeInterval],
                                    states: [String: SessionRowStatus.State]) -> [String] {
            let names = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0.name) })
            let entries = SessionOrder.arrange(sessions, lastActivity: { t0.addingTimeInterval(activity[$0.name] ?? 0) },
                                               rank: { s in SessionRowStatus.rank(states[s.name].flatMap { SidebarRowStatusTests.runtime($0) }) })
            return entries.map { e in e.nestedUnder.map { "\(names[e.id]!) < \(names[$0]!)" } ?? names[e.id]! }
        }

        @Test func needsYouThenWorkingThenRecency() {
            let names = ["old-waiting", "new-idle", "mid-working", "newest-finished"]
            let sessions = names.map(Self.session)
            let order = Self.arrange(sessions,
                                     activity: ["old-waiting": 10, "new-idle": 300, "mid-working": 100, "newest-finished": 400],
                                     states: ["old-waiting": .needsYou, "mid-working": .working, "newest-finished": .finishedUnread])
            #expect(order == ["old-waiting", "mid-working", "newest-finished", "new-idle"])
        }

        @Test func aForkThatNeedsYouLiftsItsWholeGroup() {
            let a = Self.session("a"), b = Self.session("b")
            let f = Session.fork(of: a, name: "f", order: 0, workdir: "/w", at: Self.t0.addingTimeInterval(5))
            let order = Self.arrange([a, b, f], activity: ["a": 10, "b": 500, "f": 20], states: ["f": .needsYou])
            #expect(order == ["a", "f < a", "b"], "The group sits at its best member's rank, source on top")
        }

        @Test func workingSessionsSortAmongThemselvesByActivity() {
            let (a, b) = (Self.session("a"), Self.session("b"))
            #expect(Self.arrange([a, b], activity: ["a": 10, "b": 20], states: ["a": .working, "b": .working]) == ["b", "a"])
        }

        @Test(arguments: SessionRowStatus.State.allCases)
        func rankFollowsTheState(_ state: SessionRowStatus.State) {
            let expected = switch state { case .needsYou: 0; case .working: 1; default: 2 }
            #expect(SessionRowStatus.rank(SidebarRowStatusTests.runtime(state)) == expected)
        }
    }
}

// MARK: - Time

extension SidebarRowStatusTests {
    struct Time {
        @Test func workingShowsTheTurnsElapsedTime() {
            let rt = SidebarRowStatusTests.runtime(.working)
            #expect(SessionRowStatus.time(rt, lastActivity: nil, now: SidebarRowStatusTests.now) == "4:12")
        }

        @Test func needsYouShowsWhenItLastWrote() {
            let rt = SidebarRowStatusTests.runtime(.needsYou)
            #expect(SessionRowStatus.time(rt, lastActivity: rt?.lastActivityAt, now: SidebarRowStatusTests.now) == "6m")
        }

        @Test(arguments: [
            (5.0, "now"), (45.0, "45s"), (180.0, "3m"), (7200.0, "2h"), (2.0 * 86400, "2d"),
        ] as [(TimeInterval, String)])
        func otherwiseHowLongAgo(_ seconds: TimeInterval, _ expected: String) {
            let then = SidebarRowStatusTests.now.addingTimeInterval(-seconds)
            #expect(SessionRowStatus.time(SidebarRowStatusTests.runtime(.finishedSeen), lastActivity: then,
                                          now: SidebarRowStatusTests.now) == expected)
        }

        @Test func neverActiveShowsNoTime() {
            #expect(SessionRowStatus.time(nil, lastActivity: nil, now: SidebarRowStatusTests.now) == nil)
        }

        @Test(arguments: [(0.0, "0:00"), (9, "0:09"), (252, "4:12"), (3599, "59:59"), (3725, "1:02:05")])
        func elapsedReadsAsMinutesAndSeconds(_ seconds: TimeInterval, _ expected: String) {
            #expect(SessionRowStatus.elapsed(seconds) == expected)
        }

        @Test(.tags(.edgeCase))
        func aWorkingRuntimeWithoutAStartUsesItsWorkTotal() {
            var rt = SessionRuntime()
            rt.status = .working
            rt.workSecondsCompleted = 65
            #expect(SessionRowStatus.time(rt, lastActivity: nil, now: SidebarRowStatusTests.now) == "1:05")
        }
    }
}

// MARK: - The card's third line

extension SidebarRowStatusTests {
    struct CardDetail {
        private func runtime(working: Bool = false, waiting: Bool = false, plan: [String] = [], ask: String? = nil) -> SessionRuntime {
            var rt = SessionRuntime()
            rt.isLive = true
            if working { rt.status = .working }
            rt.isWaiting = waiting
            rt.waitingFor = waiting ? "a question" : nil
            rt.waitingAsk = ask
            rt.planProgress = PlanProgress(plan.enumerated().map { ChatItem.PlanEntry(content: "step \($0)", status: $1) })
            return rt
        }
        private let prompts = ["the newest", "the one before", "an older one", "the oldest"]

        @Test func aWorkingCardListsTheStepsAroundWhereItIsAndTwoPrompts() throws {
            let rt = runtime(working: true, plan: ["completed", "completed", "in_progress", "pending", "pending"])
            let card = try #require(SessionRowStatus.card(rt, prompts: prompts, density: .comfortable))
            #expect(card.steps.map(\.title) == ["step 1", "step 2", "step 3"])
            #expect(card.steps.map(\.state) == [.completed, .inProgress, .pending])
            #expect(card.prompts == ["the newest", "the one before"])
            #expect(SessionRowStatus.of(rt, agent: .claude, planOnOwnLine: true).detail == "2 of 5")
            #expect(SessionRowStatus.of(rt, agent: .claude).detail == "2/5", "compact: the count")
        }

        @Test(arguments: [
            (["in_progress", "pending"], ["step 0", "step 1"]),                // at the start
            (["completed", "completed"], ["step 0", "step 1"]),               // all done: the last two
            (["completed", "pending", "pending"], ["step 0", "step 1", "step 2"]), // nothing in progress: the next
        ] as [([String], [String])])
        func theStepsAroundStayInsideThePlan(plan: [String], around: [String]) throws {
            let rt = runtime(working: true, plan: plan)
            #expect(try #require(SessionRowStatus.card(rt, prompts: [], density: .comfortable)).steps.map(\.title) == around)
        }

        @Test func aCardThatNeedsYouSaysWhatItAsksAndTwoPrompts() throws {
            let rt = runtime(waiting: true, ask: "Which branch?\nmain or dev")
            let card = try #require(SessionRowStatus.card(rt, prompts: prompts, density: .comfortable))
            #expect(card.ask == "Which branch? main or dev")
            #expect(card.prompts.count == 2)
        }

        @Test func otherwiseItQuotesThreePrompts() throws {
            let card = try #require(SessionRowStatus.card(runtime(), prompts: prompts, density: .comfortable))
            #expect(card.prompts == ["the newest", "the one before", "an older one"])
            #expect(card.ask == nil && card.steps.isEmpty)
        }

        @Test func nothingToSayIsNoDetail() {
            #expect(SessionRowStatus.card(runtime(), prompts: [], density: .comfortable) == nil)
            #expect(SessionRowStatus.card(runtime(working: true, plan: ["in_progress"]), prompts: prompts, density: .compact) == nil,
                    "compact cards never have one")
        }

        @Test func theDetailSetsTheHeight() {
            let comfortable = SidebarDensity.comfortable
            #expect(comfortable.sessionRowHeight() == 50)
            let quotes = SessionRowStatus.Card(prompts: ["a", "b", "c"])
            let plan = SessionRowStatus.Card(steps: [.init(title: "x", state: .inProgress)], prompts: ["a"])
            let ask = SessionRowStatus.Card(ask: "Allow it?")
            #expect(comfortable.sessionRowHeight(card: quotes) > comfortable.sessionRowHeight())
            #expect(comfortable.sessionRowHeight(card: plan) < comfortable.sessionRowHeight(card: quotes))
            #expect(comfortable.sessionRowHeight(card: ask) > comfortable.sessionRowHeight(card: .init(prompts: ["a"])))
            #expect(SidebarDensity.compact.sessionRowHeight(card: quotes) == 40)
        }

        @Test func theFirstInstructionIsTheTooltipOnlyWhenTheTitleIsntIt() {
            #expect(SessionRowStatus.instruction(displayName: "Fix links", firstPrompt: "What's not checked in?") == "What's not checked in?")
            #expect(SessionRowStatus.instruction(displayName: "is hatch accessible?", firstPrompt: "  is hatch accessible?\n") == nil)
            #expect(SessionRowStatus.instruction(displayName: "Title", firstPrompt: "first\nsecond\n\nthird") == "first second third")
            #expect(SessionRowStatus.instruction(displayName: "Fork", firstPrompt: nil) == nil)
        }

        @Test(arguments: [
            ("`swift test`", "Allow `swift test`?"),
            ("Edit Sources/App.swift", "Allow Edit Sources/App.swift?"),
            ("Allow this action?", "Allow this action?"),
            ("", "Allow this action?"),
        ])
        func aPermissionIsAskedAsAQuestion(title: String, ask: String) {
            #expect(WaitingFor.ask(permission: title) == ask)
        }
    }
}

// MARK: - Waiting for

extension SidebarRowStatusTests {
    struct Waiting {
        @Test(arguments: [
            ("`swift test`", "permission to run swift test"),
            ("Edit `Sources/App.swift`", "permission to edit Sources/App.swift"),
            ("Fetch https://example.com", "permission to fetch https://example.com"),
            ("mcp__github__create_issue", "permission for mcp__github__create_issue"),
            ("Allow this action?", "permission"),
            ("", "permission"),
            ("`make`\nand more", "permission to run make"),
        ])
        func permissionReadsAsWhatItWouldDo(_ title: String, _ expected: String) {
            #expect(WaitingFor.permission(title) == expected)
        }

        @Test func questionsAndSignIns() throws {
            let one = AgentQuestion(rpcID: 1, message: "Pick", mode: .form, fields: [
                .init(id: "q", title: "Color", detail: nil, kind: .text(secret: false), required: true, companionOf: nil, defaultValue: nil),
            ], toolCallID: nil)
            #expect(WaitingFor.question(one) == "a question")
            let two = AgentQuestion(rpcID: 1, message: "Pick", mode: .form, fields: one.fields + [
                .init(id: "r", title: "Size", detail: nil, kind: .toggle, required: false, companionOf: nil, defaultValue: nil),
                .init(id: "r_custom", title: "Other", detail: nil, kind: .text(secret: false), required: false, companionOf: "r", defaultValue: nil),
            ], toolCallID: nil)
            #expect(WaitingFor.question(two) == "2 questions", "Its Other boxes aren't questions")
            let url = try #require(URL(string: "https://example.com/login"))
            let link = AgentQuestion(rpcID: 1, message: "Sign in", mode: .url(url, elicitationID: nil), fields: [], toolCallID: nil)
            #expect(WaitingFor.question(link) == "a sign-in")
        }
    }
}

// MARK: - Palette

extension SidebarRowStatusTests {
    @MainActor
    struct Palette {
        /// The design's default dark sidebar.
        private let palette = SidebarPalette(background: .hex("2A2320"), foreground: .hex("F2EDE8"), isDark: true)

        private static func distance(_ a: NSColor, _ hex: String) -> CGFloat {
            let x = a.usingColorSpace(.sRGB)!, y = NSColor.hex(hex).usingColorSpace(.sRGB)!
            return max(abs(x.redComponent - y.redComponent), abs(x.greenComponent - y.greenComponent),
                       abs(x.blueComponent - y.blueComponent)) * 255
        }

        @Test func theDefaultSidebarComesOutAtTheDesignsValues() {
            let expected: [(NSColor, String, String)] = [
                (palette.dimForeground, "CFC5BC", "80 % title"),
                (palette.muted, "A89C92", "muted"),
                (palette.instruction, "8E8278", "instruction"),
                (palette.selectedFill, "3F3631", "selected fill"),
                (palette.otherPaneFill, "322B27", "open in another pane"),
                (palette.hoverFill, "342C28", "hover"),
                (palette.searchFill, "1F1A17", "search field"),
                (palette.rail, "4F443E", "rail"),
                (palette.separator, "3A322D", "footer border"),
            ]
            for (color, hex, what) in expected {
                // Mixed from the two colours, so a touch less warm than the
                // hand-picked swatches: within 12 of 255 on any channel.
                #expect(Self.distance(color, hex) <= 12, "\(what): \(color.hexString) vs \(hex)")
            }
        }

        @Test func statusColoursAreTheDesigns() {
            #expect(Self.distance(palette.color(for: .needsYou), "F2B13A") < 1)
            #expect(Self.distance(palette.color(for: .working), "E8845A") < 1)
            #expect(Self.distance(palette.color(for: .fresh), "7FB3FF") < 1)
            #expect(Self.distance(palette.color(for: .error), "FF6B6B") < 1)
            #expect(palette.color(for: SessionRowStatus.Tone.muted) == palette.muted)
        }

        @Test func aLightSidebarGetsLightFillsAndDarkerStatusColours() {
            let light = SidebarPalette(background: .hex("FFFFFF"), foreground: .hex("1A1D24"), isDark: false)
            #expect(light.selectedFill.brightnessComponent > 0.85)
            #expect(light.searchFill.brightnessComponent > 0.85)
            #expect(light.color(for: .needsYou).brightnessComponent < NSColor.hex("F2B13A").brightnessComponent)
        }
    }
}
