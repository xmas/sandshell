/// The setup steps shown for a new workspace.
enum SetupStep: Int, CaseIterable {
    case folder, look, mounts, kits
    var title: String {
        switch self {
        case .folder: "Folder"
        case .look: "Look"
        case .mounts: "Mounts"
        case .kits: "Kits"
        }
    }
}
