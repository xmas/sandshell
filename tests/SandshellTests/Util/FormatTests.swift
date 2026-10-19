import AppKit
import Foundation
import Testing
@testable import Sandshell

extension Tag {
    /// Boundaries and odd inputs for the shared formatters. File-private and
    /// uniquely named so it can't clash with tags other suites declare.
    @Tag fileprivate static var formatEdgeCase: Self
}

/// Tests for `Util/Format.swift`: `Format`, `String.tildeAbbreviated`,
/// `URL.realPath` and `NSAttributedString.diffCounts`.
struct FormatTests {

    // MARK: - Format.tokens

    struct Tokens {
        /// The pinned cases read with "." whatever this Mac's locale.
        private func tokens(_ count: Int) -> String {
            Format.tokens(count, locale: Locale(identifier: "en_US_POSIX"))
        }

        @Test(arguments: [(0, "0"), (1, "1"), (999, "999")])
        func underAThousandIsThePlainNumber(count: Int, expected: String) {
            #expect(tokens(count) == expected)
        }

        @Test(arguments: [
            (1_000, "1k"), (1_100, "1.1k"), (1_500, "1.5k"), (12_000, "12k"),
            (15_500, "15.5k"), (99_000, "99k"), (99_900, "99.9k"),
            (1_050, "1.1k"), (99_949, "99.9k"),
        ])
        func thousandsShowOneDecimalUnlessWhole(count: Int, expected: String) {
            #expect(tokens(count) == expected)
        }

        @Test(arguments: [
            (100_000, "100k"), (100_499, "100k"), (100_500, "101k"),
            (200_000, "200k"), (999_499, "999k"),
        ])
        func hundredsOfThousandsRoundToWholeThousands(count: Int, expected: String) {
            #expect(tokens(count) == expected, "From 100k up there is no decimal; halves round up")
        }

        @Test(arguments: [
            (1_000_000, "1.00M"), (1_234_567, "1.23M"), (1_250_000, "1.25M"),
            (2_000_000, "2.00M"), (999_994_999, "999.99M"),
        ])
        func millionsShowTwoDecimals(count: Int, expected: String) {
            #expect(tokens(count) == expected)
        }

        @Test(arguments: [(1_000_000_000, "1.00B"), (1_500_000_000, "1.50B")])
        func billionsShowTwoDecimals(count: Int, expected: String) {
            #expect(tokens(count) == expected)
        }

        @Test(.tags(.formatEdgeCase))
        func largestCountStillFormatsAsBillions() {
            #expect(tokens(Int.max) == "9223372036.85B", "There's no unit above B, and Int.max doesn't overflow")
        }

        @Test(.tags(.formatEdgeCase), arguments: [
            (-1, "-1"), (-1_500, "-1500"), (Int.min, "-9223372036854775808"),
        ])
        func negativeCountsAreNotAbbreviated(count: Int, expected: String) {
            #expect(tokens(count) == expected, "Anything under 1000, negatives included, prints as is")
        }

        @Test(.tags(.formatEdgeCase), arguments: [
            (999_500, "1.00M"), (999_999, "1.00M"), (999_995_000, "1.00B"), (999_999_999, "1.00B"),
        ])
        func roundingUpToTheNextUnitUsesThatUnit(count: Int, expected: String) {
            #expect(tokens(count) == expected, "The unit is picked after rounding: never \"1000k\" or \"1000.00M\"")
        }

        @Test(.tags(.formatEdgeCase), arguments: [
            (1_001, "1k"), (1_049, "1k"), (1_999, "2k"), (99_950, "100k"), (99_999, "100k"),
        ])
        func countsThatRoundToAWholeThousandDropTheDecimal(count: Int, expected: String) {
            #expect(tokens(count) == expected, "Never \"1.0k\" or \"100.0k\"")
        }

        @Test(arguments: [
            (15_500, "15,5k"), (12_000, "12k"), (200_000, "200k"), (1_250_000, "1,25M"),
            (1_500_000_000, "1,50B"), (Int.max, "9223372036,85B"),
        ])
        func decimalsUseTheLocalesSeparator(count: Int, expected: String) {
            #expect(Format.tokens(count, locale: Locale(identifier: "de_DE")) == expected,
                    "A German reader sees a decimal comma, and no grouping")
        }

