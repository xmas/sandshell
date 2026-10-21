import Foundation
import Testing
@testable import Sandshell

// Tests for `KitRef` and `KitStore` (Sbx/KitStore.swift).
//
// The registry half of `KitStore` (`all`, `add`, `remove`, `update`,
// `setDefault`, the `seed…IfNeeded` steps, `defaults`, `defaultSandshellRefs`,
// `learn`) reads and writes `UserDefaults.standard` directly, and the test host
// is the real app (bundle id `com.xmas.sandshell`), so those would touch the
// user's own registry; they are not tested here. `requiredAgent` and
// `kits(_:for:)` are only exercised with refs that `KitStore` knows up front,
// which return before any `UserDefaults` or `AgentProfileStore` lookup.

extension Tag {
    /// Boundary cases for kit refs (fileprivate so it can't clash with other suites' tags).
    @Tag fileprivate static var kitStoreEdgeCase: Self
}

/// Fixtures and helpers shared by the suites in this file.
fileprivate enum KitStoreFixture {
    static func decode(_ json: String) throws -> KitRef {
        try JSONDecoder().decode(KitRef.self, from: Data(json.utf8))
    }

    /// The top-level keys `KitRef` writes when encoded.
    static func encodedKeys(of kit: KitRef) throws -> Set<String> {
        let data = try JSONEncoder().encode(kit)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        return Set(object.keys)
    }

    /// Refs `KitStore.requiredAgent` answers without consulting stored state.
    static let knownRefs = ["docker.io/sbx/code-server-kit:latest", "sandshell-claude", "sandshell-codex"]

    /// Every kit in the built-in catalogs. Computed rather than stored, and tests
    /// are parameterized over `builtInRefs`, so nothing here needs `KitRef: Sendable`.
    static var builtInKits: [KitRef] { KitStore.sandshellKits + KitStore.officialKits }
    static var builtInRefs: [String] { builtInKits.map(\.ref) }

    /// Each built-in ref, paired with whether it is one of Sandshell's own kits.
    static var builtInMembership: [(String, Bool)] {
        KitStore.sandshellKits.map { ($0.ref, true) } + KitStore.officialKits.map { ($0.ref, false) }
    }

    static func builtInKit(_ ref: String, sourceLocation: SourceLocation = #_sourceLocation) throws -> KitRef {
        let kit = builtInKits.first { $0.ref == ref }
        return try #require(kit, "\(ref) should be in a built-in catalog", sourceLocation: sourceLocation)
    }

    static func roundTripped(_ kit: KitRef) throws -> KitRef {
        try JSONDecoder().decode(KitRef.self, from: JSONEncoder().encode(kit))
    }
}

// MARK: - KitRef

struct KitStoreKitRefTests {
    @Test("A new KitRef has no metadata and is not a default")
    func initializerDefaults() {
        let kit = KitRef(ref: "/Users/dev/kits/my-kit")
        #expect(kit.ref == "/Users/dev/kits/my-kit")
        #expect(kit.displayName == nil)
        #expect(kit.summary == nil)
        #expect(kit.isDefault == false)
    }

    @Test("The identity of a KitRef is its reference")
    func idIsRef() {
        let kit = KitRef(ref: "docker.io/sbx/github-ssh-kit:latest", displayName: "GitHub SSH", summary: "Keys", isDefault: true)
        #expect(kit.id == "docker.io/sbx/github-ssh-kit:latest")
    }

    @Test("The title is the display name, else the last path or ref component", arguments: [
        ("/Users/dev/kits/my-kit", nil, "my-kit"),
        ("/tmp/scratch///", nil, "scratch"),
        ("docker.io/sbx/git-ssh-sign-kit:latest", nil, "git-ssh-sign-kit:latest"),
        ("sandshell-claude", nil, "sandshell-claude"),
        ("kits/archive.zip", "", "archive.zip"),
        ("docker.io/sbx/kit", "My Kit", "My Kit"),
        ("/Users/dev/kits/my-kit", "Spec Name", "Spec Name"),
    ] as [(String, String?, String)])
    func titleFallsBackToLeaf(ref: String, displayName: String?, expected: String) {
        let kit = KitRef(ref: ref, displayName: displayName)
        #expect(kit.title == expected)
    }

    @Test("Degenerate refs still produce a title", .tags(.kitStoreEdgeCase), arguments: [
        ("/", nil, "/"),
        ("", nil, ""),
        ("", "Named", "Named"),
    ] as [(String, String?, String)])
    func titleOfDegenerateRefs(ref: String, displayName: String?, expected: String) {
        let kit = KitRef(ref: ref, displayName: displayName)
        #expect(kit.title == expected)
    }

