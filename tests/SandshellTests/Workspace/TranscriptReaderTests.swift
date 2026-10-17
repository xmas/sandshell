import Foundation
import Testing
@testable import Sandshell

extension Tag {
    /// Boundaries, malformed lines and odd inputs for `TranscriptReader`
    /// (fileprivate so it can't clash with tags other suites declare).
    @Tag fileprivate static var transcriptReaderEdgeCase: Self
}

/// `TranscriptReader` (Sandshell/Workspace/TranscriptReader.swift): finding a session's
/// transcript, its live working state, History summaries and messages, and the helpers
/// behind them. Every test works in its own fake home folder under the temporary directory.
struct TranscriptReaderTests {}

// MARK: - claudeEncodedDir(for:)

extension TranscriptReaderTests {
    struct ClaudeEncodedDir {
        @Test(arguments: [
            ("/Users/xmas/Code/xmas-sandshell", "-Users-xmas-Code-xmas-sandshell"),
            ("/Users/Zo\u{EB}/a.b c", "-Users-Zo--a-b-c"),
            ("/tmp/my_project~v2", "-tmp-my-project-v2"),
            ("abcXYZ0189", "abcXYZ0189"),
            ("", ""),
        ])
        func everythingButASCIILettersAndDigitsBecomesADash(workdir: String, expected: String) {
            #expect(TranscriptReader.claudeEncodedDir(for: workdir) == expected)
        }

        @Test(.tags(.transcriptReaderEdgeCase), arguments: ["/", ":", "@", "[", "`", "{", "\u{7F}", "-", ".", " "])
        func asciiNeighboursOfTheKeptRangesBecomeDashes(character: String) {
            #expect(TranscriptReader.claudeEncodedDir(for: character) == "-")
        }

        @Test(arguments: ["0", "9", "A", "Z", "a", "z"])
        func edgesOfTheKeptRangesAreKept(character: String) {
            #expect(TranscriptReader.claudeEncodedDir(for: character) == character)
        }

        @Test(.tags(.transcriptReaderEdgeCase), arguments: [
            ("Zo\u{EB}", "Zo-"),            // precomposed ë: one UTF-16 unit
            ("Zoe\u{308}", "Zoe-"),         // e + combining diaeresis: two units
            ("a\u{1F600}b", "a--b"),        // an emoji is a surrogate pair: two units
        ])
        func nonASCIIBecomesOneDashPerUTF16Unit(workdir: String, expected: String) {
            #expect(TranscriptReader.claudeEncodedDir(for: workdir) == expected,
                    "Like JavaScript's replace(/[^a-zA-Z0-9]/g, \"-\") over UTF-16 code units")
        }

        @Test func keepsTheLengthInUTF16Units() {
            let workdir = "/Users/Zo\u{EB}/Projects/\u{65E5}\u{672C}/\u{1F600} app"
            #expect(TranscriptReader.claudeEncodedDir(for: workdir).utf16.count == workdir.utf16.count)
        }

        @Test(.tags(.transcriptReaderEdgeCase))
        func longPathsAreNotTruncated() {
            let workdir = "/" + String(repeating: "a", count: 299)
            #expect(TranscriptReader.claudeEncodedDir(for: workdir) == "-" + String(repeating: "a", count: 299),
                    "Claude Code's truncation and hash past 200 characters isn't mirrored")
        }
    }
}

// MARK: - SearchText

extension TranscriptReaderTests {
    struct SearchTextBuffer {
        private let headLimit = TranscriptReader.SearchText.headLimit
        private let tailLimit = TranscriptReader.SearchText.tailLimit

        @Test func limitsAreFortyThousandAndOneHundredSixtyThousandCharacters() {
            #expect(headLimit == 40_000)
            #expect(tailLimit == 160_000)
        }

        @Test func startsEmpty() {
            #expect(TranscriptReader.SearchText().joined == "")
        }

        @Test func shortTextsAreKeptOnePerLine() {
            var text = TranscriptReader.SearchText()
            text.append("Fix the login bug")
            text.append("Done.")
            #expect(text.joined == "Fix the login bug\nDone.\n")
        }

        @Test(.tags(.transcriptReaderEdgeCase))
        func textThatExactlyFillsTheHeadStaysInTheHead() {
            let opening = String(repeating: "a", count: headLimit)
            var text = TranscriptReader.SearchText()
            text.append(opening)
            #expect(text.joined == opening + "\n", "No ellipsis while everything fits in the head")
        }

        @Test(.tags(.transcriptReaderEdgeCase))
        func textOneCharacterOverTheHeadGoesToTheTail() {
            let big = String(repeating: "a", count: headLimit + 1)
            var text = TranscriptReader.SearchText()
            text.append(big)
            #expect(text.joined == "\u{2026}\n" + big + "\n")
        }

        @Test(.tags(.transcriptReaderEdgeCase), arguments: [(39_994, false), (39_995, true)])
        func theHeadsLineBreaksCountTowardsItsLimit(length: Int, overflows: Bool) {
            var text = TranscriptReader.SearchText()
            text.append("first")    // the head now holds "first\n": 6 characters
            text.append(String(repeating: "b", count: length))
            #expect(text.joined.contains("\u{2026}") == overflows,
                    "The ellipsis marks where the head stopped and the tail began")
        }

        @Test func onceTheHeadOverflowsLaterTextsGoToTheTail() {
            let overflow = String(repeating: "b", count: headLimit)
            var text = TranscriptReader.SearchText()
            text.append("first")
            text.append(overflow)   // "first\n" plus this is over the head's limit
            text.append("last")     // would fit in the head, but the head is closed now
            #expect(text.joined == "first\n\u{2026}\n" + overflow + "\nlast\n")
        }

        @Test func theTailKeepsOnlyTheLatestStretch() {
            let opening = String(repeating: "h", count: headLimit + 1)
            let x = String(repeating: "x", count: 60_000)
            let y = String(repeating: "y", count: 60_000)
            let z = String(repeating: "z", count: 60_000)
            var text = TranscriptReader.SearchText()
            for part in [opening, x, y, z] { text.append(part) }
            #expect(text.joined == "\u{2026}\n" + y + "\n" + z + "\n",
                    "The oldest tail texts are dropped once the tail passes its limit")
        }

        @Test(.tags(.transcriptReaderEdgeCase), arguments: [(0, true), (1, false)])
        func theTailIsTrimmedOnlyPastItsLimit(extra: Int, keepsOldest: Bool) {
            let opening = String(repeating: "h", count: headLimit + 1)   // 40_002 tail characters with its line break
            let rest = String(repeating: "t", count: tailLimit - (headLimit + 2) - 1 + extra)
            var text = TranscriptReader.SearchText()
            text.append(opening)
            text.append(rest)
            let expected = keepsOldest
                ? "\u{2026}\n" + opening + "\n" + rest + "\n"
                : "\u{2026}\n" + rest + "\n"
            #expect(text.joined == expected)
        }

        @Test(.tags(.transcriptReaderEdgeCase))
        func aSingleTextLongerThanTheTailIsKeptWhole() {
            let huge = String(repeating: "q", count: tailLimit + 50_000)
            var text = TranscriptReader.SearchText()
            text.append("intro")
            text.append(huge)
            #expect(text.joined == "intro\n\u{2026}\n" + huge + "\n", "The newest text is never dropped, however long")
        }

        @Test(.tags(.transcriptReaderEdgeCase))
        func aHugeTextPushesOutEveryOlderTailText() {
            let opening = String(repeating: "h", count: headLimit + 1)
            let huge = String(repeating: "q", count: tailLimit + 1)
            var text = TranscriptReader.SearchText()
            text.append(opening)
            text.append(huge)
            #expect(text.joined == "\u{2026}\n" + huge + "\n")
        }

        @Test(.tags(.transcriptReaderEdgeCase))
        func limitsCountCharactersNotBytes() {
            let accented = String(repeating: "\u{E9}", count: headLimit)   // 80_000 bytes of UTF-8
            var text = TranscriptReader.SearchText()
            text.append(accented)
            #expect(text.joined == accented + "\n")
        }
    }
}

// MARK: - transcriptURL(agent:workdir:home:since:excluding:) — Claude

extension TranscriptReaderTests {
    struct ClaudeNewSessionLookup {
        private let home: TranscriptReaderHome

        init() throws {
            home = try TranscriptReaderHome()
        }

        private func find(excluding claimed: Set<URL> = []) -> URL? {
            TranscriptReader.transcriptURL(agent: .claude, workdir: TRFixture.workdir, home: home.root,
                                           since: TRFixture.epoch, excluding: claimed)
        }

        @Test func findsTheNewestTranscriptInTheProjectFolder() throws {
            try home.writeClaudeTranscript(id: "older", modified: TRFixture.epoch + 10)
            let newest = try home.writeClaudeTranscript(id: "newest", modified: TRFixture.epoch + 30)
            try home.writeClaudeTranscript(id: "middle", modified: TRFixture.epoch + 20)
            #expect(canonicalPath(find()) == canonicalPath(newest))
        }

        @Test(arguments: [(-3_600, false), (-6, false), (-5, true), (-4, true), (0, true), (3_600, true)]
              as [(TimeInterval, Bool)])
        func countsTranscriptsWrittenSinceTheLaunchWithFiveSecondsSlack(offset: TimeInterval, found: Bool) throws {
            let url = try home.writeClaudeTranscript(id: "session", modified: TRFixture.epoch + offset)
            #expect(canonicalPath(find()) == (found ? canonicalPath(url) : nil),
                    "Transcripts modified up to five seconds before the launch still count")
        }