        @Test(arguments: [
            (999, "٩٩٩"), (12_000, "١٢k"), (15_500, "١٥٫٥k"), (200_000, "٢٠٠k"),
            (1_250_000, "١٫٢٥M"), (1_500_000_000, "١٫٥٠B"),
        ])
        func wholeAndDecimalCountsUseTheSameDigits(count: Int, expected: String) {
            #expect(Format.tokens(count, locale: Locale(identifier: "ar@numbers=arab")) == expected,
                    "Whole counts are in the locale's digits like the decimals, so a list never mixes digit systems")
        }
    }

    // MARK: - Format.ago

    struct Ago {
        /// A fixed "now" at the reference date, so the interval is exactly the offset.
        let now = Date(timeIntervalSinceReferenceDate: 0)

        @Test(arguments: [
            (0, "just now"), (9, "just now"), (9.999, "just now"),
            (10, "10s ago"), (45, "45s ago"), (59.999, "59s ago"),
            (60, "1m ago"), (119, "1m ago"), (120, "2m ago"), (3_599, "59m ago"),
            (3_600, "1h ago"), (7_199, "1h ago"), (86_399, "23h ago"),
            (86_400, "1d ago"), (345_600, "4d ago"), (31_536_000, "365d ago"),
        ] as [(TimeInterval, String)])
        func pastDatesUseTheLargestWholeUnit(secondsAgo: TimeInterval, expected: String) {
            let date = now.addingTimeInterval(-secondsAgo)
            #expect(Format.ago(date, now: now) == expected)
        }

        @Test(.tags(.formatEdgeCase), arguments: [0.001, 1, 59, 3_600, 2_592_000] as [TimeInterval])
        func futureDatesReadAsJustNow(secondsAhead: TimeInterval) {
            let date = now.addingTimeInterval(secondsAhead)
            #expect(Format.ago(date, now: now) == "just now", "A date after now is clamped to zero seconds")
        }

        @Test(.tags(.formatEdgeCase))
        func veryOldDatesStayInDays() {
            let date = now.addingTimeInterval(-1e12)
            #expect(Format.ago(date, now: now) == "11574074d ago", "There's no unit above days")
        }

        @Test func nowDefaultsToTheCurrentTime() {
            #expect(Format.ago(Date()) == "just now", "A date taken just before the call is under 10s old")
            #expect(Format.ago(Date().addingTimeInterval(-3 * 3_600)) == "3h ago", "Measured against the current time")
        }
    }

    // MARK: - Format.relative

    struct Relative {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

        /// -3_599 and 45_000: the system's formatter truncates ("59 minutes
        /// ago", "in 12 hours") where the relative format style would round.
        @Test(arguments: [-259_200, -86_400, -3_599, -300, -45, 300, 3_600, 45_000, 604_800] as [TimeInterval])
        func usesTheSystemWordingForTheDateAgainstNow(offset: TimeInterval) {
            let date = now.addingTimeInterval(offset)
            let expected = RelativeDateTimeFormatter().localizedString(for: date, relativeTo: now)
            #expect(Format.relative(date, now: now) == expected)
        }

        @Test func pastAndFutureReadDifferently() {
            let past = Format.relative(now.addingTimeInterval(-300), now: now)
            let future = Format.relative(now.addingTimeInterval(300), now: now)
            #expect(past != future, "Five minutes ago and in five minutes must not read the same")
        }
    }

    // MARK: - Format.workTime

    struct WorkTime {
        @Test(arguments: [
            (0, "0s"), (0.001, "1s"), (0.5, "1s"), (1, "1s"), (1.2, "2s"), (59, "59s"),
        ] as [(TimeInterval, String)])
        func underAMinuteIsWholeSecondsRoundedUp(seconds: TimeInterval, expected: String) {
            #expect(Format.workTime(seconds) == expected)
        }

        @Test(arguments: [
            (59.01, "1m 0s"), (60, "1m 0s"), (61, "1m 1s"), (200, "3m 20s"), (3_599, "59m 59s"),
        ] as [(TimeInterval, String)])
        func underAnHourIsMinutesAndSeconds(seconds: TimeInterval, expected: String) {
            #expect(Format.workTime(seconds) == expected, "Seconds aren't zero-padded in the minutes form")
        }

        @Test(arguments: [
            (3_599.5, "1h 00m"), (3_600, "1h 00m"), (3_659, "1h 00m"), (3_660, "1h 01m"),
            (3_900, "1h 05m"), (7_199, "1h 59m"), (39_540, "10h 59m"),
            (86_400, "24h 00m"), (360_000, "100h 00m"),
        ] as [(TimeInterval, String)])
        func anHourOrMoreIsHoursAndPaddedMinutes(seconds: TimeInterval, expected: String) {
            #expect(Format.workTime(seconds) == expected, "Leftover seconds are dropped, minutes are two digits")
        }

        @Test(.tags(.formatEdgeCase), arguments: [
            (-0.5, "0s"), (-5, "-5s"), (-3_600, "-3600s"),
        ] as [(TimeInterval, String)])
        func negativeDurationsAreNotClampedOrSplit(seconds: TimeInterval, expected: String) {
            #expect(Format.workTime(seconds) == expected, "ceil(-0.5) is -0, which prints as 0; other negatives print as seconds")
        }
    }

    // MARK: - Format.compactWorkTime

    struct CompactWorkTime {
        @Test(arguments: [
            (1, "1s"), (1.5, "2s"), (59, "59s"),
            (59.5, "1m"), (60, "1m"), (119, "1m"), (120, "2m"), (3_599, "59m"),
            (3_599.5, "1h"), (3_600, "1h"), (7_199, "1h"), (86_400, "24h"),
        ] as [(TimeInterval, String)])
        func showsOnlyTheLargestWholeUnit(seconds: TimeInterval, expected: String) {
            #expect(Format.compactWorkTime(seconds) == expected)
        }

        @Test(.tags(.formatEdgeCase), arguments: [0, -0.5, -1, -3_600] as [TimeInterval])
        func zeroAndNegativeTimesAreNil(seconds: TimeInterval) {
            #expect(Format.compactWorkTime(seconds) == nil, "No time worked shows nothing")
        }

        @Test(.tags(.formatEdgeCase), arguments: [0.001, 0.5, 0.999] as [TimeInterval])
        func subSecondTimesAreNil(seconds: TimeInterval) {
            #expect(Format.compactWorkTime(seconds) == nil, "Nil under a second, as documented")
        }
    }

    // MARK: - String.tildeAbbreviated

    struct TildeAbbreviated {
        let home: String

        init() throws {
            home = FileManager.default.homeDirectoryForCurrentUser.path
            try #require(home.hasPrefix("/") && home.count > 1, "These tests need an absolute home folder other than /")
        }

        @Test func homeItselfIsATilde() {
            #expect(home.tildeAbbreviated == "~")
        }

        @Test(arguments: ["/", "/Code", "/Code/xmas-sandshell/README.md", "/a b/ü é.txt", "//double"])
        func pathsInsideHomeStartWithATilde(suffix: String) {
            #expect((home + suffix).tildeAbbreviated == "~" + suffix)
        }

        @Test func onlyTheLeadingHomeIsReplaced() {
            #expect((home + home).tildeAbbreviated == "~" + home)
        }

        @Test(arguments: ["", "/", "/tmp/x", "~", "~/x", "relative/path", "/private/var/tmp"])
        func pathsOutsideHomeAreUnchanged(path: String) {
            #expect(path.tildeAbbreviated == path, "Only the home folder's real path is abbreviated; a literal ~ is left alone")
        }

        @Test(.tags(.formatEdgeCase), arguments: ["2", "-old", ".backup"])
        func siblingThatSharesTheHomePrefixIsUnchanged(suffix: String) {
            let sibling = home + suffix
            #expect(sibling.tildeAbbreviated == sibling, "Only a whole leading component counts as home")
        }

        @Test(.tags(.formatEdgeCase))
        func homeFurtherInIsUnchanged() {
            let path = "/Volumes/Backup" + home + "/Code"
            #expect(path.tildeAbbreviated == path)
        }
    }

    // MARK: - URL.realPath

    struct RealPath {
        @Test(arguments: ["a/file", "a/./file", "a//file", "a/b/../file", "alias/../file", "rel/../file"])
        func existingPathsResolveLikeRealpath(relative: String) throws {
            try withSymlinkFixture { root in
                let url = fileURL(in: root, relative)
                #expect(url.realPath == root.realPath + "/a/file",
                        "realpath follows a symlink before applying .., unlike a lexical standardize")
            }
        }

        @Test(arguments: [
            ("alias", "/a/b"), ("alias/inner", "/a/b/inner"), ("rel", "/a/b"), ("rel/inner", "/a/b/inner"),
        ])
        func symlinksAreFollowed(relative: String, expectedSuffix: String) throws {
            try withSymlinkFixture { root in
                #expect(fileURL(in: root, relative).realPath == root.realPath + expectedSuffix,
                        "Absolute and relative symlinks both resolve to the folder they point at")
            }
        }

        @Test(.enabled(if: FileManager.default.temporaryDirectory.path.hasPrefix("/var/"),
                       "The temporary folder must sit under the /var symlink"))
        func varResolvesToPrivateVar() throws {
            try withSymlinkFixture { root in
                #expect(root.realPath == "/private" + root.path, "Like git, /var/… reads as /private/var/…")
            }
        }

        @Test(.tags(.formatEdgeCase))
        func missingPathFallsBackToAStandardizedPath() throws {
            try withSymlinkFixture { root in
                let resolved = fileURL(in: root, "missing/a/../b").realPath
                #expect(resolved.hasSuffix("/missing/b"))
                #expect(resolved.contains("/..") == false, "The fallback still removes dot segments")
            }
        }

        @Test(.tags(.formatEdgeCase), arguments: [
            ("alias/missing", "/a/b/missing"), ("rel/missing", "/a/b/missing"),
            ("alias/gone/deeper", "/a/b/gone/deeper"), ("alias/./gone/../missing", "/a/b/missing"),
        ])
        func missingFileStillResolvesItsFolder(relative: String, expectedSuffix: String) throws {
            try withSymlinkFixture { root in
                let missing = fileURL(in: root, relative)
                let expected = root.realPath + expectedSuffix
                #expect(missing.realPath == expected, "A deleted file still reads with its folder resolved, as git reports it")
            }
        }

        /// alias -> a/b, so alias/.. is a, not the root a lexical standardize gives.
        @Test(.tags(.formatEdgeCase), arguments: [
            ("alias/../gone", "/a/gone"), ("rel/../gone", "/a/gone"), ("alias/../b/gone", "/a/b/gone"),
            ("alias/../gone/../missing", "/a/missing"), ("a/file/../gone", "/a/gone"),
        ])
        func missingFileAppliesDotDotAfterASymlinkPhysically(relative: String, expectedSuffix: String) throws {
            try withSymlinkFixture { root in
                #expect(fileURL(in: root, relative).realPath == root.realPath + expectedSuffix,
                        "Like realpath, .. after a symlink leaves the folder the link points at")
            }
        }
    }

    // MARK: - NSAttributedString.diffCounts

    struct DiffCounts {
        @Test(arguments: [
            (0, 0, "+0 \u{2212}0"), (12, 3, "+12 \u{2212}3"), (1_000_000, 42, "+1000000 \u{2212}42"),
        ])
        func readsPlusAddedMinusRemoved(added: Int, removed: Int, expected: String) {
            #expect(NSAttributedString.diffCounts(added: added, removed: removed).string == expected)
        }

        @Test func removedCountUsesTheMinusSign() {
            let text = NSAttributedString.diffCounts(added: 1, removed: 2).string
            #expect(text.contains("\u{2212}"), "Removed lines show U+2212 MINUS SIGN")
            #expect(text.contains("-") == false, "No ASCII hyphen-minus")
        }

        /// In "+12 −3", "+12" is green and " −3" (the space included) is red.
        @Test(arguments: [
            (NSColor.systemGreen, NSRange(location: 0, length: 3)),
            (NSColor.systemRed, NSRange(location: 3, length: 3)),
        ])
        func eachCountIsColoredOverExactlyItsRun(expectedColor: NSColor, expectedRun: NSRange) {
            let counts = NSAttributedString.diffCounts(added: 12, removed: 3)
            var range = NSRange()
            let color = counts.attribute(.foregroundColor, at: expectedRun.location, longestEffectiveRange: &range,
                                         in: NSRange(location: 0, length: counts.length)) as? NSColor
            #expect(color == expectedColor)
            #expect(range == expectedRun, "Green covers exactly \"+12\", red exactly \" \u{2212}3\"")
        }

        @Test func bothCountsAreInTheCodeRole() {
            let counts = NSAttributedString.diffCounts(added: 12, removed: 3)
            verifyFont(of: counts)
        }
    }
}

