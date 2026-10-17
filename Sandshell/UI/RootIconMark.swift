import SwiftUI

/// A root folder's colored icon mark (rounded square in its brand color with
/// the white SF symbol) — the same identity the sidebar header shows.
struct RootIconMark: View {
    let profile: RootProfile
    var side: CGFloat = 24

    var body: some View {
        BadgeMark(color: .hex(profile.colorHex), content: .symbol(profile.icon), side: side)
    }
}
