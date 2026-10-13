import Foundation

/// A kit published in a Docker Hub namespace (the public `sbx` namespace holds
/// the official kits, `*-kit`, alongside their `*-image` base images).
struct HubKit: Identifiable, Hashable {
    var namespace: String
    var name: String            // repository name, e.g. "github-ssh-kit"
    var description: String
    var pullCount: Int
    var lastUpdated: Date?

    var id: String { ref }
    /// The reference to pass to `sbx create --kit`.
    var ref: String { "docker.io/\(namespace)/\(name):latest" }
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
        var url: URL? = URL(string: "https://hub.docker.com/v2/namespaces/\(namespace)/repositories/?page_size=100")
        var kits: [HubKit] = []
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()
        var pages = 0
        while let u = url, pages < 5 {
            pages += 1
            let (data, response) = try await URLSession.shared.data(from: u)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                throw HubError(message: "Docker Hub returned HTTP \(http.statusCode) for \(namespace).")
            }
            let page = try JSONDecoder().decode(Page.self, from: data)
            for r in page.results where r.name.hasSuffix("-kit") {
                let date = r.last_updated.flatMap { iso.date(from: $0) ?? isoPlain.date(from: $0) }
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
        return t.replacingOccurrences(of: "\n", with: " ")
    }
}

/// What `sbx kit inspect <ref> --json` tells us about a kit (schema v1 or v2;
/// every field optional so a newer spec can't break decoding).
struct KitInspection: Decodable {
    var name: String?
    var displayName: String?
    var description: String?
    var permissions: Permissions?
    var caps: Permissions?           // schema v1 spelling
    var ports: [Port]?
    var agentInstructions: AgentInstructions?

    struct Permissions: Decodable {
        struct Network: Decodable { var allow: [String]?; var deny: [String]? }
        var network: Network?
    }
    struct Port: Decodable {
        var container: Int?
        var proto: String?
        var name: String?
        enum CodingKeys: String, CodingKey { case container, name, proto = "protocol" }
    }
    struct AgentInstructions: Decodable { var content: String? }

    var networkAllow: [String] { (permissions ?? caps)?.network?.allow ?? [] }
    var title: String? { displayName ?? name }
}