// MARK: - Helpers

/// Runs `body` with a unique folder under the temporary directory, laid out as
///
///     a/file
///     a/b/inner
///     alias -> <root>/a/b   (absolute symlink)
///     rel   -> a/b          (relative symlink)
///
/// and removes the folder afterwards.
fileprivate func withSymlinkFixture(_ body: (_ root: URL) throws -> Void) throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory
        .appending(component: "SandshellFormatTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? fileManager.removeItem(at: root) }

    let folder = root.appending(path: "a/b", directoryHint: .isDirectory)
    try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data("file".utf8).write(to: root.appending(path: "a/file", directoryHint: .notDirectory))
    try Data("inner".utf8).write(to: folder.appending(path: "inner", directoryHint: .notDirectory))
    try fileManager.createSymbolicLink(at: root.appending(path: "alias", directoryHint: .notDirectory),
                                       withDestinationURL: folder)
    try fileManager.createSymbolicLink(atPath: root.path + "/rel", withDestinationPath: "a/b")
    try body(root)
}

/// A file URL for `relative` under `root`, built from the string so `.` and
/// `..` components reach `realpath` untouched.
fileprivate func fileURL(in root: URL, _ relative: String) -> URL {
    URL(fileURLWithPath: root.path + "/" + relative)
}

/// Both counts use the monospaced-digit semibold system font at `size`.
fileprivate func verifyFont(of counts: NSAttributedString, sourceLocation: SourceLocation = #_sourceLocation) {
    let expected = NSFont.role(.code)
    for index in [0, counts.length - 1] {
        let font = counts.attribute(.font, at: index, effectiveRange: nil) as? NSFont
        #expect(font == expected, "Font at \(index)", sourceLocation: sourceLocation)
    }
}
