import SwiftUI

/// The setup wizard's navigation: Default (first launch) or Cancel, Back, and
/// Next — or Open Workspace for a known folder, Create Workspace at the end.
struct SetupWizardFooter: View {
    let step: SetupStep
    let welcome: Bool
    let isKnownWorkspace: Bool
    let onDefault: () -> Void
    let onCancel: () -> Void
    let onBack: () -> Void
    let onNext: () -> Void
    let onOpenExisting: () -> Void
    let onCreate: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            if welcome && step == .folder {
                Button("Default", action: onDefault)
                    .help("Create ~/Sandshell with default settings.")
            } else {
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
            }
            Spacer()
            if step != .folder {
                Button("Back", action: onBack)
            }
            if step == .kits {
                Button("Create Workspace", action: onCreate).keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            } else if step == .folder && isKnownWorkspace {
                Button("Open Workspace", action: onOpenExisting).keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            } else {
                Button("Next", action: onNext).keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
    }
}
