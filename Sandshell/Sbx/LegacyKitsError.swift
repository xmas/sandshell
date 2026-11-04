import Foundation

/// A workspace's kits include ones in sbx's older format (v1/v2), which sbx
/// won't put in a sandbox beside v3 kits — and every agent is a v3 kit since
/// sbx 0.51. Thrown before `sbx create` when the kits' formats are known, and
/// made from sbx's own refusal when they weren't. The launch failure offers
/// to turn them off (`WorkspaceController.turnOffKits`).
struct LegacyKitsError: LocalizedError, Equatable {
    /// The workspace's kit references sbx can't use here.
    let refs: [String]

    var errorDescription: String? {
        let lines = refs.map { ref in
            let name = KitStore.displayName(ref)
            return name == ref ? "• \(ref)" : "• \(name) — \(ref)"
        }
        let subject = refs.count == 1 ? "This kit is" : "These kits are"
        let fix = refs.count == 1 ? "Turn it off for this workspace, or use a v3 version of it"
                                  : "Turn them off for this workspace, or use v3 versions of them"
        return "\(subject) in sbx’s older kit format (v1/v2):\n\n" + lines.joined(separator: "\n")
            + "\n\nsbx can’t put an older kit in the same sandbox as v3 kits, and every agent is a v3 kit now. "
            + "\(fix) (its spec.yaml starting “# syntax=docker/sandbox-kit:3”)."
    }

    /// sbx's refusal — "cannot mix v3 kits with v1/v2 kits in one sandbox; …
    /// (v3: claude, git-ssh-sign; v1/v2: claude-sbx-statusline). …" — gives
    /// the v1/v2 kits' names; nil for any other message.
    static func legacyNames(inSbxError message: String) -> [String]? {
        guard message.contains("cannot mix v3 kits with v1/v2 kits"),
              let range = message.range(of: "v1/v2: ", options: .backwards) else { return nil }
        let rest = message[range.upperBound...]
        let list = rest.prefix { $0 != ")" && $0 != "\n" }
        let names = list.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return names.isEmpty ? nil : names
    }

    /// Which of `refs` sbx named: by the spec name `sbx kit inspect` gave, or
    /// the name the reference itself suggests.
    static func refs(named names: [String], in refs: [String],
                     sbxName: (String) -> String = KitStore.sbxName) -> [String] {
        refs.filter { ref in
            let candidates = [sbxName(ref), KitStore.derivedName(ref)]
            return names.contains { name in candidates.contains(name) || candidates.contains(name.replacing(/-kit$/, with: "")) }
        }
    }

    /// sbx's refusal as this error, the named kits marked as older-format so
    /// the next attempt names them before building. Nil when it isn't that
    /// refusal or none of `kits` matches.
    static func from(sbxError error: Error, kits: [String]) -> LegacyKitsError? {
        from(message: error.localizedDescription, kits: kits)
    }

    static func from(message: String, kits: [String]) -> LegacyKitsError? {
        guard let names = legacyNames(inSbxError: message) else { return nil }
        let matched = Self.refs(named: names, in: kits)
        guard !matched.isEmpty else { return nil }
        KitStore.setLegacy(matched)
        return LegacyKitsError(refs: matched)
    }
}
