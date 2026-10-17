import Foundation
import Testing
@testable import Sandshell

/// Tests for `Update/Updater.swift`: reading the Homebrew cask and comparing
/// versions, which decide whether an update is offered. `Updater` is
/// @MainActor, so its static helpers are too.
@MainActor
struct UpdaterTests {

    // MARK: - isNewer

    @Test(arguments: [
        ("0.10.0", "0.9.9", true),     // component-wise, not lexicographic
        ("0.2.28", "0.2.27", true),
        ("0.3", "0.2.99", true),
        ("1.0.1", "1.0", true),        // a missing component counts as 0
        ("0.2.27", "0.2.27", false),   // equal is not newer
        ("1.0", "1.0.0", false),
        ("0.2.26", "0.2.27", false),
        ("0.9.9", "0.10.0", false),
    ])
    func isNewerComparesNumericComponents(a: String, b: String, newer: Bool) {
        #expect(Updater.isNewer(a, than: b) == newer)
    }

    // MARK: - parseCask

    private static func cask(version: String, url: String) -> String {
        """
        cask "sandshell" do
          version "\(version)"
          sha256 "0000"

          url "\(url)"
          name "Sandshell"
        end
        """
    }

    @Test func parseCaskReadsTheVersionAndExpandsItInTheURL() throws {
        let text = Self.cask(
            version: "0.2.27",
            url: "https://github.com/xmas/homebrew-xmas/releases/download/sandshell-v#{version}/Sandshell-#{version}.dmg")
        let parsed = try #require(Updater.parseCask(text))
        #expect(parsed.version == "0.2.27")
        #expect(parsed.dmgURL?.absoluteString
            == "https://github.com/xmas/homebrew-xmas/releases/download/sandshell-v0.2.27/Sandshell-0.2.27.dmg",
            "Every #{version} is expanded")
    }

    @Test func parseCaskRejectsTheTauriAppsTags() {
        let text = Self.cask(
            version: "0.15.3",
            url: "https://github.com/xmas/homebrew-xmas/releases/download/v#{version}/Sandshell_#{version}_aarch64.dmg")
        #expect(Updater.parseCask(text) == nil, "Only sandshell-v… tags are the native app's")
    }

    @Test(.tags(.edgeCase), arguments: ["0.3.0-beta", "v0.3.0", ""])
    func parseCaskRejectsVersionsThatArentDigitsAndDots(version: String) {
        let text = Self.cask(
            version: version,
            url: "https://github.com/xmas/homebrew-xmas/releases/download/sandshell-v#{version}/Sandshell.dmg")
        #expect(Updater.parseCask(text) == nil)
    }

    @Test(.tags(.edgeCase), arguments: [
        "cask \"sandshell\" do\n  url \"https://x/sandshell-v1/S.dmg\"\nend",
        "cask \"sandshell\" do\n  version \"0.2.27\"\nend",
    ])
    func parseCaskNeedsBothAVersionAndAURL(text: String) {
        #expect(Updater.parseCask(text) == nil)
    }
}
