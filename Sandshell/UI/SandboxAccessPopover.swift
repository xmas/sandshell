import SwiftUI

/// The panel as a popover: a fixed, modest height that scrolls, so it always
/// fits beside its chip (a too-tall popover gets slid away from its arrow).
struct SandboxAccessPopover: View {
    let access: SandboxAccess
    var body: some View {
        ScrollView { SandboxAccessView(access: access) }
            .frame(width: 400, height: 440)
    }
}