        @Test func claimedTranscriptsAreSkipped() throws {
            let older = try home.writeClaudeTranscript(id: "older", modified: TRFixture.epoch + 10)
            try home.writeClaudeTranscript(id: "newer", modified: TRFixture.epoch + 20)
            let claimed = try #require(find(), "The newest transcript is found first")
            #expect(canonicalPath(find(excluding: [claimed])) == canonicalPath(older),
                    "Another session already owns the newest one")
        }

        @Test func everyTranscriptClaimedGivesNil() throws {
            try home.writeClaudeTranscript(id: "only", modified: TRFixture.epoch)
            let claimed = try #require(find())
            #expect(find(excluding: [claimed]) == nil)
        }

        @Test func filesOtherThanTopLevelJSONLAreIgnored() throws {
            let transcript = try home.writeClaudeTranscript(id: "session", modified: TRFixture.epoch)
            let folder = ".claude/projects/\(TRFixture.encodedWorkdir)"
            let later = TRFixture.epoch + 60
            try home.write("\(folder)/notes.txt", contents: "x", modified: later)
            try home.write("\(folder)/session.json", contents: "{}", modified: later)
            try home.write("\(folder)/backup.jsonl.bak", contents: TRFixture.claudeUser(), modified: later)
            try home.write("\(folder)/session/subagents/agent-a1.jsonl", contents: TRFixture.claudeUser(), modified: later)
            #expect(canonicalPath(find()) == canonicalPath(transcript))
        }

        @Test func transcriptsOfAnotherFolderAreIgnored() throws {
            try home.writeClaudeTranscript(id: "elsewhere", folder: TRFixture.encodedOtherWorkdir, modified: TRFixture.epoch)
            #expect(find() == nil)
        }

        @Test func missingProjectFolderGivesNil() {
            #expect(find() == nil)
        }

        @Test(arguments: ["gemini", "shell", "copilot", "my-kit-agent"])
        func agentsWithoutAKnownTranscriptFormatGiveNil(agent: String) throws {
            try home.writeClaudeTranscript(id: "session", modified: TRFixture.epoch)
            try home.writeCodexRollout("rollout-1", lines: [TRFixture.codexMeta()], modified: TRFixture.epoch)
            let url = TranscriptReader.transcriptURL(agent: AgentKind(rawValue: agent), workdir: TRFixture.workdir,
                                                     home: home.root, since: TRFixture.epoch, excluding: [])
            #expect(url == nil)
        }
    }
}

// MARK: - transcriptURL(agent:workdir:home:since:excluding:) — Codex

extension TranscriptReaderTests {
    struct CodexNewSessionLookup {
        private let home: TranscriptReaderHome

        init() throws {
            home = try TranscriptReaderHome()
        }

        private func find(workdir: String = TRFixture.workdir, excluding claimed: Set<URL> = []) -> URL? {
            TranscriptReader.transcriptURL(agent: .codex, workdir: workdir, home: home.root,
                                           since: TRFixture.epoch, excluding: claimed)
        }

        @Test func findsTheNewestRolloutForTheFolder() throws {
            try home.writeCodexRollout("rollout-a", day: "2026/01/01", lines: [TRFixture.codexMeta(id: "a")],
                                       modified: TRFixture.epoch + 10)
            let newest = try home.writeCodexRollout("rollout-b", day: "2026/01/02", lines: [TRFixture.codexMeta(id: "b")],
                                                    modified: TRFixture.epoch + 20)
            try home.writeCodexRollout("rollout-c", day: "2026/01/03",
                                       lines: [TRFixture.codexMeta(id: "c", cwd: TRFixture.otherWorkdir)],
                                       modified: TRFixture.epoch + 30)
            #expect(canonicalPath(find()) == canonicalPath(newest), "A newer rollout for another folder doesn't count")
        }

        @Test(arguments: [(-6, false), (-5, true), (0, true)] as [(TimeInterval, Bool)])
        func countsRolloutsWrittenSinceTheLaunchWithFiveSecondsSlack(offset: TimeInterval, found: Bool) throws {
            let url = try home.writeCodexRollout("rollout-1", lines: [TRFixture.codexMeta()],
                                                 modified: TRFixture.epoch + offset)
            #expect(canonicalPath(find()) == (found ? canonicalPath(url) : nil),
                    "Rollouts modified up to five seconds before the launch still count")
        }

        @Test func claimedRolloutsAreSkipped() throws {
            let older = try home.writeCodexRollout("rollout-a", lines: [TRFixture.codexMeta(id: "a")],
                                                   modified: TRFixture.epoch + 10)
            try home.writeCodexRollout("rollout-b", lines: [TRFixture.codexMeta(id: "b")], modified: TRFixture.epoch + 20)
            let claimed = try #require(find(), "The newest rollout is found first")
            #expect(canonicalPath(find(excluding: [claimed])) == canonicalPath(older))
        }

        @Test func rolloutWithoutSessionMetaIsIgnored() throws {
            try home.writeCodexRollout("rollout-1", lines: [TRFixture.codexMessage("user", "Add a test")],
                                       modified: TRFixture.epoch)
            #expect(find() == nil, "Without session_meta there's no folder to match")
        }

        @Test(.tags(.transcriptReaderEdgeCase))
        func theFolderMustMatchExactly() throws {
            try home.writeCodexRollout("rollout-1", lines: [TRFixture.codexMeta(cwd: TRFixture.workdir + "/")],
                                       modified: TRFixture.epoch)
            #expect(find() == nil)
        }

        @Test func missingSessionsFolderGivesNil() {
            #expect(find() == nil)
        }
    }
}

// MARK: - transcriptURL(agent:workdir:home:id:)

extension TranscriptReaderTests {
    struct KnownTranscriptLookup {
        private let home: TranscriptReaderHome

        init() throws {
            home = try TranscriptReaderHome()
        }

        @Test func claudeTranscriptIsFoundByID() throws {
            let url = try home.writeClaudeTranscript(id: "7f3c2a10-session")
            let found = TranscriptReader.transcriptURL(agent: .claude, workdir: TRFixture.workdir, home: home.root,
                                                       id: "7f3c2a10-session")
            #expect(canonicalPath(found) == canonicalPath(url))
        }

        @Test func claudeTranscriptOfAnotherFolderIsNotFound() throws {
            try home.writeClaudeTranscript(id: "session", folder: TRFixture.encodedOtherWorkdir)
            #expect(TranscriptReader.transcriptURL(agent: .claude, workdir: TRFixture.workdir, home: home.root,
                                                   id: "session") == nil)
        }

        @Test func missingClaudeTranscriptGivesNil() throws {
            try home.writeClaudeTranscript(id: "session")
            #expect(TranscriptReader.transcriptURL(agent: .claude, workdir: TRFixture.workdir, home: home.root,
                                                   id: "another") == nil)
        }

        @Test func codexRolloutIsFoundBySessionIDWhateverTheFolder() throws {
            let url = try home.writeCodexRollout("rollout-1", lines: [TRFixture.codexMeta(id: "thread-7")])
            let found = TranscriptReader.transcriptURL(agent: .codex, workdir: "/somewhere/else", home: home.root,
                                                       id: "thread-7")
            #expect(canonicalPath(found) == canonicalPath(url), "Codex lookups by id don't look at the folder")
        }

        @Test func newestCodexRolloutWithTheIDWins() throws {
            try home.writeCodexRollout("rollout-a", lines: [TRFixture.codexMeta(id: "thread-7")],
                                       modified: TRFixture.epoch + 10)
            let newest = try home.writeCodexRollout("rollout-b", lines: [TRFixture.codexMeta(id: "thread-7")],
                                                    modified: TRFixture.epoch + 20)
            let found = TranscriptReader.transcriptURL(agent: .codex, workdir: TRFixture.workdir, home: home.root,
                                                       id: "thread-7")
            #expect(canonicalPath(found) == canonicalPath(newest))
        }

        @Test func codexRolloutIsMatchedByContentNotFileName() throws {
            try home.writeCodexRollout("rollout-thread-7", lines: [TRFixture.codexMeta(id: "thread-8")])
            #expect(TranscriptReader.transcriptURL(agent: .codex, workdir: TRFixture.workdir, home: home.root,
                                                   id: "thread-7") == nil)
        }

        @Test(arguments: ["gemini", "shell", "my-kit-agent"])
        func otherAgentsGiveNil(agent: String) throws {
            try home.writeClaudeTranscript(id: "shared-id")
            try home.writeCodexRollout("rollout-1", lines: [TRFixture.codexMeta(id: "shared-id")])
            #expect(TranscriptReader.transcriptURL(agent: AgentKind(rawValue: agent), workdir: TRFixture.workdir,
                                                   home: home.root, id: "shared-id") == nil)
        }
    }
}

// MARK: - transcriptExists(agent:workdir:home:id:)

extension TranscriptReaderTests {
    struct TranscriptExists {
        private let home: TranscriptReaderHome

        init() throws {
            home = try TranscriptReaderHome()
        }