    @Test("Equal values are equal and hash alike")
    func equalValuesHashAlike() {
        let a = KitRef(ref: "/k", displayName: "K", summary: "S", isDefault: true)
        let b = KitRef(ref: "/k", displayName: "K", summary: "S", isDefault: true)
        #expect(a == b)
        #expect(a.hashValue == b.hashValue)
    }

    @Test("Two entries for one ref with different flags share an id but are not equal")
    func sameRefDifferentFlagIsNotEqual() {
        let plain = KitRef(ref: "/k")
        let flagged = KitRef(ref: "/k", isDefault: true)
        #expect(plain.id == flagged.id)
        #expect(plain != flagged)
    }
}

// MARK: - KitRef coding

struct KitStoreKitRefCodingTests {
    @Test("Decoding reads every field")
    func decodesAllFields() throws {
        let kit = try KitStoreFixture.decode(#"{"ref":"/k","displayName":"D","summary":"S","isDefault":true}"#)
        #expect(kit == KitRef(ref: "/k", displayName: "D", summary: "S", isDefault: true))
    }

    @Test("A registry entry saved before the default flag existed decodes as not a default")
    func missingFlagDecodesAsFalse() throws {
        let kit = try KitStoreFixture.decode(#"{"ref":"/k"}"#)
        #expect(kit.isDefault == false)
        #expect(kit.displayName == nil)
        #expect(kit.summary == nil)
    }

    @Test("Explicit nulls decode as missing values", .tags(.kitStoreEdgeCase))
    func nullsDecodeAsMissing() throws {
        let kit = try KitStoreFixture.decode(#"{"ref":"/k","displayName":null,"summary":null,"isDefault":null}"#)
        #expect(kit == KitRef(ref: "/k"))
    }

    @Test("Unknown keys are ignored, and the id always comes from the ref", .tags(.kitStoreEdgeCase))
    func unknownKeysIgnored() throws {
        let kit = try KitStoreFixture.decode(#"{"ref":"/k","id":"other","unknown":1}"#)
        #expect(kit.id == "/k")
        #expect(kit == KitRef(ref: "/k"))
    }

    @Test("An entry without a ref fails to decode")
    func missingRefThrows() throws {
        let error = try #require(throws: DecodingError.self) {
            try KitStoreFixture.decode(#"{"displayName":"D","isDefault":true}"#)
        }
        guard case .keyNotFound(let key, _) = error else {
            Issue.record("Expected keyNotFound, got \(error)")
            return
        }
        #expect(key.stringValue == "ref")
    }

    @Test("A null ref fails to decode", .tags(.kitStoreEdgeCase))
    func nullRefThrows() throws {
        let error = try #require(throws: DecodingError.self) {
            try KitStoreFixture.decode(#"{"ref":null}"#)
        }
        guard case .valueNotFound = error else {
            Issue.record("Expected valueNotFound, got \(error)")
            return
        }
    }

    @Test("A default flag of the wrong type fails to decode", .tags(.kitStoreEdgeCase))
    func wrongFlagTypeThrows() throws {
        let error = try #require(throws: DecodingError.self) {
            try KitStoreFixture.decode(#"{"ref":"/k","isDefault":"yes"}"#)
        }
        guard case .typeMismatch(_, let context) = error else {
            Issue.record("Expected typeMismatch, got \(error)")
            return
        }
        #expect(context.codingPath.last?.stringValue == "isDefault")
    }

    @Test("Encoding omits missing metadata but always writes the default flag")
    func encodingOmitsNilMetadata() throws {
        let keys = try KitStoreFixture.encodedKeys(of: KitRef(ref: "/k"))
        #expect(keys == ["ref", "isDefault"])
    }

    @Test("Encoding writes every field that has a value")
    func encodingWritesAllFields() throws {
        let keys = try KitStoreFixture.encodedKeys(of: KitRef(ref: "/k", displayName: "D", summary: "S", isDefault: true))
        #expect(keys == ["ref", "displayName", "summary", "isDefault"])
    }

    @Test("Every built-in catalog entry survives an encode/decode round trip", arguments: KitStoreFixture.builtInRefs)
    func builtInKitRoundTrips(ref: String) throws {
        let kit = try KitStoreFixture.builtInKit(ref)
        let decoded = try KitStoreFixture.roundTripped(kit)
        #expect(decoded == kit)
    }

    @Test("A bare entry survives an encode/decode round trip")
    func bareKitRoundTrips() throws {
        let kit = KitRef(ref: "/k")
        let decoded = try KitStoreFixture.roundTripped(kit)
        #expect(decoded == kit)
    }
}

// MARK: - Built-in catalogs

struct KitStoreCatalogTests {
    @Test("Sandshell's own kits are the Claude and Codex chat kits, in that order")
    func sandshellKitRefs() {
        #expect(KitStore.sandshellKits.map(\.ref) == ["sandshell-claude", "sandshell-codex"])
    }

    @Test("The official kits are the three docker.io kits, in that order")
    func officialKitRefs() {
        #expect(KitStore.officialKits.map(\.ref) == [
            "docker.io/sbx/git-ssh-sign-kit:latest",
            "docker.io/sbx/github-ssh-kit:latest",
            "docker.io/sbx/code-server-kit:latest",
        ])
    }

    @Test("Every built-in kit but code-server is a default; each has a display name and summary, and is titled by it",
          arguments: KitStoreFixture.builtInRefs)
    func builtInKitIsDescribedDefault(ref: String) throws {
        let kit = try KitStoreFixture.builtInKit(ref)
        #expect(kit.isDefault == (ref != KitStore.codeServerRef), "only code-server (minutes to install) is off by default")
        #expect(kit.displayName?.isEmpty == false, "a built-in kit needs a display name")
        #expect(kit.summary?.isEmpty == false, "a built-in kit needs a summary")
        #expect(kit.title == kit.displayName, "a built-in kit is titled by its display name")
    }

    @Test("The official kits come from docker.io, a source sbx allows without configuration",
          arguments: KitStore.officialKits.map(\.ref))
    func officialDefaultUsesAllowedSource(ref: String) {
        #expect(ref.hasPrefix("docker.io/"))
    }

    @Test("No ref appears twice across the built-in catalogs")
    func builtInRefsAreUnique() {
        let refs = KitStoreFixture.builtInRefs
        #expect(Set(refs).count == refs.count, "each built-in ref should appear once in \(refs)")
    }

    @Test("Sandshell's kits are recognized as Sandshell kits; the official kits are not",
          arguments: KitStoreFixture.builtInMembership)
    func catalogMembership(ref: String, isSandshellKit: Bool) {
        #expect(KitStore.isSandshellKit(ref) == isSandshellKit)
    }
}

// MARK: - Recognizing and resolving Sandshell's kits

struct KitStoreSandshellKitTests {
    @Test("A Sandshell kit is recognized by name or by a path ending in /kits/<name>", arguments: [
        "sandshell-claude",
        "sandshell-codex",
        "/Applications/Sandshell.app/Contents/Resources/kits/sandshell-claude",
        "/Users/dev/Code/xmas-sandshell/kits/sandshell-codex",
        "/kits/sandshell-claude",
    ])
    func recognizedSandshellKits(ref: String) {
        #expect(KitStore.isSandshellKit(ref))
    }

    @Test("Other refs, near misses included, are not Sandshell kits", .tags(.kitStoreEdgeCase), arguments: [
        "",
        "sandshell-gemini",
        "Sandshell-Claude",
        " sandshell-claude",
        "sandshell-claude-extra",
        "/Users/dev/kits/sandshell-claude-extra",
        "/Users/dev/mykits/sandshell-claude",
        "/Users/dev/sandshell-claude",
        "docker.io/sbx/git-ssh-sign-kit:latest",
    ])
    func unrecognizedRefs(ref: String) {
        #expect(KitStore.isSandshellKit(ref) == false)
    }

    @Test("Anything but a bare Sandshell kit name is passed to sbx unchanged", arguments: [
        "docker.io/sbx/github-ssh-kit:latest",
        "/Users/dev/kits/my-kit",
        "/Users/dev/kits/archive.zip",
        "sandshell-gemini",
        "Sandshell-Claude",
        "",
        // A path to a copy is already a path: only the bare name is resolved.
        "/Users/dev/Code/xmas-sandshell/kits/sandshell-claude",
    ])
    func otherRefsResolveToThemselves(ref: String) {
        #expect(KitStore.resolve(ref) == ref)
    }

    @Test("A Sandshell kit name resolves to the app's bundled copy, which is still recognized", arguments: [
        "sandshell-claude",
        "sandshell-codex",
    ])
    func sandshellKitResolvesToBundledCopy(ref: String) throws {
        // The test host is the app, which ships kits/ in its resources; a missing
        // folder is a packaging regression, not a case to tolerate.
        let base = try #require(SbxCommand.bundledKits, "The host app should bundle a kits folder")
        let resolved = KitStore.resolve(ref)
        #expect(resolved == base.appendingPathComponent(ref).path)
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: resolved, isDirectory: &isDirectory)
        #expect(exists, "The bundled kit should exist at \(resolved)")
        #expect(isDirectory.boolValue, "The bundled kit should be a directory")
        #expect(KitStore.isSandshellKit(resolved), "The resolved ref should still count as a Sandshell kit")
    }
}

// MARK: - Agent requirements

struct KitStoreAgentRequirementTests {
    @Test("Kits known up front report their agent without any lookup", arguments: [
        ("docker.io/sbx/code-server-kit:latest", "claude"),
        ("sandshell-claude", "claude"),
        ("sandshell-codex", "codex"),
    ])
    func knownRequirements(ref: String, agent: String) throws {
        let required = try #require(KitStore.requiredAgent(ref), "\(ref)'s requirement should be known")
        #expect(required == agent)
    }

