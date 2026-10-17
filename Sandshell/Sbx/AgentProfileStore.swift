import Foundation
import Synchronization

/// Display identity for a custom agent — one introduced by a `kind: sandbox`
/// kit (sbx names the sandbox's agent after the kit's `name`). Builtins keep
/// their brand look in `AgentStyle`; this only covers agents sbx doesn't ship.
/// Stored app-globally (like `RootProfile`) so an agent looks the same in
/// every window.
struct AgentProfile: Codable, Hashable, Identifiable {
    /// The agent identity (`AgentKind.rawValue`) — the kit's `name`.
    var agent: String
    var displayName: String
    var icon: String        // SF Symbol name
    var colorHex: String
    /// The kit that defines the agent: the first positional of `sbx create`.
    var kitRef: String?
    var summary: String?
    /// The kit's own `sandbox.image`, for display.
    var image: String?
    /// The kit's `sandbox.entrypoint`: what a terminal session runs (via
    /// `sbx exec`, which doesn't apply the entrypoint itself).
    var entrypoint: [String]?

    var id: String { agent }
    var kind: AgentKind { AgentKind(rawValue: agent) }

    /// Curated icon choices for the picker (the full SF catalog is one click away).
    static let symbols = [
        "cpu", "brain", "brain.head.profile", "sparkles", "wand.and.stars", "atom",
        "bolt.fill", "hammer.fill", "wrench.and.screwdriver.fill", "terminal.fill",
        "curlybraces", "ladybug.fill", "leaf.fill", "flame.fill", "star.fill", "cube.fill",
    ]

    /// Badge palette, auto-assigned in order to newly registered agents. Picked
    /// to stay clear of the builtin brand colors (Claude orange, Codex green,
    /// Gemini blue, Shell slate) and to carry a white glyph.
    static let palette = [
        "8b5cf6", "db2777", "d97706", "0d9488", "dc2626",
        "4f46e5", "65a30d", "0891b2", "9333ea", "ea580c",
    ]
}

/// App-global registry of custom agent profiles, backed by `UserDefaults`.
/// Read from nonisolated code (`AgentKind.displayName`), so it keeps a
/// decoded copy behind a mutex rather than decoding JSON per lookup.
enum AgentProfileStore {
    private static let key = "agentProfiles"
    private static let cache = Mutex<[AgentProfile]?>(nil)

    static var all: [AgentProfile] {
        cache.withLock { cached in
            if let cached { return cached }
            let decoded = UserDefaults.standard.data(forKey: key)
                .flatMap { try? JSONDecoder().decode([AgentProfile].self, from: $0) } ?? []
            cached = decoded
            return decoded
        }
    }

    /// Posted (on the caller's thread) after any profile is added, edited or removed.
    static let didChange = Notification.Name("AgentProfileStoreDidChange")

    private static func save(_ list: [AgentProfile]) {
        cache.withLock { $0 = list }
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: key)
        }
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    static func profile(for agent: AgentKind) -> AgentProfile? {
        all.first { $0.agent == agent.rawValue }
    }

    static func upsert(_ profile: AgentProfile) {
        var list = all
        if let i = list.firstIndex(where: { $0.agent == profile.agent }) { list[i] = profile } else { list.append(profile) }
        save(list)
    }

    static func remove(_ agent: String) {
        save(all.filter { $0.agent != agent })
    }

    /// The next unused palette slot (cycling once every slot is taken).
    static func nextColor() -> String {
        let used = Set(all.map(\.colorHex))
        return AgentProfile.palette.first { !used.contains($0) }
            ?? AgentProfile.palette[all.count % AgentProfile.palette.count]
    }

    /// Whether a string can be an agent identity: it ends up in a container
    /// name (`<slug>-<agent>`), so sbx's name rules apply.
    static func isValidName(_ name: String) -> Bool {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-")
        return name.count >= 2 && name.allSatisfy { allowed.contains($0) } && !name.hasPrefix("-")
    }

    enum RegistrationError: LocalizedError {
        case unreadable(String)
        case notSandboxKit(String, kind: String?)
        case badName(String)
        case builtin(String)

        var errorDescription: String? {
            switch self {
            case .unreadable(let ref):
                "Couldn’t read the kit “\(ref)” (sbx kit inspect failed)."
            case .notSandboxKit(let ref, let kind):
                "“\(ref)” is a \(kind ?? "mixin") kit, not an agent. Agent kits declare kind: sandbox — add mixins under Kits instead."
            case .badName(let name):
                "The kit’s name “\(name)” can’t be used as an agent name (lowercase letters, digits and hyphens only)."
            case .builtin(let name):
                "“\(name)” is a built-in agent."
            }
        }
    }

    /// Register (or refresh) the agent a `kind: sandbox` kit defines, reading
    /// its name, display name and image with `sbx kit inspect --json`. A
    /// refresh keeps the user's icon/color/name edits. On the main actor, like
    /// every other write, so nothing lands between its read and its save.
    @MainActor @discardableResult
    static func register(kitRef ref: String) async throws -> AgentProfile {
        let ref = ref.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let info = await SbxClient.shared.kitInspect(ref) else { throw RegistrationError.unreadable(ref) }
        guard info.kind == "sandbox" else { throw RegistrationError.notSandboxKit(ref, kind: info.kind) }
        guard let name = info.name, isValidName(name) else { throw RegistrationError.badName(info.name ?? "") }
        guard !AgentKind(rawValue: name).isBuiltin else { throw RegistrationError.builtin(name) }
        var profile = profile(for: AgentKind(rawValue: name)) ?? AgentProfile(
            agent: name, displayName: info.displayName ?? name, icon: "cpu", colorHex: nextColor())
        profile.kitRef = ref
        profile.summary = info.description
        profile.image = info.sandbox?.image
        profile.entrypoint = info.sandbox?.entrypoint
        upsert(profile)
        return profile
    }
}