        @Test(arguments: [("session", true), ("another", false)])
        func claudeTranscriptExistsForItsFolder(id: String, expected: Bool) throws {
            try home.writeClaudeTranscript(id: "session")
            #expect(TranscriptReader.transcriptExists(agent: .claude, workdir: TRFixture.workdir,
                                                      home: home.root, id: id) == expected)
        }

        @Test func claudeTranscriptOfAnotherFolderDoesNotCount() throws {
            try home.writeClaudeTranscript(id: "session", folder: TRFixture.encodedOtherWorkdir)
            #expect(TranscriptReader.transcriptExists(agent: .claude, workdir: TRFixture.workdir,
                                                      home: home.root, id: "session") == false)
        }

        @Test(arguments: [("thread-7", true), ("thread-8", false), ("rollout-1", false)])
        func codexRolloutExistsBySessionID(id: String, expected: Bool) throws {
            try home.writeCodexRollout("rollout-1", lines: [TRFixture.codexMeta(id: "thread-7")])
            #expect(TranscriptReader.transcriptExists(agent: .codex, workdir: TRFixture.workdir,
                                                      home: home.root, id: id) == expected)
        }

        @Test func nothingExistsInAnEmptyHome() {
            #expect(TranscriptReader.transcriptExists(agent: .claude, workdir: TRFixture.workdir,
                                                      home: home.root, id: "session") == false)
            #expect(TranscriptReader.transcriptExists(agent: .codex, workdir: TRFixture.workdir,
                                                      home: home.root, id: "thread-7") == false)
        }

        @Test(arguments: ["gemini", "shell", "copilot", "my-kit-agent"])
        func otherAgentsNeverHaveOne(agent: String) throws {
            try home.writeClaudeTranscript(id: "shared-id")
            try home.writeCodexRollout("rollout-1", lines: [TRFixture.codexMeta(id: "shared-id")])
            #expect(TranscriptReader.transcriptExists(agent: AgentKind(rawValue: agent), workdir: TRFixture.workdir,
                                                      home: home.root, id: "shared-id") == false)
        }
    }
}

// MARK: - transcriptID(at:agent:)

extension TranscriptReaderTests {
    struct TranscriptIDs {
        private let home: TranscriptReaderHome

        init() throws {
            home = try TranscriptReaderHome()
        }

        @Test(arguments: ["claude", "gemini", "shell", "my-kit-agent"])
        func isTheFileNameForAgentsOtherThanCodex(agent: String) {
            let url = URL(filePath: "/nonexistent/projects/-Users-test/3f2a9c1e-session.jsonl")
            #expect(TranscriptReader.transcriptID(at: url, agent: AgentKind(rawValue: agent)) == "3f2a9c1e-session",
                    "No file access needed: the id is the file name")
        }

        @Test(.tags(.transcriptReaderEdgeCase))
        func onlyTheLastExtensionIsDropped() {
            let url = URL(filePath: "/nonexistent/a.b.jsonl")
            #expect(TranscriptReader.transcriptID(at: url, agent: .claude) == "a.b")
        }

        @Test func codexIDComesFromSessionMetaNotTheFileName() throws {
            let url = try home.writeCodexRollout("rollout-2026-01-02T10-00-00-abc", lines: [
                TRFixture.codexMeta(id: "019a-thread"), TRFixture.codexMessage("user", "Add a test"),
            ])
            #expect(TranscriptReader.transcriptID(at: url, agent: .codex) == "019a-thread")
        }

        @Test func firstCodexSessionMetaWins() throws {
            let url = try home.writeCodexRollout("rollout-1", lines: [
                TRFixture.codexMeta(id: "first"), TRFixture.codexMeta(id: "second"),
            ])
            #expect(TranscriptReader.transcriptID(at: url, agent: .codex) == "first")
        }

        @Test func codexRolloutWithoutSessionMetaHasNoID() throws {
            let url = try home.writeCodexRollout("rollout-1", lines: [TRFixture.codexMessage("user", "Add a test")])
            #expect(TranscriptReader.transcriptID(at: url, agent: .codex) == nil)
        }

        @Test func missingCodexRolloutHasNoID() {
            let url = home.root.appendingPathComponent(".codex/sessions/rollout-missing.jsonl")
            #expect(TranscriptReader.transcriptID(at: url, agent: .codex) == nil)
        }
    }
}

// MARK: - startedAsChat(at:agent:)

extension TranscriptReaderTests {
    struct StartedAsChat {
        private let home: TranscriptReaderHome

        init() throws {
            home = try TranscriptReaderHome()
        }

        private func file(_ lines: [String]) throws -> URL {
            try home.write("transcripts/chat.jsonl", contents: TRFixture.jsonl(lines))
        }

        @Test(arguments: [("cli", false), ("sdk-ts", true), ("sdk-py", true), ("claude-desktop", true)])
        func claudeEntrypointOtherThanCLIMeansChat(entrypoint: String, expected: Bool) throws {
            let url = try file([TRFixture.claudeUser(extra: ["entrypoint": entrypoint])])
            #expect(TranscriptReader.startedAsChat(at: url, agent: .claude) == expected)
        }

        @Test func linesWithoutAnEntrypointAreSkipped() throws {
            let url = try file([
                TRFixture.summaryLine,
                "not json",
                "[1, 2]",
                TRFixture.claudeUser(extra: ["entrypoint": "sdk-ts"]),
            ])
            #expect(TranscriptReader.startedAsChat(at: url, agent: .claude))
        }

        @Test func theFirstEntrypointDecides() throws {
            let url = try file([
                TRFixture.claudeUser(extra: ["entrypoint": "cli"]),
                TRFixture.claudeUser(extra: ["entrypoint": "sdk-ts"]),
            ])
            #expect(TranscriptReader.startedAsChat(at: url, agent: .claude) == false)
        }

        @Test(.tags(.transcriptReaderEdgeCase))
        func nonStringEntrypointIsSkipped() throws {
            let url = try file([
                TRFixture.claudeUser(extra: ["entrypoint": 1]),
                TRFixture.claudeUser(extra: ["entrypoint": "sdk-ts"]),
            ])
            #expect(TranscriptReader.startedAsChat(at: url, agent: .claude))
        }

        @Test func noEntrypointMeansNotAChat() throws {
            let url = try file([TRFixture.claudeUser(), TRFixture.claudeAssistant()])
            #expect(TranscriptReader.startedAsChat(at: url, agent: .claude) == false)
        }

        @Test(.tags(.transcriptReaderEdgeCase))
        func emptyOrMissingFileMeansNotAChat() throws {
            let empty = try home.write("transcripts/empty.jsonl", contents: "")
            let missing = home.root.appendingPathComponent("transcripts/missing.jsonl")
            #expect(TranscriptReader.startedAsChat(at: empty, agent: .claude) == false)
            #expect(TranscriptReader.startedAsChat(at: missing, agent: .claude) == false)
        }

        @Test(arguments: [("codex-acp", true), ("Codex_ACP_Client", true), ("codex_cli_rs", false), ("codex_vscode", false)])
        func codexOriginatorMentioningACPMeansChat(originator: String, expected: Bool) throws {
            let url = try file([TRFixture.codexMeta(originator: originator), TRFixture.codexMessage("user", "Add a test")])
            #expect(TranscriptReader.startedAsChat(at: url, agent: .codex) == expected,
                    "Only an originator containing \"acp\", in any case, means an ACP client")
        }

        @Test func codexIgnoresClaudeEntrypoints() throws {
            let url = try file([
                TRFixture.claudeUser(extra: ["entrypoint": "sdk-ts"]),
                TRFixture.codexMeta(originator: "codex_cli_rs"),
            ])
            #expect(TranscriptReader.startedAsChat(at: url, agent: .codex) == false, "Only session_meta's originator counts")
        }

        @Test func codexWithoutOriginatorIsNotAChat() throws {
            let url = try file([TRFixture.codexMeta(originator: nil)])
            #expect(TranscriptReader.startedAsChat(at: url, agent: .codex) == false)
        }

        @Test func codexWithoutSessionMetaIsNotAChat() throws {
            let url = try file([TRFixture.codexMessage("user", "Add a test"), TRFixture.codexMessage("assistant", "Added.")])
            #expect(TranscriptReader.startedAsChat(at: url, agent: .codex) == false)
        }

        /// `overrun` is how far past the 256 KiB head the entrypoint line ends.
        @Test(.tags(.transcriptReaderEdgeCase), arguments: [(0, true), (1, false), (24, false)])
        func onlyTheFirst256KiBAreRead(overrun: Int, expected: Bool) throws {
            let headSize = 256 * 1024
            let entry = #"{"entrypoint":"sdk-ts"}"#
            let prefix = #"{"type":"summary","pad":""#
            let suffix = #""}"#
            let padCount = headSize + overrun - entry.utf8.count - 1 - prefix.utf8.count - suffix.utf8.count
            let padding = prefix + String(repeating: "x", count: padCount) + suffix
            let url = try home.write("transcripts/long.jsonl", contents: padding + "\n" + entry + "\n")
            #expect(TranscriptReader.startedAsChat(at: url, agent: .claude) == expected)
        }
    }
}

// MARK: - liveState(in:) — Claude

extension TranscriptReaderTests {
    struct ClaudeLiveState {
        private let home: TranscriptReaderHome

        init() throws {
            home = try TranscriptReaderHome()
        }

        private func transcript(_ lines: [String]) throws -> URL {
            try home.writeClaudeTranscript(id: "live", lines: lines)
        }

        @Test func userPromptMeansWorking() throws {
            let url = try transcript([TRFixture.claudeUser()])
            let live = try #require(TranscriptReader.liveState(in: url))
            #expect(live.working)
            #expect(live.latestPrompt == TRFixture.prompt)
        }

        @Test(arguments: ["end_turn", "stop_sequence", "max_tokens"])
        func terminalStopReasonMeansIdle(stopReason: String) throws {
            let url = try transcript([TRFixture.claudeUser(), TRFixture.claudeAssistant(stopReason: stopReason)])
            let live = try #require(TranscriptReader.liveState(in: url))
            #expect(live.working == false)
            #expect(live.latestPrompt == TRFixture.prompt, "The prompt is kept after the reply")
        }

        @Test(arguments: ["tool_use", "pause_turn", nil] as [String?])
        func otherStopReasonsMeanWorking(stopReason: String?) throws {
            let url = try transcript([TRFixture.claudeUser(), TRFixture.claudeAssistant(stopReason: stopReason)])
            let live = try #require(TranscriptReader.liveState(in: url))
            #expect(live.working, "A tool call, a paused turn or a still-streaming reply isn't the end of the turn")
        }

