import SwiftUI

/// A sample of a terminal palette: a prompt and its 16 ANSI colors.
struct PalettePreview: View {
    let palette: TerminalPalette
    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 8).fill(Color(palette.bgColor))
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text("›").foregroundStyle(Color(palette.fgColor))
                    Text("sandshell").foregroundStyle(Color(palette.dimColor))
                    Text("session").foregroundStyle(Color(palette.greenColor))
                }
                .font(.mark(12, monospaced: true))

                HStack(spacing: 5) {
                    ForEach(0..<16, id: \.self) { i in
                        Circle().fill(Color(NSColor.hex(palette.ansi[i]))).frame(width: 11, height: 11)
                    }
                }
            }
            .padding(.horizontal, 14)
        }
        .overlay { RoundedRectangle(cornerRadius: 8).stroke(.quaternary) }
        // A sample of the palette, nothing to read out.
        .accessibilityHidden(true)
    }
}
