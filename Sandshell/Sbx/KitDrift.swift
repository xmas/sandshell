import Foundation

/// A sandbox whose actual kit list (`sbx inspect --json`) differs from the
/// workspace's configured kits — typically a kit added by hand with
/// `sbx kit add`, which the next Sandshell rebuild would silently drop.
struct KitDrift: Equatable {
    var containerName: String
    /// Kits in the container but not in the workspace config (refs as sbx reports them).
    var extra: [String]
    /// Configured kits the container doesn't have (refs as configured).
    var missing: [String]

    var isEmpty: Bool { extra.isEmpty && missing.isEmpty }

    /// Identity for "dismissed" bookkeeping: changes when the drift does.
    var signature: String { containerName + "|" + extra.joined(separator: ",") + "|" + missing.joined(separator: ",") }

    /// Compare refs after `normalize`, so a relative path, a symlinked path or
    /// a `docker.io/…:latest` spelling doesn't read as drift.
    static func compute(containerName: String, actual: [String], configured: [String], root: URL) -> KitDrift {
        let have = Set(actual.map { normalize($0, root: root) })
        let want = Set(configured.map { normalize($0, root: root) })
        return KitDrift(containerName: containerName,
                        extra: actual.filter { !want.contains(normalize($0, root: root)) },
                        missing: configured.filter { !have.contains(normalize($0, root: root)) })
    }

    /// Canonical form of a kit reference for comparison. Local paths resolve
    /// against the workspace root (where `sbx create` runs) with symlinks and a
    /// trailing slash removed; Docker Hub refs get the implicit registry and tag.
    static func normalize(_ ref: String, root: URL) -> String {
        let t = ref.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("/") || t.hasPrefix("~") || t == "." || t == ".." || t.hasPrefix("./") || t.hasPrefix("../") {
            let expanded = (t as NSString).expandingTildeInPath
            let url = expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded) : root.appendingPathComponent(expanded)
            return url.standardizedFileURL.resolvingSymlinksInPath().path
        }
        guard !t.contains("://"), !t.hasPrefix("git+") else { return t }
        var oci = t
        for prefix in ["docker.io/", "index.docker.io/", "registry-1.docker.io/"] where oci.hasPrefix(prefix) {
            oci = String(oci.dropFirst(prefix.count))
        }
        let last = oci.split(separator: "/").last.map(String.init) ?? oci
        if !last.contains(":"), !oci.contains("@") { oci += ":latest" }
        return oci
    }

    /// Additions-only change: the refs in `new` that `old` lacks, when nothing
    /// was removed (so `sbx kit add` can apply them in place). Nil otherwise.
    static func additionsOnly(from old: [String], to new: [String]) -> [String]? {
        let added = new.filter { !old.contains($0) }
        guard !added.isEmpty, old.allSatisfy(new.contains) else { return nil }
        return added
    }
}