        @Test(.tags(.transcriptReaderEdgeCase), arguments: ["refusal", "model_context_window_exceeded"])
        func everyStopReasonThatEndsTheTurnMeansIdle(stopReason: String) throws {
            let url = try transcript([TRFixture.claudeUser(), TRFixture.claudeAssistant(stopReason: stopReason)])
            let live = try #require(TranscriptReader.liveState(in: url))
            withKnownIssue("Claude live state only treats end_turn, stop_sequence and max_tokens as terminal, so a turn the API ended with refusal or model_context_window_exceeded reads as working until the next write") {
                #expect(live.working == false)
            }
        }

        @Test func toolResultKeepsWorkingAndThePrompt() throws {
            let url = try transcript([
                TRFixture.claudeUser(),
                TRFixture.claudeAssistant([TRFixture.toolUseBlock], stopReason: "tool_use"),
                TRFixture.claudeUser(TRFixture.toolResult()),
            ])
            let live = try #require(TranscriptReader.liveState(in: url))
            #expect(live.working)
            #expect(live.latestPrompt == TRFixture.prompt, "A tool result has no text to become the prompt")
        }

        @Test func theLatestPromptWins() throws {
            let url = try transcript([
                TRFixture.claudeUser("First task"), TRFixture.claudeAssistant(),
                TRFixture.claudeUser("Second task"), TRFixture.claudeAssistant(),
            ])
            let live = try #require(TranscriptReader.liveState(in: url))
            #expect(live.working == false)
            #expect(live.latestPrompt == "Second task")
        }

        @Test(arguments: [
            "<command-name>/clear</command-name>",
            "  <system-reminder>Use the todo list.</system-reminder>",
            "<local-command-stdout>Done</local-command-stdout>",
        ])
        func injectedContextIsNotThePrompt(injected: String) throws {
            let url = try transcript([TRFixture.claudeUser(), TRFixture.claudeAssistant(), TRFixture.claudeUser(injected)])
            let live = try #require(TranscriptReader.liveState(in: url))
            #expect(live.working, "Any user line starts a turn")
            #expect(live.latestPrompt == TRFixture.prompt, "Text starting with < (once trimmed) is injected context")
        }

        @Test func promptIsOneTrimmedLine() throws {
            let url = try transcript([TRFixture.claudeUser("  Fix the\nlogin bug \n")])
            let live = try #require(TranscriptReader.liveState(in: url))
            #expect(live.latestPrompt == "Fix the login bug")
        }

        @Test func textBlocksAreJoinedAndOtherBlocksIgnored() throws {
            let url = try transcript([TRFixture.claudeUser([
                TRFixture.textBlock("Fix the"), TRFixture.imageBlock, TRFixture.textBlock("login bug"),
            ])])
            let live = try #require(TranscriptReader.liveState(in: url))
            #expect(live.latestPrompt == "Fix the login bug")
        }

        @Test(.tags(.transcriptReaderEdgeCase))
        func whitespaceOnlyPromptLeavesNoPrompt() throws {
            let url = try transcript([TRFixture.claudeUser("  \n  ")])
            let live = try #require(TranscriptReader.liveState(in: url))
            #expect(live.working)
            #expect(live.latestPrompt == nil)
        }

        @Test func sidechainLinesAreIgnored() throws {
            let sidechain: [String: Any] = ["isSidechain": true]
            let url = try transcript([
                TRFixture.claudeUser(), TRFixture.claudeAssistant(),
                TRFixture.claudeUser("Explore the repo", extra: sidechain),
                TRFixture.claudeAssistant([TRFixture.toolUseBlock], stopReason: "tool_use", extra: sidechain),
            ])
            let live = try #require(TranscriptReader.liveState(in: url))
            #expect(live.working == false, "A subagent's own turns don't decide whether this session is done")
            #expect(live.latestPrompt == TRFixture.prompt)
        }

        @Test func pendingSubagentsKeepTheSessionWorking() throws {
            let url = try transcript([TRFixture.claudeUser(), TRFixture.claudeAssistant(), TRFixture.claudeSystem(pending: 2)])
            let live = try #require(TranscriptReader.liveState(in: url))
            #expect(live.working, "The turn ended but a dispatched subagent hasn't returned")
        }

        @Test(arguments: [0, nil] as [Int?])
        func noPendingSubagentsLeavesTheTurnDone(pending: Int?) throws {
            let url = try transcript([TRFixture.claudeUser(), TRFixture.claudeAssistant(), TRFixture.claudeSystem(pending: pending)])
            let live = try #require(TranscriptReader.liveState(in: url))
            #expect(live.working == false)
        }

        @Test(.tags(.transcriptReaderEdgeCase))
        func onlyTurnDurationLinesReportPendingSubagents() throws {
            let url = try transcript([
                TRFixture.claudeUser(), TRFixture.claudeAssistant(),
                TRFixture.claudeSystem(subtype: "compact_boundary", pending: 1),
            ])
            let live = try #require(TranscriptReader.liveState(in: url))
            #expect(live.working == false)
        }

        @Test func aLaterFinishedTurnOverridesPendingSubagents() throws {
            let url = try transcript([
                TRFixture.claudeUser(), TRFixture.claudeAssistant(), TRFixture.claudeSystem(pending: 1),
                TRFixture.claudeUser("<task-notification>done</task-notification>"), TRFixture.claudeAssistant(),
            ])
            let live = try #require(TranscriptReader.liveState(in: url))
            #expect(live.working == false, "The last status-bearing line wins")
        }

        @Test(.tags(.transcriptReaderEdgeCase))
        func malformedLinesAreSkipped() throws {
            let url = try transcript(["not json", "[1, 2]", "{\"type\":\"user\"", TRFixture.claudeUser()])
            let live = try #require(TranscriptReader.liveState(in: url))
            #expect(live.working)
            #expect(live.latestPrompt == TRFixture.prompt)
        }

        @Test func transcriptWithoutStatusLinesGivesNil() throws {
            let url = try transcript([
                TRFixture.summaryLine,
                TRFixture.json(["type": "file-history-snapshot", "messageId": "m1"]),
                TRFixture.claudeSystem(),
                "not json",
            ])
            #expect(TranscriptReader.liveState(in: url) == nil)
        }

        @Test(.tags(.transcriptReaderEdgeCase))
        func emptyOrMissingTranscriptGivesNil() throws {
            let empty = try transcript([])
            let missing = home.root.appendingPathComponent(".claude/projects/missing.jsonl")
            #expect(TranscriptReader.liveState(in: empty) == nil)
            #expect(TranscriptReader.liveState(in: missing) == nil)
        }
    }
}

// MARK: - liveState(in:) — Codex

extension TranscriptReaderTests {
    struct CodexLiveState {
        private let home: TranscriptReaderHome

        init() throws {
            home = try TranscriptReaderHome()
        }

        @Test func trailingUserMessageMeansWorking() throws {
            let url = try home.writeCodexRollout("rollout-1", lines: [TRFixture.codexMeta(), TRFixture.codexMessage("user", "Add a test")])
            let live = try #require(TranscriptReader.liveState(in: url))
            #expect(live.working)
            #expect(live.latestPrompt == "Add a test")
        }

        @Test func trailingAssistantMessageMeansIdle() throws {
            let url = try home.writeCodexRollout("rollout-1", lines: [
                TRFixture.codexMeta(), TRFixture.codexMessage("user", "Add a test"), TRFixture.codexMessage("assistant", "Added."),
            ])
            let live = try #require(TranscriptReader.liveState(in: url))
            #expect(live.working == false, "Even though the file was just written")
            #expect(live.latestPrompt == "Add a test")
        }

        @Test func aQuietRolloutWithATrailingUserMessageStillWorks() throws {
            let url = try home.writeCodexRollout("rollout-1", lines: [TRFixture.codexMeta(), TRFixture.codexMessage("user", "Add a test")],
                                                 modified: TRFixture.epoch)
            let live = try #require(TranscriptReader.liveState(in: url))
            #expect(live.working, "A trailing user message is in flight however old the file is")
        }

        @Test func theLatestUserMessageIsThePrompt() throws {
            let url = try home.writeCodexRollout("rollout-1", lines: [
                TRFixture.codexMeta(), TRFixture.codexMessage("user", "Add a test"),
                TRFixture.codexMessage("assistant", "Added."), TRFixture.codexMessage("user", "Now the docs\nplease"),
            ])
            let live = try #require(TranscriptReader.liveState(in: url))
            #expect(live.working)
            #expect(live.latestPrompt == "Now the docs please")
        }

        @Test func injectedContextAndToolItemsAreNotMessages() throws {
            let url = try home.writeCodexRollout("rollout-1", lines: [
                TRFixture.codexMeta(),
                TRFixture.codexMessage("developer", "You are Codex."),
                TRFixture.codexMessage("user", TRFixture.codexEnvironmentContext),
                TRFixture.codexMessage("user", "Add a test"),
            ] + TRFixture.codexToolLines)
            let live = try #require(TranscriptReader.liveState(in: url))
            #expect(live.working, "Tool calls after the prompt don't change the last role")
            #expect(live.latestPrompt == "Add a test")
        }

        @Test(arguments: [false, true])
        func rolloutWithoutConversationGivesNil(withInjectedContext: Bool) throws {
            let lines = [TRFixture.codexMeta()]
                + (withInjectedContext ? [TRFixture.codexMessage("user", TRFixture.codexEnvironmentContext)] : [])
            let url = try home.writeCodexRollout("rollout-1", lines: lines)
            #expect(TranscriptReader.liveState(in: url) == nil)
        }