    @Test("Only kits made for the sandbox's agent are kept, in their original order", arguments: [
        ("claude", ["docker.io/sbx/code-server-kit:latest", "sandshell-claude"]),
        ("codex", ["sandshell-codex"]),
        ("gemini", []),
        ("shell", []),
    ] as [(String, [String])])
    func kitsFilteredByAgent(agent: String, expected: [String]) {
        let kept = KitStore.kits(KitStoreFixture.knownRefs, for: AgentKind(rawValue: agent))
        #expect(kept == expected)
    }

    @Test("Agent names are matched exactly, so a differently cased agent takes none of them", .tags(.kitStoreEdgeCase))
    func agentMatchIsCaseSensitive() {
        let kept = KitStore.kits(KitStoreFixture.knownRefs, for: AgentKind(rawValue: "Claude"))
        #expect(kept.isEmpty)
    }

    @Test("No refs in means no refs out", .tags(.kitStoreEdgeCase))
    func emptyInput() {
        #expect(KitStore.kits([], for: .claude).isEmpty)
    }

    @Test("An inspected kit is cached with its kind: an agent kit can be told from a mixin made for that agent",
          arguments: [("sandbox", "droid", nil, "sandbox:droid"), ("mixin", nil, "claude", "mixin:claude"),
                      ("mixin", nil, nil, "mixin:"), (nil, "x", nil, "mixin:")] as [(String?, String?, String?, String)])
    func requirementEntry(kind: String?, name: String?, requires: String?, entry: String) {
        var info = KitInspection()
        info.kind = kind
        info.name = name
        info.requires = requires.map { KitInspection.Requires(agent: $0) }
        #expect(KitStore.requirementEntry(info) == entry)
    }

