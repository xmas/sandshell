import Foundation

/// A kit published in a Docker Hub namespace (the public `sbx` namespace holds
/// the official kits, `*-kit`, alongside their `*-image` base images).
struct HubKit: Identifiable, Hashable {
    var namespace: String
    var name: String            // repository name, e.g. "github-ssh-kit"
    var description: String
    var pullCount: Int
    var lastUpdated: Date?
    /// One of Sandshell's kits (github.com/xmas/sandshell-kits), not Docker Hub's.
    var isSandshell = false

    var id: String { ref }
    /// The reference to pass to `sbx create --kit`: a kit this app bundles by
    /// its name (`KitStore.resolve`), another Sandshell kit as published.
    var ref: String {
        guard isSandshell else { return "docker.io/\(namespace)/\(name):latest" }
        return KitStore.bundledKitNames.contains(name) ? name : "\(KitStore.publishedRepository)/\(name):latest"
    }
    /// "github-ssh-kit" → "github-ssh" for display.
    var shortName: String { name.hasSuffix("-kit") ? String(name.dropLast(4)) : name }
}

/// Docker Hub's public repository listing for a namespace — no auth needed.
enum KitHub {
    static let officialNamespace = "sbx"

    struct HubError: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    private struct Page: Decodable {
        struct Repo: Decodable {
            var name: String
            var description: String?
            var pull_count: Int?
            var last_updated: String?
        }
        var count: Int?
        var next: String?
        var results: [Repo]
    }

    /// All `*-kit` repositories in `namespace`, most pulled first.
    static func fetchKits(namespace: String = officialNamespace) async throws -> [HubKit] {
        // Filtered to kits server-side: Hub refuses anonymous requests past the
        // first page (HTTP 403), and a namespace's images outnumber its kits.
        var url: URL? = URL(string: "https://hub.docker.com/v2/namespaces/\(namespace)/repositories/?page_size=100&name=-kit")
        var kits: [HubKit] = []
        var pages = 0
        while let u = url, pages < 5 {
            pages += 1
            let (data, response) = try await URLSession.shared.data(from: u)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                if pages > 1, !kits.isEmpty { break }   // keep the pages we got
                throw HubError(message: "Docker Hub returned HTTP \(http.statusCode) for \(namespace).")
            }
            let page = try JSONDecoder().decode(Page.self, from: data)
            for r in page.results where r.name.hasSuffix("-kit") {
                let date = r.last_updated.flatMap {
                    (try? Date($0, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
                        ?? (try? Date($0, strategy: .iso8601))
                }
                kits.append(HubKit(namespace: namespace, name: r.name,
                                   description: Self.cleanDescription(r.description ?? ""),
                                   pullCount: r.pull_count ?? 0, lastUpdated: date))
            }
            url = page.next.flatMap(URL.init(string:))
        }
        return kits.sorted { $0.pullCount > $1.pullCount }
    }

    /// Hub descriptions are the kit's YAML `description`; some are block-scalar
    /// markers (`|`, `>-`) with no text, which read as garbage in a list.
    static func cleanDescription(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t == "|" || t == ">" || t == ">-" || t == "|-" { return "" }
        return t.replacing("\n", with: " ")
    }
}

// MARK: Sandshell's kits

extension KitHub {
    /// Where Sandshell's kits are published (`scripts/publish-kits.sh`).
    static let sandshellRepository = "xmas/sandshell-kits"

    /// Sandshell's kits a workspace can add: those in github.com/xmas/sandshell-kits
    /// (not the always-on chat kits), else — offline, or GitHub refusing —
    /// the ones this app bundles.
    static func fetchSandshellKits() async -> [HubKit] {
        let bundled = KitStore.optionalSandshellKits.map {
            HubKit(namespace: sandshellRepository, name: $0.ref, description: $0.summary ?? "",
                   pullCount: 0, lastUpdated: nil, isSandshell: true)
        }
        struct Entry: Decodable { var name: String; var type: String }
        guard let list = URL(string: "https://api.github.com/repos/\(sandshellRepository)/contents/"),
              let (data, response) = try? await URLSession.shared.data(from: list),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let entries = try? JSONDecoder().decode([Entry].self, from: data) else { return bundled }
        let names = entries.filter { $0.type == "dir" && !$0.name.hasPrefix(".") }.map(\.name)
            .filter { name in !KitStore.sandshellKits.contains { $0.ref == name } }
        var kits: [HubKit] = []
        for name in names {
            guard let spec = URL(string: "https://raw.githubusercontent.com/\(sandshellRepository)/main/\(name)/spec.yaml"),
                  let (data, response) = try? await URLSession.shared.data(from: spec),
                  (response as? HTTPURLResponse)?.statusCode == 200 else { continue }
            let summary = specSummary(String(decoding: data, as: UTF8.self))
            kits.append(HubKit(namespace: sandshellRepository, name: name, description: summary.description,
                               pullCount: 0, lastUpdated: nil, isSandshell: true))
        }
        // A kit this app bundles that isn't published yet still shows.
        kits += bundled.filter { b in !kits.contains { $0.name == b.name } }
        return kits.sorted { $0.name < $1.name }
    }

    /// A kit spec's top-level `displayName` and `description` (plain, quoted,
    /// or a folded/literal block), without a YAML parser.
    static func specSummary(_ yaml: String) -> (displayName: String?, description: String) {
        let lines = yaml.components(separatedBy: .newlines)
        func value(_ key: String) -> String? {
            guard let i = lines.firstIndex(where: { $0.hasPrefix("\(key):") }) else { return nil }
            var rest = lines[i].dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces)
            if ["", ">", ">-", "|", "|-", ">+", "|+"].contains(rest) {
                let block = lines[(i + 1)...].prefix { $0.isEmpty || $0.hasPrefix(" ") }
                rest = block.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
            } else if rest.count >= 2, let q = rest.first, q == "\"" || q == "'", rest.last == q {
                rest = String(rest.dropFirst().dropLast())
            }
            return rest.isEmpty ? nil : rest
        }
        return (value("displayName"), cleanDescription(value("description") ?? ""))
    }
}