        @Test func missingRolloutGivesNil() {
            let url = home.root.appendingPathComponent(".codex/sessions/rollout-missing.jsonl")
            #expect(TranscriptReader.liveState(in: url) == nil)
        }

        @Test(.tags(.transcriptReaderEdgeCase))
        func rolloutOutsideACodexFolderIsReadAsClaude() throws {
            let url = try home.write("elsewhere/rollout-1.jsonl", contents: TRFixture.jsonl([
                TRFixture.codexMeta(), TRFixture.codexMessage("user", "Add a test"),
            ]))
            #expect(TranscriptReader.liveState(in: url) == nil, "Codex lines carry nothing Claude's reader knows")
        }

        @Test(.tags(.transcriptReaderEdgeCase))
        func claudeTranscriptInsideACodexFolderIsReadAsCodex() throws {
            let url = try home.writeCodexRollout("claude-shaped", lines: [TRFixture.claudeUser()])
            #expect(TranscriptReader.liveState(in: url) == nil)
        }
    }
}

// MARK: - liveStateMayChangeWithoutFileWrite(agent:)

extension TranscriptReaderTests {
    struct TimeBasedLiveState {
        @Test(arguments: [("codex", true), ("claude", false), ("gemini", false), ("shell", false), ("my-kit-agent", false)])
        func onlyCodexHasTimeBasedState(agent: String, expected: Bool) {
            #expect(TranscriptReader.liveStateMayChangeWithoutFileWrite(agent: AgentKind(rawValue: agent)) == expected)
        }
    }
}

// MARK: - incrementalLiveState(in:fromOffset:) — Claude

extension TranscriptReaderTests {
    struct ClaudeIncrementalLiveState {
        private let home: TranscriptReaderHome
        private let firstTurn = [TRFixture.claudeUser("First task"), TRFixture.claudeAssistant()]

        init() throws {
            home = try TranscriptReaderHome()
        }

        @Test func readingFromTheStartCoversTheWholeFile() throws {
            let url = try home.writeClaudeTranscript(id: "s", lines: firstTurn)
            let result = try #require(TranscriptReader.incrementalLiveState(in: url, fromOffset: 0))
            #expect(result.liveState.working == false)
            #expect(result.liveState.latestPrompt == "First task")
            #expect(result.newOffset == TRFixture.jsonl(firstTurn).utf8.count, "The next read starts at the end of the file")
            #expect(result.lastRole == nil, "Only Codex reports a role")
        }

        @Test func onlyAppendedLinesAreRead() throws {
            let url = try home.writeClaudeTranscript(id: "s", lines: firstTurn)
            let offset = TRFixture.jsonl(firstTurn).utf8.count
            let appended = TRFixture.jsonl([TRFixture.claudeUser("Second task")])
            try home.append(appended, to: url)
            let result = try #require(TranscriptReader.incrementalLiveState(in: url, fromOffset: offset))
            #expect(result.liveState.working)
            #expect(result.liveState.latestPrompt == "Second task")
            #expect(result.newOffset == offset + appended.utf8.count)
        }

        @Test func appendedReplyAloneHasNoPrompt() throws {
            let url = try home.writeClaudeTranscript(id: "s", lines: [TRFixture.claudeUser("First task")])
            let offset = TRFixture.jsonl([TRFixture.claudeUser("First task")]).utf8.count
            try home.append(TRFixture.jsonl([TRFixture.claudeAssistant()]), to: url)
            let result = try #require(TranscriptReader.incrementalLiveState(in: url, fromOffset: offset))
            #expect(result.liveState.working == false)
            #expect(result.liveState.latestPrompt == nil, "The prompt before the offset isn't read again")
        }

        @Test func pendingSubagentLineAloneMeansWorking() throws {
            let url = try home.writeClaudeTranscript(id: "s", lines: firstTurn)
            let offset = TRFixture.jsonl(firstTurn).utf8.count
            try home.append(TRFixture.jsonl([TRFixture.claudeSystem(pending: 1)]), to: url)
            let result = try #require(TranscriptReader.incrementalLiveState(in: url, fromOffset: offset))
            #expect(result.liveState.working)
            #expect(result.liveState.latestPrompt == nil)
        }

        @Test func appendedLinesWithoutStatusGiveNil() throws {
            let url = try home.writeClaudeTranscript(id: "s", lines: firstTurn)
            let offset = TRFixture.jsonl(firstTurn).utf8.count
            try home.append(TRFixture.jsonl([
                TRFixture.summaryLine,
                TRFixture.claudeUser("Explore the repo", extra: ["isSidechain": true]),
                TRFixture.claudeSystem(),
            ]), to: url)
            #expect(TranscriptReader.incrementalLiveState(in: url, fromOffset: offset) == nil)
        }

        @Test(.tags(.transcriptReaderEdgeCase), arguments: [0, 1, 4_096])
        func noNewBytesGivesNil(pastTheEnd: Int) throws {
            let url = try home.writeClaudeTranscript(id: "s", lines: firstTurn)
            let size = TRFixture.jsonl(firstTurn).utf8.count
            #expect(TranscriptReader.incrementalLiveState(in: url, fromOffset: size + pastTheEnd) == nil)
        }

        @Test(.tags(.transcriptReaderEdgeCase), arguments: [-1, -4_096, Int.min])
        func negativeOffsetsReadFromTheStart(offset: Int) throws {
            let url = try home.writeClaudeTranscript(id: "s", lines: firstTurn)
            let result = try #require(TranscriptReader.incrementalLiveState(in: url, fromOffset: offset))
            #expect(result.liveState.latestPrompt == "First task")
            #expect(result.newOffset == TRFixture.jsonl(firstTurn).utf8.count)
        }

        @Test(.tags(.transcriptReaderEdgeCase))
        func emptyOrMissingTranscriptGivesNil() throws {
            let empty = try home.writeClaudeTranscript(id: "empty", lines: [])
            let missing = home.root.appendingPathComponent(".claude/projects/missing.jsonl")
            #expect(TranscriptReader.incrementalLiveState(in: empty, fromOffset: 0) == nil)
            #expect(TranscriptReader.incrementalLiveState(in: missing, fromOffset: 0) == nil)
        }

        @Test(.tags(.transcriptReaderEdgeCase))
        func readEndingInsideACharacterWaitsForTheRest() throws {
            let bytes = Data((#"{"type":"user","message":{"role":"user","content":"Caf\#u{E9} au lait"}}"# + "\n").utf8)
            let cut = try #require(bytes.firstIndex(of: 0xC3), "\u{E9} starts with 0xC3 in UTF-8")
            let url = try home.write(".claude/projects/\(TRFixture.encodedWorkdir)/s.jsonl", data: bytes.prefix(through: cut))
            #expect(TranscriptReader.incrementalLiveState(in: url, fromOffset: 0) == nil,
                    "Not valid UTF-8 yet, so the caller keeps its offset")
            try home.append(bytes.suffix(from: cut + 1), to: url)
            let result = try #require(TranscriptReader.incrementalLiveState(in: url, fromOffset: 0))
            #expect(result.liveState.latestPrompt == "Caf\u{E9} au lait")
        }

        @Test(.tags(.transcriptReaderEdgeCase))
        func lineSplitAcrossTwoReadsIsStillParsed() throws {
            let reply = TRFixture.claudeAssistant()
            let half = reply.index(reply.startIndex, offsetBy: reply.count / 2)
            let url = try home.writeClaudeTranscript(id: "s", lines: [TRFixture.claudeUser("First task")])
            try home.append(String(reply[..<half]), to: url)
            let first = try #require(TranscriptReader.incrementalLiveState(in: url, fromOffset: 0))
            #expect(first.liveState.working, "Only the user's line is complete so far")
            try home.append(String(reply[half...]) + "\n", to: url)
            withKnownIssue("incrementalLiveState sets newOffset to the end of the file even when the last line is still half-written, so the rest of that line is unparseable on the next read and its status (here end_turn) is lost") {
                let second = try #require(TranscriptReader.incrementalLiveState(in: url, fromOffset: first.newOffset))
                #expect(second.liveState.working == false)
            }
        }
    }
}

// MARK: - incrementalLiveState(in:fromOffset:) — Codex

extension TranscriptReaderTests {
    struct CodexIncrementalLiveState {
        private let home: TranscriptReaderHome
        private let firstTurn = [
            TRFixture.codexMeta(), TRFixture.codexMessage("user", "Add a test"), TRFixture.codexMessage("assistant", "Added."),
        ]

        init() throws {
            home = try TranscriptReaderHome()
        }

        @Test func readingFromTheStartReportsTheLastRole() throws {
            let url = try home.writeCodexRollout("rollout-1", lines: firstTurn)
            let result = try #require(TranscriptReader.incrementalLiveState(in: url, fromOffset: 0))
            #expect(result.lastRole == "assistant")
            #expect(result.liveState.working == false)
            #expect(result.liveState.latestPrompt == "Add a test")
            #expect(result.newOffset == TRFixture.jsonl(firstTurn).utf8.count)
        }

        @Test func appendedUserMessageMeansWorking() throws {
            let url = try home.writeCodexRollout("rollout-1", lines: firstTurn)
            let offset = TRFixture.jsonl(firstTurn).utf8.count
            let appended = TRFixture.jsonl([TRFixture.codexMessage("user", "Now the docs")])
            try home.append(appended, to: url)
            let result = try #require(TranscriptReader.incrementalLiveState(in: url, fromOffset: offset))
            #expect(result.lastRole == "user")
            #expect(result.liveState.working)
            #expect(result.liveState.latestPrompt == "Now the docs")
            #expect(result.newOffset == offset + appended.utf8.count)
        }