    @Test("An agent's own create reference is never also a --kit")
    func ownCreateReferenceDropped() {
        #expect(KitStore.kits(["claude", "sandshell-claude"], for: .claude) == ["sandshell-claude"])
    }

    @Test("Duplicate refs are kept, not collapsed", .tags(.kitStoreEdgeCase))
    func duplicatesKept() {
        let refs = ["sandshell-claude", "sandshell-codex", "sandshell-claude"]
        #expect(KitStore.kits(refs, for: .claude) == ["sandshell-claude", "sandshell-claude"])
        #expect(KitStore.kits(refs, for: .codex) == ["sandshell-codex"])
    }
}

// MARK: - spec.yaml metadata

/// Each test gets its own kit folder under the temporary directory; `deinit` removes it.
final class KitStoreSpecTests {
    let kit: URL

    init() throws {
        kit = FileManager.default.temporaryDirectory
            .appendingPathComponent("SandshellKitStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: kit, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: kit)
    }

    func writeSpec(_ lines: [String], lineEnding: String) throws {
        let text = lines.joined(separator: lineEnding) + lineEnding
        try Data(text.utf8).write(to: kit.appendingPathComponent("spec.yaml"))
    }

    @Test("displayName and description are read whatever the line endings", arguments: ["\n", "\r\n", "\r"])
    func readsTopLevelNameAndDescription(lineEnding: String) throws {
        try writeSpec(["schemaVersion: \"1\"", "kind: mixin", "displayName: GitHub SSH",
                       "description: 'Forwards the SSH agent'", "commands:", "  - echo hi"],
                      lineEnding: lineEnding)

        let spec = KitStore.parseSpec(at: kit.path)

        #expect(spec.displayName == "GitHub SSH")
        #expect(spec.summary == "Forwards the SSH agent", "Quotes are stripped, and no later line leaks in")
    }

    @Test("A folder without spec.yaml has no metadata", .tags(.kitStoreEdgeCase))
    func missingSpecHasNoMetadata() {
        let spec = KitStore.parseSpec(at: kit.path)
        #expect(spec.displayName == nil)
        #expect(spec.summary == nil)
    }
}
