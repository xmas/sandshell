import AppKit
import SwiftUI
import Testing
@testable import Sandshell

/// The type scale (Theme/Theme.swift): every chrome font is one of these roles.
struct TypeRoleTests {
    @Test(arguments: [
        (TypeRole.title, 15), (.body, 13), (.bodyEmphasis, 13), (.meta, 11.5), (.code, 11),
    ] as [(TypeRole, CGFloat)])
    func eachRoleHasItsPointSize(role: TypeRole, size: CGFloat) {
        #expect(role.pointSize == size)
        #expect(NSFont.role(role).pointSize == size)
    }

    @Test(arguments: [
        (TypeRole.title, NSFont.Weight.semibold), (.body, .regular), (.bodyEmphasis, .semibold),
        (.meta, .regular), (.code, .regular),
    ])
    func eachRoleHasItsWeight(role: TypeRole, weight: NSFont.Weight) {
        #expect(role.weight == weight)
        let expected = role == .code ? NSFont.monospacedSystemFont(ofSize: role.pointSize, weight: weight)
            : NSFont.systemFont(ofSize: role.pointSize, weight: weight)
        #expect(NSFont.role(role).fontName == expected.fontName)
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
        #expect(NSFont.role(role, weight: role.weight) == NSFont.role(role))
    }

    @Test(arguments: TypeRole.allCases)
    func swiftUIFontIsBuiltFromTheAppKitOne(role: TypeRole) {
        #expect(Font.role(role) == Font(NSFont.role(role) as CTFont))
        #expect(Font.role(role, weight: .semibold) == Font(NSFont.role(role, weight: .semibold) as CTFont))
        #expect(Font.role(role) != Font.role(role == .code ? .meta : .code), "Roles don't collapse into one font")
    }

    @Test(arguments: [
        (TypeRole.title, 16), (.body, 16), (.bodyEmphasis, 16), (.meta, 12), (.code, 12),
    ] as [(TypeRole, CGFloat)])
    func symbolsAreSixteenBesideBodyAndTwelveBesideMeta(role: TypeRole, size: CGFloat) {
        #expect(role.symbolPointSize == size)
    }

    @Test(arguments: [1, 4, 6] as [CGFloat])
    func aSpacerIsOnlyItsHeight(height: CGFloat) {
        #expect(NSFont.spacer(height).pointSize == height)
    }
}