        @Test func appendedAssistantMessageHasNoPrompt() throws {
            let lines = [TRFixture.codexMeta(), TRFixture.codexMessage("user", "Add a test")]
            let url = try home.writeCodexRollout("rollout-1", lines: lines)
            try home.append(TRFixture.jsonl([TRFixture.codexMessage("assistant", "Added.")]), to: url)
            let result = try #require(TranscriptReader.incrementalLiveState(in: url, fromOffset: TRFixture.jsonl(lines).utf8.count))
            #expect(result.lastRole == "assistant")
            #expect(result.liveState.working == false)
            #expect(result.liveState.latestPrompt == nil)
        }

        @Test func appendedLinesWithoutMessagesGiveNil() throws {
            let url = try home.writeCodexRollout("rollout-1", lines: firstTurn)
            let offset = TRFixture.jsonl(firstTurn).utf8.count
            try home.append(TRFixture.jsonl(TRFixture.codexToolLines + [
                TRFixture.codexEvent("Now the docs"),
                TRFixture.codexMessage("user", TRFixture.codexEnvironmentContext),
                TRFixture.codexMeta(),
            ]), to: url)
            #expect(TranscriptReader.incrementalLiveState(in: url, fromOffset: offset) == nil)
        }

        @Test(.tags(.transcriptReaderEdgeCase), arguments: [0, 1])
        func noNewBytesGivesNil(pastTheEnd: Int) throws {
            let url = try home.writeCodexRollout("rollout-1", lines: firstTurn)
            let size = TRFixture.jsonl(firstTurn).utf8.count
            #expect(TranscriptReader.incrementalLiveState(in: url, fromOffset: size + pastTheEnd) == nil)
        }

        @Test(.tags(.transcriptReaderEdgeCase))
        func rolloutOutsideACodexFolderIsReadAsClaude() throws {
            let url = try home.write("elsewhere/rollout-1.jsonl", contents: TRFixture.jsonl(firstTurn))
            #expect(TranscriptReader.incrementalLiveState(in: url, fromOffset: 0) == nil)
        }

        @Test(.tags(.transcriptReaderEdgeCase))
        func lineSplitAcrossTwoReadsIsStillParsed() throws {
            let reply = TRFixture.codexMessage("assistant", "Added.")
            let half = reply.index(reply.startIndex, offsetBy: reply.count / 2)
            let url = try home.writeCodexRollout("rollout-1", lines: [TRFixture.codexMeta(), TRFixture.codexMessage("user", "Add a test")])
            try home.append(String(reply[..<half]), to: url)
            let first = try #require(TranscriptReader.incrementalLiveState(in: url, fromOffset: 0))
            #expect(first.lastRole == "user", "Only the user's message is complete so far")
            try home.append(String(reply[half...]) + "\n", to: url)
            withKnownIssue("incrementalLiveState sets newOffset to the end of the file even when the last line is still half-written, so the rest of that line is unparseable on the next read and the assistant's reply is lost") {
                let second = try #require(TranscriptReader.incrementalLiveState(in: url, fromOffset: first.newOffset))
                #expect(second.lastRole == "assistant")
                #expect(second.liveState.working == false)
            }
        }
    }
}

// MARK: - summary(at:agent:) — Claude

extension TranscriptReaderTests {
    struct ClaudeSummary {
        private let home: TranscriptReaderHome

        init() throws {
            home = try TranscriptReaderHome()
        }

        private func transcript(_ lines: [String]) throws -> URL {
            try home.writeClaudeTranscript(id: "history", lines: lines)
        }

        @Test func summarizesTheConversation() throws {
            let cwd: [String: Any] = ["cwd": TRFixture.workdir]
            let url = try transcript([
                TRFixture.claudeUser("Fix the login bug\nplease", extra: cwd),
                TRFixture.claudeAssistant(extra: cwd),
                TRFixture.claudeUser("Thanks", extra: cwd),
            ])
            let summary = try #require(TranscriptReader.summary(at: url, agent: .claude))
            #expect(summary.firstPrompt == "Fix the login bug please", "The title is one line")
            #expect(summary.cwd == TRFixture.workdir)
            #expect(summary.messageCount == 3)
            #expect(summary.searchText == "Fix the login bug\nplease\nFixed.\nThanks\n", "Search keeps the raw text")
            #expect(summary.sessionID == nil, "Claude's id is the file name")
        }

        @Test func cwdComesFromTheFirstLineThatHasOne() throws {
            let url = try transcript([
                TRFixture.json(["type": "system", "subtype": "init", "cwd": "/first"]),
                TRFixture.claudeUser(extra: ["cwd": "/second"]),
            ])
            let summary = try #require(TranscriptReader.summary(at: url, agent: .claude))
            #expect(summary.cwd == "/first", "Any line's cwd counts, not just a message's")
        }

        @Test func firstPromptIsTheFirstUserMessage() throws {
            let url = try transcript([TRFixture.claudeAssistant([TRFixture.textBlock("Hello!")]), TRFixture.claudeUser()])
            let summary = try #require(TranscriptReader.summary(at: url, agent: .claude))
            #expect(summary.firstPrompt == TRFixture.prompt)
            #expect(summary.messageCount == 2)
        }

        @Test func linesWithoutTextAreNotCounted() throws {
            let url = try transcript([
                TRFixture.claudeUser(),
                TRFixture.claudeAssistant([TRFixture.toolUseBlock], stopReason: "tool_use"),
                TRFixture.claudeUser(TRFixture.toolResult()),
                TRFixture.claudeUser(""),
                TRFixture.claudeAssistant([[String: Any]]()),
                TRFixture.claudeSystem(),
                TRFixture.summaryLine,
                "not json",
            ])
            let summary = try #require(TranscriptReader.summary(at: url, agent: .claude))
            #expect(summary.messageCount == 1)
            #expect(summary.searchText == TRFixture.prompt + "\n")
        }

        @Test(.tags(.transcriptReaderEdgeCase))
        func whitespaceOnlyPromptCountsButIsNotTheTitle() throws {
            let url = try transcript([TRFixture.claudeUser("   "), TRFixture.claudeUser()])
            let summary = try #require(TranscriptReader.summary(at: url, agent: .claude))
            #expect(summary.messageCount == 2)
            #expect(summary.firstPrompt == TRFixture.prompt)
        }

        @Test func textBlocksAreJoined() throws {
            let url = try transcript([TRFixture.claudeUser([
                TRFixture.textBlock("Fix the"), TRFixture.imageBlock, TRFixture.textBlock("login bug"),
            ])])
            let summary = try #require(TranscriptReader.summary(at: url, agent: .claude))
            #expect(summary.firstPrompt == "Fix the login bug")
            #expect(summary.searchText == "Fix the login bug\n")
        }

        @Test(.tags(.transcriptReaderEdgeCase))
        func injectedContextIsNotTheFirstPrompt() throws {
            let url = try transcript([
                TRFixture.claudeUser("<command-name>/init</command-name>\n<command-message>init</command-message>"),
                TRFixture.claudeUser(),
                TRFixture.claudeAssistant(),
            ])
            let summary = try #require(TranscriptReader.summary(at: url, agent: .claude))
            withKnownIssue("Claude's summary takes the first user text as the History title without skipping injected <…> context, unlike Claude live state and the Codex summary, so a conversation that opened with a slash command is titled \"<command-name>/init</command-name> …\"") {
                #expect(summary.firstPrompt == TRFixture.prompt)
            }
        }

        @Test func transcriptWithoutMessagesGivesNil() throws {
            let url = try transcript([TRFixture.summaryLine, TRFixture.claudeSystem()])
            #expect(TranscriptReader.summary(at: url, agent: .claude) == nil)
        }

        @Test(.tags(.transcriptReaderEdgeCase))
        func emptyOrMissingTranscriptGivesNil() throws {
            let empty = try transcript([])
            let missing = home.root.appendingPathComponent(".claude/projects/missing.jsonl")
            #expect(TranscriptReader.summary(at: empty, agent: .claude) == nil)
            #expect(TranscriptReader.summary(at: missing, agent: .claude) == nil)
        }

        @Test(arguments: ["gemini", "shell", "my-kit-agent"])
        func otherAgentsHaveNoSummary(agent: String) throws {
            let url = try transcript([TRFixture.claudeUser(), TRFixture.claudeAssistant()])
            #expect(TranscriptReader.summary(at: url, agent: AgentKind(rawValue: agent)) == nil,
                    "An unknown format isn't assumed to be Claude's")
        }
    }
}

// MARK: - summary(at:agent:) — Codex

extension TranscriptReaderTests {
    struct CodexSummary {
        private let home: TranscriptReaderHome

        init() throws {
            home = try TranscriptReaderHome()
        }

        @Test func summarizesTheRollout() throws {
            let url = try home.writeCodexRollout("rollout-1", lines: [
                TRFixture.codexMeta(id: "thread-1"),
                TRFixture.codexMessage("user", "Add a test\nfor login"),
                TRFixture.codexMessage("assistant", "Added."),
            ])
            let summary = try #require(TranscriptReader.summary(at: url, agent: .codex))
            #expect(summary.firstPrompt == "Add a test for login")
            #expect(summary.cwd == TRFixture.workdir)
            #expect(summary.sessionID == "thread-1")
            #expect(summary.messageCount == 2)
            #expect(summary.searchText == "Add a test\nfor login\nAdded.\n")
        }

        @Test func injectedContextAndNonMessagesAreSkipped() throws {
            let url = try home.writeCodexRollout("rollout-1", lines: [
                TRFixture.codexMeta(),
                TRFixture.codexMessage("developer", "You are Codex."),
                TRFixture.codexMessage("user", TRFixture.codexEnvironmentContext),
                TRFixture.codexMessage("user", "Add a test"),
            ] + TRFixture.codexToolLines + [
                TRFixture.codexEvent("Add a test"),
                TRFixture.codexMessage("assistant", "Added."),
            ])
            let summary = try #require(TranscriptReader.summary(at: url, agent: .codex))
            #expect(summary.firstPrompt == "Add a test", "The injected <environment_context> isn't the title")
            #expect(summary.messageCount == 2)
            #expect(summary.searchText == "Add a test\nAdded.\n")
        }

