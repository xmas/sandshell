import AppKit
import Testing
@testable import Sandshell

/// `NSColor.hex` and `hexString` (Theme/Theme.swift): every color token and
/// saved preference goes through them.
struct ColorHexTests {
    @Test(arguments: ["d97757", "1d63ed", "000000", "ffffff", "0c0d11"])
    func hexRoundTrips(hex: String) {
        #expect(NSColor.hex(hex).hexString == hex)
    }

    @Test func aLeadingHashIsIgnored() {
        #expect(NSColor.hex("#4f8bff").hexString == "4f8bff")
    }

    @Test func uppercaseDigitsRead() {
        #expect(NSColor.hex("D97757").hexString == "d97757")
    }

    @Test(.tags(.edgeCase), arguments: ["", "#", "zz", "not a color"])
    func textThatIsntHexIsBlack(text: String) {
        #expect(NSColor.hex(text).hexString == "000000")
    }

    @Test func colorIsOpaqueSRGB() {
        let color = NSColor.hex("16a34a")
        #expect(color.colorSpace == .sRGB)
        #expect(color.alphaComponent == 1)
    }
}
