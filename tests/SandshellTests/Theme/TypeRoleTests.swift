import AppKit
import SwiftUI
import Testing
@testable import Sandshell

/// The type scale (Theme/Theme.swift): every chrome font is one of these roles.
/// On the main actor, and fonts compared by name and size: comparing NSFont
/// objects on the test pool once trapped (a 0.2.51 run in Xcode, while
/// CoreText freed a font on its own queue).
@MainActor
struct TypeRoleTests {
    @Test(arguments: [
        (TypeRole.title, 13), (.body, 13), (.bodyEmphasis, 13), (.meta, 11.5), (.code, 11.5), (.reading, 14),
    ] as [(TypeRole, CGFloat)])
    func eachRoleHasItsPointSize(role: TypeRole, size: CGFloat) {
        #expect(role.pointSize == size)
        #expect(NSFont.role(role).pointSize == size)
    }

    @Test(arguments: [
        (TypeRole.title, NSFont.Weight.semibold), (.body, .regular), (.bodyEmphasis, .semibold),
        (.meta, .regular), (.code, .regular), (.reading, .regular),
    ])
    func eachRoleHasItsWeight(role: TypeRole, weight: NSFont.Weight) {
        #expect(role.weight == weight)
        let expected = role == .code ? NSFont.monospacedSystemFont(ofSize: role.pointSize, weight: weight)
            : NSFont.systemFont(ofSize: role.pointSize, weight: weight)
        #expect(NSFont.role(role).fontName == expected.fontName)
    }

    /// Small, UI, reading: a title is weight, never a bigger size.
    @Test func thereAreThreeSizes() {
        #expect(Set(TypeRole.allCases.map(\.pointSize)) == [11.5, 13, 14])
        #expect(Set(TypeRole.allCases.map(\.weight)) == [.regular, .semibold])
        #expect(TypeRole.title.pointSize == TypeRole.body.pointSize)
    }

    @Test func onlyCodeIsMonospaced() {
        for role in TypeRole.allCases {
            #expect(NSFont.role(role).isFixedPitch == (role == .code), "\(role)")
        }
    }

    @Test func codeHasMonospacedDigits() {
        let font = NSFont.role(.code)
        let widths = Set("0123456789".map { String($0).size(withAttributes: [.font: font]).width })
        #expect(widths.count == 1)
    }

    @Test(arguments: TypeRole.allCases)
    func aWeightVariantKeepsTheRolesSizeAndFace(role: TypeRole) {
        let font = NSFont.role(role, weight: .semibold)
        #expect(font.pointSize == role.pointSize)
        #expect(font.isFixedPitch == (role == .code))
        let same = NSFont.role(role, weight: role.weight), plain = NSFont.role(role)
        #expect(same.fontName == plain.fontName)
        #expect(same.pointSize == plain.pointSize)
    }

    @Test(arguments: TypeRole.allCases)
    func swiftUIFontIsBuiltFromTheAppKitOne(role: TypeRole) {
        #expect(Font.role(role) == Font(NSFont.role(role) as CTFont))
        #expect(Font.role(role, weight: .semibold) == Font(NSFont.role(role, weight: .semibold) as CTFont))
        #expect(Font.role(role) != Font.role(role == .code ? .meta : .code), "Roles don't collapse into one font")
    }

    @Test(arguments: [
        (TypeRole.title, 16), (.body, 16), (.bodyEmphasis, 16), (.meta, 12), (.code, 12), (.reading, 16),
    ] as [(TypeRole, CGFloat)])
    func symbolsAreSixteenBesideBodyAndTwelveBesideMeta(role: TypeRole, size: CGFloat) {
        #expect(role.symbolPointSize == size)
    }

    @Test(arguments: [1, 4, 6] as [CGFloat])
    func aSpacerIsOnlyItsHeight(height: CGFloat) {
        #expect(NSFont.spacer(height).pointSize == height)
    }
}