        @Test func everyTextBlockIsJoined() throws {
            let url = try home.writeCodexRollout("rollout-1", lines: [
                TRFixture.codexMeta(),
                TRFixture.codexItem(["type": "message", "role": "user", "content": [
                    ["type": "input_text", "text": "Add"],
                    ["type": "input_image", "image_url": "data:image/png;base64,AAAA"],
                    ["type": "input_text", "text": "a test"],
                ]]),
            ])
            let summary = try #require(TranscriptReader.summary(at: url, agent: .codex))
            #expect(summary.firstPrompt == "Add a test")
        }

        @Test func plainStringContentIsAccepted() throws {
            let url = try home.writeCodexRollout("rollout-1", lines: [
                TRFixture.codexMeta(),
                TRFixture.codexItem(["type": "message", "role": "user", "content": "Add a test"]),
            ])
            let summary = try #require(TranscriptReader.summary(at: url, agent: .codex))
            #expect(summary.firstPrompt == "Add a test")
        }

        @Test func assistantTextStartingWithAnAngleBracketIsKept() throws {
            let url = try home.writeCodexRollout("rollout-1", lines: [
                TRFixture.codexMeta(), TRFixture.codexMessage("user", "Add a test"), TRFixture.codexMessage("assistant", "<b>Added.</b>"),
            ])
            let summary = try #require(TranscriptReader.summary(at: url, agent: .codex))
            #expect(summary.messageCount == 2, "Only user messages can be injected context")
            #expect(summary.searchText == "Add a test\n<b>Added.</b>\n")
        }

        @Test func firstSessionMetaWins() throws {
            let url = try home.writeCodexRollout("rollout-1", lines: [
                TRFixture.codexMeta(id: "thread-1", cwd: "/first"),
                TRFixture.codexMeta(id: "thread-2", cwd: "/second"),
                TRFixture.codexMessage("user", "Add a test"),
            ])
            let summary = try #require(TranscriptReader.summary(at: url, agent: .codex))
            #expect(summary.sessionID == "thread-1")
            #expect(summary.cwd == "/first")
        }

        @Test func rolloutWithoutSessionMetaHasNoIDOrFolder() throws {
            let url = try home.writeCodexRollout("rollout-1", lines: [
                TRFixture.codexMessage("user", "Add a test"), TRFixture.codexMessage("assistant", "Added."),
            ])
            let summary = try #require(TranscriptReader.summary(at: url, agent: .codex))
            #expect(summary.sessionID == nil)
            #expect(summary.cwd == nil)
            #expect(summary.messageCount == 2)
        }

        @Test func rolloutWithoutMessagesGivesNil() throws {
            let url = try home.writeCodexRollout("rollout-1", lines: [
                TRFixture.codexMeta(), TRFixture.codexMessage("user", TRFixture.codexEnvironmentContext),
            ] + TRFixture.codexToolLines)
            #expect(TranscriptReader.summary(at: url, agent: .codex) == nil)
        }
    }
}

// MARK: - messages(at:agent:)

extension TranscriptReaderTests {
    struct Messages {
        private let home: TranscriptReaderHome

        init() throws {
            home = try TranscriptReaderHome()
        }

        @Test func claudeMessagesKeepTheirOrderAndRawText() throws {
            let url = try home.writeClaudeTranscript(id: "history", lines: [
                TRFixture.summaryLine,
                TRFixture.claudeUser("Fix the\nlogin bug"),
                TRFixture.claudeAssistant([TRFixture.toolUseBlock], stopReason: "tool_use"),
                TRFixture.claudeUser(TRFixture.toolResult()),
                TRFixture.claudeAssistant([TRFixture.textBlock("Fixed"), TRFixture.textBlock("it.")]),
                TRFixture.claudeSystem(),
            ])
            let messages = TranscriptReader.messages(at: url, agent: .claude)
            #expect(messages.map { $0.role } == ["user", "assistant"])
            #expect(messages.map { $0.text } == ["Fix the\nlogin bug", "Fixed it."], "The preview isn't flattened to one line")
        }

        @Test func codexMessagesSkipInjectedContextAndToolCalls() throws {
            let url = try home.writeCodexRollout("rollout-1", lines: [
                TRFixture.codexMeta(),
                TRFixture.codexMessage("developer", "You are Codex."),
                TRFixture.codexMessage("user", TRFixture.codexEnvironmentContext),
                TRFixture.codexMessage("user", "Add a test"),
            ] + TRFixture.codexToolLines + [
                TRFixture.codexMessage("assistant", "Added."),
                TRFixture.codexMessage("user", "Now the docs"),
            ])
            let messages = TranscriptReader.messages(at: url, agent: .codex)
            #expect(messages.map { $0.role } == ["user", "assistant", "user"])
            #expect(messages.map { $0.text } == ["Add a test", "Added.", "Now the docs"])
        }

        @Test(arguments: ["gemini", "shell", "my-kit-agent"])
        func otherAgentsHaveNoMessages(agent: String) throws {
            let url = try home.writeClaudeTranscript(id: "history", lines: [TRFixture.claudeUser(), TRFixture.claudeAssistant()])
            #expect(TranscriptReader.messages(at: url, agent: AgentKind(rawValue: agent)).isEmpty)
        }

        @Test(.tags(.transcriptReaderEdgeCase), arguments: ["claude", "codex"])
        func missingTranscriptHasNoMessages(agent: String) {
            let url = home.root.appendingPathComponent("missing.jsonl")
            #expect(TranscriptReader.messages(at: url, agent: AgentKind(rawValue: agent)).isEmpty)
        }
    }
}

// MARK: - codexFiles(home:limit:)

extension TranscriptReaderTests {
    struct CodexFiles {
        private let home: TranscriptReaderHome

        init() throws {
            home = try TranscriptReaderHome()
        }

        @Test func findsRolloutsInNestedFoldersNewestFirst() throws {
            try home.writeCodexRollout("a", day: "2026/01/01", lines: [TRFixture.codexMeta()], modified: TRFixture.epoch + 10)
            try home.writeCodexRollout("b", day: "2026/01/03", lines: [TRFixture.codexMeta()], modified: TRFixture.epoch + 30)
            try home.write(".codex/sessions/c.jsonl", contents: TRFixture.codexMeta(), modified: TRFixture.epoch + 20)
            let files = TranscriptReader.codexFiles(home: home.root)
            #expect(files.map { $0.url.lastPathComponent } == ["b.jsonl", "c.jsonl", "a.jsonl"])
            #expect(files.map { $0.date } == [TRFixture.epoch + 30, TRFixture.epoch + 20, TRFixture.epoch + 10])
        }

        @Test func onlyVisibleJSONLFilesCount() throws {
            try home.writeCodexRollout("rollout-1", lines: [TRFixture.codexMeta()])
            let day = ".codex/sessions/2026/01/02"
            try home.write("\(day)/notes.txt", contents: "x")
            try home.write("\(day)/rollout-2.json", contents: "{}")
            try home.write("\(day)/.hidden.jsonl", contents: TRFixture.codexMeta())
            try home.write(".codex/sessions/.archive/old.jsonl", contents: TRFixture.codexMeta())
            let files = TranscriptReader.codexFiles(home: home.root)
            #expect(files.map { $0.url.lastPathComponent } == ["rollout-1.jsonl"])
        }

        @Test func missingSessionsFolderGivesNoFiles() throws {
            try home.writeClaudeTranscript(id: "session")
            #expect(TranscriptReader.codexFiles(home: home.root).isEmpty)
        }

        @Test(arguments: [(1, 1), (2, 2), (3, 3), (10, 3)])
        func limitCapsTheNumberOfFiles(limit: Int, expectedCount: Int) throws {
            for (index, day) in ["2026/01/01", "2026/01/02", "2026/01/03"].enumerated() {
                try home.writeCodexRollout("rollout-\(index)", day: day, lines: [TRFixture.codexMeta()])
            }
            #expect(TranscriptReader.codexFiles(home: home.root, limit: limit).count == expectedCount)
        }

        @Test(.tags(.transcriptReaderEdgeCase))
        func zeroLimitGivesNoFiles() throws {
            try home.writeCodexRollout("rollout-1", lines: [TRFixture.codexMeta()])
            let files = TranscriptReader.codexFiles(home: home.root, limit: 0)
            withKnownIssue("codexFiles appends a file before checking the limit, so a limit of 0 (or less) still returns one file") {
                #expect(files.isEmpty)
            }
        }
    }
}

// MARK: - moveClaudeProjects(_:home:)

extension TranscriptReaderTests {
    /// A folder rename takes its sessions' Claude conversations along, so they resume (xmas-sandshell-e7q.84).
    struct MoveClaudeProjects {
        private let home: TranscriptReaderHome

        init() throws {
            home = try TranscriptReaderHome()
        }

        private func projectsFolder(_ encoded: String) -> URL {
            home.root.appendingPathComponent(".claude/projects/\(encoded)", isDirectory: true)
        }

        private func contents(_ encoded: String) throws -> Set<String> {
            Set(try FileManager.default.contentsOfDirectory(atPath: projectsFolder(encoded).path))
        }

