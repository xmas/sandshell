import Foundation

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
    /// `sandbox` (defines an agent; the create positional) or `mixin` (`--kit`).
    var kind: String?
    var sandbox: SandboxSpec?
    /// A mixin made for one agent only (`requires: { agent: claude }`).
    var requires: Requires?
    struct Requires: Decodable { var agent: String? }

    struct SandboxSpec: Decodable { var image: String?; var entrypoint: [String]? }
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
