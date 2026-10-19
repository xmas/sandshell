import Foundation
import Testing
@testable import Sandshell

/// A session's forks and names: `Session.forkedFrom`/`forkedAt`,
/// `firstPrompt`/`generatedName` and `displayName`.
struct SessionNamingTests {
    fileprivate static let referenceDate = Date(timeIntervalSince1970: 1_700_000_000)

    fileprivate static func session(_ name: String = "New Claude Session", agent: AgentKind = .claude,
                                    containerAgent: AgentKind? = nil) -> Session {
        Session(folderID: UUID(), agent: agent, name: name, order: 0, workdir: "/workspace",
                createdAt: referenceDate, containerAgent: containerAgent)
    }

    fileprivate static func decode(_ json: String) throws -> Session {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Session.self, from: Data(json.utf8))
    }

    fileprivate static func encodedKeys(_ session: Session) throws -> Set<String> {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let object = try JSONSerialization.jsonObject(with: encoder.encode(session))
        return Set(try #require(object as? [String: Any]).keys)
    }
}

// MARK: - Coding

extension SessionNamingTests {
    struct Coding {
        /// A state.json written before forks and first prompts.
        @Test func anOldSessionDecodesWithoutTheNewFields() throws {
            let old = try SessionNamingTests.decode(#"""
                {"id":"6F1A3C1E-0000-4000-8000-000000000001","folderID":"6F1A3C1E-0000-4000-8000-000000000002",
                 "agent":"claude","name":"fix the login bug","order":0,"workdir":"/workspace",
                 "createdAt":"2023-11-14T22:13:20Z","chat":true}
                """#)
            #expect(old.forkedFrom == nil)
            #expect(old.forkedAt == nil)
            #expect(old.firstPrompt == nil)
            #expect(old.generatedName == nil)
            #expect(old.name == "fix the login bug")
        }

        @Test func theNewFieldsAreWrittenOnlyWhenSet() throws {
            let keys = try SessionNamingTests.encodedKeys(SessionNamingTests.session())
            #expect(keys.isDisjoint(with: ["forkedFrom", "forkedAt", "firstPrompt", "generatedName"]))

            var full = SessionNamingTests.session()
            full.forkedFrom = UUID()
            full.forkedAt = SessionNamingTests.referenceDate
            full.firstPrompt = "a"
            full.generatedName = "b"
            #expect(try SessionNamingTests.encodedKeys(full)
                .isSuperset(of: ["forkedFrom", "forkedAt", "firstPrompt", "generatedName"]))
        }
    }
}

// MARK: - Display name

extension SessionNamingTests {
    struct DisplayName {
        struct Case: CustomTestStringConvertible, Sendable {
            var label: String
            var named: Bool = false
            var name = "New Claude Session"
            var generated: String?
            var first: String?
            var expected: String
            var testDescription: String { label }
        }

        @Test(arguments: [
            Case(label: "the person's name wins", named: true, name: "Release checklist",
                 generated: "Fixing login", first: "fix the login bug", expected: "Release checklist"),
            Case(label: "then the agent's title", generated: "Fixing login", first: "fix the login bug",
                 expected: "Fixing login"),
            Case(label: "then the first prompt", first: "fix the login bug", expected: "fix the login bug"),
            Case(label: "nothing asked yet", expected: "New session"),
            Case(label: "an automatic name never shows the stored one", name: "an old rename",
                 first: "fix the login bug", expected: "fix the login bug"),
        ])
        func resolvesInOrder(_ c: Case) {
            var s = SessionNamingTests.session(c.name)
            s.isNamedByUser = c.named
            s.generatedName = c.generated
            s.firstPrompt = c.first
            #expect(s.displayName == c.expected)
        }

        @Test func aForkWithNothingAskedIsAForkOfItsSource() {
            var source = SessionNamingTests.session()
            source.firstPrompt = "fix the login bug"
            let fork = Session.fork(of: source, name: "Fork of fix the login bug", order: 1,
                                    workdir: "/workspace", at: SessionNamingTests.referenceDate)
            let lookup: (UUID) -> Session? = { $0 == source.id ? source : nil }

            #expect(fork.displayName(parent: lookup) == "Fork of fix the login bug")
            source.generatedName = "Fixing login"
            #expect(fork.displayName(parent: { $0 == source.id ? source : nil }) == "Fork of Fixing login",
                    "It follows its source's name")
        }

        @Test func aForkOfAForkNamesTheWholeChain() {
            var source = SessionNamingTests.session()
            source.firstPrompt = "root"
            let first = Session.fork(of: source, name: "x", order: 1, workdir: "/w", at: SessionNamingTests.referenceDate)
            let second = Session.fork(of: first, name: "y", order: 2, workdir: "/w", at: SessionNamingTests.referenceDate)
            let all = [source, first, second]
            #expect(second.displayName { id in all.first { $0.id == id } } == "Fork of Fork of root")
        }

        @Test(.tags(.edgeCase))
        func aForkWhoseSourceIsGoneReadsAsItWasNamed() {
            let fork = Session.fork(of: SessionNamingTests.session(), name: "Fork of fix the login bug", order: 1,
                                    workdir: "/workspace", at: SessionNamingTests.referenceDate)
            #expect(fork.displayName(parent: { _ in nil }) == "Fork of fix the login bug")
            #expect(fork.displayName == "Fork of fix the login bug")
        }

        @Test func aForksOwnFirstPromptNamesIt() {
            let source = SessionNamingTests.session()
            var fork = Session.fork(of: source, name: "Fork of x", order: 1, workdir: "/w",
                                    at: SessionNamingTests.referenceDate)
            let recorded = fork.recordPrompt("try it the other way")
            #expect(recorded)
            #expect(fork.displayName(parent: { _ in source }) == "try it the other way")
        }

        @Test func aShellKeepsReadingAsAShell() {
            let shell = SessionNamingTests.session("Shell in Claude", agent: .shell, containerAgent: .claude)
            #expect(shell.displayName == "Shell in Claude")
        }

        /// Clearing a rename (Session ▸ Rename… with an empty name) puts the
        /// automatic name back.
        @Test func clearingARenameRevertsToTheAutomaticName() throws {
            var s = SessionNamingTests.session()
            s.firstPrompt = "fix the login bug"
            let renamed = try #require(s.renamed(to: "Release checklist"))
            #expect(renamed.displayName == "Release checklist")
            let cleared = try #require(renamed.renamed(to: "  "))
            #expect(!cleared.isNamedByUser)
            #expect(cleared.displayName == "fix the login bug")

            var titled = cleared
            titled.generatedName = "Fixing login"
            #expect(titled.displayName == "Fixing login")
        }
    }
}

// MARK: - Automatic naming

extension SessionNamingTests {
    struct AutomaticNaming {
        @Test func theFirstPromptSticks() {
            var s = SessionNamingTests.session()
            let first = s.recordPrompt("  fix the login bug\n")
            #expect(first)
            #expect(s.firstPrompt == "fix the login bug", "Trimmed")
            let later = s.recordPrompt("and now the tests")
            #expect(!later, "A later prompt changes nothing")
            #expect(s.firstPrompt == "fix the login bug")
            #expect(s.name == "New Claude Session", "The stored name isn't touched")
            #expect(s.displayName == "fix the login bug")
        }

        @Test(.tags(.edgeCase), arguments: ["", "   ", "\n\t"])
        func aBlankPromptIsNotTheFirst(prompt: String) {
            var s = SessionNamingTests.session()
            let blank = s.recordPrompt(prompt)
            #expect(!blank)
            #expect(s.firstPrompt == nil)
            let real = s.recordPrompt("fix it")
            #expect(real, "The first real one is")
        }

        @Test func theFirstTitleSticks() {
            var s = SessionNamingTests.session()
            let blank = s.adoptGeneratedName("  ")
            let first = s.adoptGeneratedName("Fixing login")
            let second = s.adoptGeneratedName("Something else")
            #expect(!blank && first && !second)
            #expect(s.generatedName == "Fixing login")
        }

        @Test func aRenamedSessionKeepsItsNameAsPromptsArrive() throws {
            var s = try #require(SessionNamingTests.session().renamed(to: "Release checklist"))
            _ = s.recordPrompt("some later prompt")
            #expect(s.displayName == "Release checklist")
            #expect(s.name == "Release checklist")
        }
    }
}

// MARK: - Forking

extension SessionNamingTests {
    struct Forking {
        @Test func aForkRemembersItsSourceAndWhen() {
            var source = SessionNamingTests.session()
            source.firstPrompt = "fix the login bug"
            source.generatedName = "Fixing login"
            source.transcriptID = "t-1"
            let at = SessionNamingTests.referenceDate.addingTimeInterval(600)

            let fork = Session.fork(of: source, name: "Fork of Fixing login", order: 4, workdir: "/workspace/app", at: at)

            #expect(fork.id != source.id)
            #expect(fork.forkedFrom == source.id)
            #expect(fork.forkedAt == at)
            #expect(fork.createdAt == at)
            #expect(fork.isFork && !source.isFork)
            #expect(fork.folderID == source.folderID && fork.agent == source.agent)
            #expect(fork.isChat)
            #expect(fork.order == 4 && fork.workdir == "/workspace/app")
            #expect(fork.firstPrompt == nil, "Its first prompt is its own")
            #expect(fork.generatedName == nil, "Its title is its own")
            #expect(fork.transcriptID == nil, "Set once its transcript is written")
            #expect(!fork.isNamedByUser)
        }
    }
}

// MARK: - Schema 3 migration

extension SessionNamingTests {
    struct LegacyNames {
        @Test(arguments: [
            ("fix the login bug", AgentKind.claude, nil as AgentKind?, "fix the login bug" as String?),
            ("Untitled conversation", .claude, nil, "Untitled conversation"),
            ("New Claude Session", .claude, nil, nil),
            ("New Docker-Agent Session", .dockerAgent, nil, nil),
            ("New Gemini Session", .claude, nil, nil),
            ("Shell in Claude", .shell, .claude, nil),
            ("", .claude, nil, nil),
        ])
        func aPromptsNameBecomesTheFirstPrompt(name: String, agent: AgentKind, container: AgentKind?,
                                                expected: String?) {
            var state = WorkspaceState(sessions: [SessionNamingTests.session(name, agent: agent, containerAgent: container)])
            state.migrateLegacyNames()
            #expect(state.sessions[0].firstPrompt == expected)
            #expect(state.sessions[0].name == name)
        }

        @Test func thePersonsNamesForksAndFirstPromptsAreLeftAlone() {
            var named = SessionNamingTests.session("Release checklist")
            named.isNamedByUser = true
            var prompted = SessionNamingTests.session("latest prompt")
            prompted.firstPrompt = "first prompt"
            let fork = Session.fork(of: named, name: "Fork of Release checklist", order: 1, workdir: "/w",
                                    at: SessionNamingTests.referenceDate)
            var state = WorkspaceState(sessions: [named, prompted, fork])

            state.migrateLegacyNames()

            #expect(state.sessions == [named, prompted, fork])
        }
    }
}