        @Test func movesTheFolderOfTheOldCwdToTheNewOne() throws {
            try home.writeClaudeTranscript(id: "session")
            try home.write(".claude/projects/\(TRFixture.encodedWorkdir)/session/subagents/agent-1.jsonl", contents: "{}\n")

            TranscriptReader.moveClaudeProjects([(TRFixture.workdir, TRFixture.otherWorkdir)], home: home.root)

            #expect(FileManager.default.fileExists(atPath: projectsFolder(TRFixture.encodedWorkdir).path) == false)
            #expect(try contents(TRFixture.encodedOtherWorkdir) == ["session.jsonl", "session"])
            #expect(TranscriptReader.transcriptExists(agent: .claude, workdir: TRFixture.otherWorkdir,
                                                      home: home.root, id: "session"),
                    "Resuming in the new cwd finds the conversation")
        }

        @Test func mergesIntoAFolderTheNewCwdAlreadyHas() throws {
            try home.writeClaudeTranscript(id: "moved")
            try home.writeClaudeTranscript(id: "already-there", folder: TRFixture.encodedOtherWorkdir)

            TranscriptReader.moveClaudeProjects([(TRFixture.workdir, TRFixture.otherWorkdir)], home: home.root)

            #expect(try contents(TRFixture.encodedOtherWorkdir) == ["moved.jsonl", "already-there.jsonl"])
            #expect(FileManager.default.fileExists(atPath: projectsFolder(TRFixture.encodedWorkdir).path) == false,
                    "The emptied old folder goes")
        }

        @Test(.tags(.transcriptReaderEdgeCase))
        func neverReplacesAFileTheNewFolderHas() throws {
            try home.writeClaudeTranscript(id: "same", lines: [TRFixture.claudeUser("old cwd")])
            try home.writeClaudeTranscript(id: "same", folder: TRFixture.encodedOtherWorkdir,
                                           lines: [TRFixture.claudeUser("new cwd")])

            TranscriptReader.moveClaudeProjects([(TRFixture.workdir, TRFixture.otherWorkdir)], home: home.root)

            let kept = projectsFolder(TRFixture.encodedOtherWorkdir).appendingPathComponent("same.jsonl")
            #expect(try String(contentsOf: kept, encoding: .utf8).contains("new cwd"))
            #expect(try contents(TRFixture.encodedWorkdir) == ["same.jsonl"],
                    "The clashing file stays where it was, and so does its folder")
        }

        @Test(.tags(.transcriptReaderEdgeCase))
        func aCwdWithNoConversationsIsSkipped() throws {
            try home.writeClaudeTranscript(id: "other", folder: TRFixture.encodedOtherWorkdir)

            TranscriptReader.moveClaudeProjects([("/Users/test/Code/none", TRFixture.otherWorkdir),
                                                 (TRFixture.workdir, "/Users/test/Code/new")], home: home.root)

            #expect(try contents(TRFixture.encodedOtherWorkdir) == ["other.jsonl"])
            #expect(FileManager.default.fileExists(atPath: projectsFolder("-Users-test-Code-new").path) == false)
        }

        @Test(.tags(.transcriptReaderEdgeCase))
        func aRenameClaudeEncodesTheSameWayLeavesTheFolderAlone() throws {
            try home.writeClaudeTranscript(id: "session", folder: "-Users-test-a-b")

            TranscriptReader.moveClaudeProjects([("/Users/test/a b", "/Users/test/a-b")], home: home.root)

            #expect(try contents("-Users-test-a-b") == ["session.jsonl"])
        }
    }
}

// MARK: - Fixtures

fileprivate enum TRFixture {
    /// A whole-second date, so it survives the round trip through file timestamps exactly.
    static let epoch = Date(timeIntervalSince1970: 1_700_000_000)
    static let workdir = "/Users/test/Code/project"
    /// `workdir` as Claude Code names its project folder (written out, not computed).
    static let encodedWorkdir = "-Users-test-Code-project"
    static let otherWorkdir = "/Users/test/Code/other"
    static let encodedOtherWorkdir = "-Users-test-Code-other"
    static let prompt = "Fix the login bug"
    static let summaryLine = #"{"type":"summary","summary":"Login fix","leafUuid":"u1"}"#
    static let codexEnvironmentContext = "<environment_context>\n  <cwd>/Users/test/Code/project</cwd>\n</environment_context>"

    /// One compact JSON line (JSONSerialization never pretty-prints without being asked).
    static func json(_ object: [String: Any]) -> String {
        // An invalid object raises an Objective-C exception rather than throwing, so check first.
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        else {
            Issue.record("Fixture isn't representable as JSON: \(object)")
            return ""
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// JSONL: each line newline-terminated.
    static func jsonl(_ lines: [String]) -> String {
        lines.map { $0 + "\n" }.joined()
    }

    // MARK: Claude Code lines

    static func claudeUser(_ content: Any = prompt, extra: [String: Any] = [:]) -> String {
        var line: [String: Any] = ["type": "user", "message": ["role": "user", "content": content] as [String: Any]]
        line.merge(extra) { _, new in new }
        return json(line)
    }

    /// A nil `stopReason` writes `null`, as a still-streaming reply does.
    static func claudeAssistant(_ content: Any = [textBlock("Fixed.")], stopReason: String? = "end_turn",
                                extra: [String: Any] = [:]) -> String {
        let message: [String: Any] = [
            "role": "assistant", "content": content, "stop_reason": stopReason.map { $0 as Any } ?? NSNull(),
        ]
        var line: [String: Any] = ["type": "assistant", "message": message]
        line.merge(extra) { _, new in new }
        return json(line)
    }

    /// A `system` line; `pending` adds `pendingBackgroundAgentCount`.
    static func claudeSystem(subtype: String = "turn_duration", pending: Int? = nil) -> String {
        var line: [String: Any] = ["type": "system", "subtype": subtype, "durationMs": 1_200]
        if let pending { line["pendingBackgroundAgentCount"] = pending }
        return json(line)
    }

    static func textBlock(_ text: String) -> [String: Any] {
        ["type": "text", "text": text]
    }

    static var imageBlock: [String: Any] {
        ["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": "AAAA"]]
    }

    static var toolUseBlock: [String: Any] {
        ["type": "tool_use", "id": "toolu_1", "name": "Bash", "input": ["command": "swift test"]]
    }

    static func toolResult(_ text: String = "ok") -> [[String: Any]] {
        [["type": "tool_result", "tool_use_id": "toolu_1", "content": text]]
    }

    // MARK: Codex rollout lines

    static func codexMeta(id: String? = "thread-1", cwd: String? = workdir, originator: String? = "codex_cli_rs") -> String {
        var payload: [String: Any] = [:]
        if let id { payload["id"] = id }
        if let cwd { payload["cwd"] = cwd }
        if let originator { payload["originator"] = originator }
        return json(["timestamp": "2026-01-02T10:00:00.000Z", "type": "session_meta", "payload": payload])
    }

    /// A `response_item` message with one `input_text` (or, for the assistant, `output_text`) block.
    static func codexMessage(_ role: String, _ text: String) -> String {
        let blockType = role == "assistant" ? "output_text" : "input_text"
        return codexItem(["type": "message", "role": role, "content": [["type": blockType, "text": text]]])
    }

    static func codexItem(_ payload: [String: Any]) -> String {
        json(["timestamp": "2026-01-02T10:00:01.000Z", "type": "response_item", "payload": payload])
    }

    /// An `event_msg` line, which carries no turn of its own.
    static func codexEvent(_ message: String) -> String {
        json(["timestamp": "2026-01-02T10:00:01.000Z", "type": "event_msg",
              "payload": ["type": "user_message", "message": message]])
    }

    /// A tool call, its output and a reasoning item: none of them a message.
    static var codexToolLines: [String] {
        [
            codexItem(["type": "function_call", "name": "shell", "arguments": "{}", "call_id": "call_1"]),
            codexItem(["type": "function_call_output", "call_id": "call_1", "output": "ok"]),
            codexItem(["type": "reasoning", "summary": [String]()]),
        ]
    }
}

/// A fresh fake home folder under the temporary directory (holding `.claude/projects/…`
/// and `.codex/sessions/…` as a test needs them), removed when the owning test ends.
fileprivate final class TranscriptReaderHome: Sendable {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SandshellTranscriptReaderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    /// Writes `data` at `relativePath` under the home (making its folders), with its
    /// modification date set when given.
    @discardableResult
    func write(_ relativePath: String, data: Data, modified: Date? = nil) throws -> URL {
        let url = root.appendingPathComponent(relativePath, isDirectory: false)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        if let modified {
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        }
        return url
    }

    @discardableResult
    func write(_ relativePath: String, contents: String, modified: Date? = nil) throws -> URL {
        try write(relativePath, data: Data(contents.utf8), modified: modified)
    }

    /// `~/.claude/projects/<folder>/<id>.jsonl`.
    @discardableResult
    func writeClaudeTranscript(id: String, folder: String = TRFixture.encodedWorkdir,
                               lines: [String] = [TRFixture.claudeUser()], modified: Date? = nil) throws -> URL {
        try write(".claude/projects/\(folder)/\(id).jsonl", contents: TRFixture.jsonl(lines), modified: modified)
    }

    /// `~/.codex/sessions/<day>/<name>.jsonl`.
    @discardableResult
    func writeCodexRollout(_ name: String, day: String = "2026/01/02", lines: [String],
                           modified: Date? = nil) throws -> URL {
        try write(".codex/sessions/\(day)/\(name).jsonl", contents: TRFixture.jsonl(lines), modified: modified)
    }

    func append(_ text: String, to url: URL) throws {
        try append(Data(text.utf8), to: url)
    }

    func append(_ data: Data, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }
}

/// A path to compare file URLs by, whichever API produced them (symlinks such as
/// /var → /private/var resolved the same way on both sides).
fileprivate func canonicalPath(_ url: URL?) -> String? {
    url?.resolvingSymlinksInPath().path
}
