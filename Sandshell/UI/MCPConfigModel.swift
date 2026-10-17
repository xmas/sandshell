import Foundation
import Observation

/// Editable MCP configuration (gateway URL + the enabled server set) with dirty
/// tracking, so Settings can force an Apply/Revert choice on leaving.
@MainActor
@Observable
final class MCPConfigModel {
    var urlString: String
    var servers: [String]

    private var baselineURL: String
    private var baselineServers: [String]

    init(url: URL, servers: [String]) {
        self.urlString = url.absoluteString
        self.servers = servers
        self.baselineURL = url.absoluteString
        self.baselineServers = servers
    }

    var isDirty: Bool { urlString != baselineURL || servers != baselineServers }

    /// The entered URL if it parses to an absolute http(s) URL, else nil.
    func resolvedURL() -> URL? {
        let trimmed = urlString.trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: trimmed), let scheme = url.scheme,
              scheme == "http" || scheme == "https", url.host != nil else { return nil }
        return url
    }

    /// Whether `name` is in the enabled set — each server row's toggle.
    subscript(isEnabled name: String) -> Bool {
        get { servers.contains(name) }
        set { if newValue { add(name) } else { remove(name) } }
    }

    func add(_ name: String) {
        let s = name.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty, !servers.contains(s) else { return }
        servers.append(s)
    }

    func remove(_ name: String) { servers.removeAll { $0 == name } }

    func commitBaseline() { baselineURL = urlString; baselineServers = servers }

    func revert() { urlString = baselineURL; servers = baselineServers }
}
