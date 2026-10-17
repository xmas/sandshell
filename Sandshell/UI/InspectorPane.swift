import SwiftUI

/// The per-root inspector panes. All app settings live here — there is no
/// separate global Settings window.
enum InspectorPane: String, CaseIterable, Identifiable {
    case general, sandboxes, folders, mounts, kits, agents, mcp, git, terminal
    var id: String { rawValue }
    var title: String {
        switch self {
        case .mcp: "MCP"
        default: rawValue.capitalized
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape.fill"
        case .sandboxes: "shippingbox.fill"
        case .folders: "folder.fill"
        case .mounts: "externaldrive.fill"
        case .kits: "cube.fill"
        case .agents: "person.crop.square.fill"
        case .mcp: "point.3.connected.trianglepath.dotted"
        case .git: "arrow.triangle.branch"
        case .terminal: "terminal.fill"
        }
    }

    /// The tab's tint.
    var color: Color {
        switch self {
        case .general: .gray
        case .sandboxes: .brown
        case .folders: .indigo
        case .mounts: .blue
        case .kits: .green
        case .agents: .pink
        case .mcp: .purple
        case .git: .orange
        case .terminal: .teal
        }
    }
}
