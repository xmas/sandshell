import SwiftUI

/// Where the session runs: its sandbox, the folder (and how the sandbox sees
/// it), git — branch, worktree, ahead/behind — and the kits it was built with.
struct EnvironmentCard: View {
    let model: SessionInspectorModel
    @State private var showKits = false

    var body: some View {
        if let env = model.environment {
            VStack(alignment: .leading, spacing: 7) {
                InspectorRow(symbol: "shippingbox", title: env.sandbox, subtitle: env.sandboxState)
                    .help([env.system, env.resources].compactMap { $0 }.joined(separator: "\n"))
                if let system = env.system {
                    InspectorRow(symbol: "cpu", title: system, subtitle: env.resources)
                }
                InspectorRow(symbol: "folder", title: env.folderName, subtitle: env.folderParent)
                    .help(env.folderPath)
                InspectorRow(symbol: env.accessSymbol, title: env.access)
                if let branch = env.branch {
                    InspectorRow(symbol: "arrow.triangle.branch", title: branch) {
                        if let ahead = env.ahead, let behind = env.behind, ahead + behind > 0 {
                            Text("↑\(ahead) ↓\(behind)").foregroundStyle(.secondary).monospacedDigit()
                                .help("\(ahead) ahead, \(behind) behind \(env.upstream ?? "upstream")")
                        }
                    }
                }
                if let worktree = env.worktree {
                    InspectorRow(symbol: "square.stack.3d.down.right", title: "Worktree \(worktree)",
                                 subtitle: env.mainCheckout.map { "of \($0)" })
                }
                if let changed = env.changedFiles, changed > 0 {
                    InspectorRow(symbol: "pencil.line", title: "\(changed) changed file\(changed == 1 ? "" : "s")")
                }
                if !env.kits.isEmpty {
                    DisclosureGroup(isExpanded: $showKits) {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(env.kits, id: \.self) { kit in
                                Text(kit).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary).help(kit)
                            }
                        }
                        .padding(.leading, 27)
                    } label: {
                        InspectorRow(symbol: "puzzlepiece.extension", title: "\(env.kits.count) kit\(env.kits.count == 1 ? "" : "s")")
                    }
                }
            }
            .font(.callout)
        } else {
            ProgressView().controlSize(.small)
        }
    }
}
