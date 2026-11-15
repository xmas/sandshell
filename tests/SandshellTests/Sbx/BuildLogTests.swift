import Foundation
import Testing
@testable import Sandshell

// Tests for `BuildLog` (Sbx/BuildLog.swift): sbx's create progress, read in
// pieces from its output files and kept for the pane's build log.

struct BuildLogTests {
    /// What `sbx create` (0.48, progress on, stdout not a terminal) printed for a shell sandbox with one kit.
    static let createOutput = """

    SANDBOX
      Name:       probe
      Agent:      shell
      Kit:        docker.io/sbx/github-ssh:latest

    IMAGE
      ○ image — pulling…
          1560168ac5fb already present
          5bbe8539825f already present
      ✓ image — ready

    AGENT
        running 1 install command
          ✓ mkdir -p /home/agent/.ssh (kit=github-ssh, user=0, 233ms)

      ✓ Created sandbox probe

    """

    struct Splitting {
        @Test("Lines come out once their newline arrives, however the bytes are cut")
        func linesAcrossChunks() {
            var splitter = BuildLog.LineSplitter()
            #expect(splitter.feed(Data("IMA".utf8)) == [])
            #expect(splitter.feed(Data("GE\n  ○ image".utf8)) == ["IMAGE"])
            #expect(splitter.feed(Data(" — pulling…\n\n".utf8)) == ["  ○ image — pulling…", ""])
            #expect(splitter.flush() == [])
        }

        @Test("A character split between chunks comes out whole")
        func multibyteAcrossChunks() {
            var splitter = BuildLog.LineSplitter()
            let bytes = Array("✓ ready\n".utf8)
            #expect(splitter.feed(Data(bytes[..<1])) == [])
            #expect(splitter.feed(Data(bytes[1...])) == ["✓ ready"])
        }

        @Test("A last line without its newline comes out at the end")
        func flushesTheRest() {
            var splitter = BuildLog.LineSplitter()
            #expect(splitter.feed(Data("one\ntwo".utf8)) == ["one"])
            #expect(splitter.flush() == ["two"])
            #expect(splitter.flush() == [], "Nothing twice")
        }

        @Test("A redrawn line keeps its last state; CRLF just ends a line")
        func carriageReturns() {
            var splitter = BuildLog.LineSplitter()
            #expect(splitter.feed(Data("pulling 10%\rpulling 60%\rpulling 100%\nnext\r\n".utf8))
                    == ["pulling 100%", "next"])
        }

        @Test("Terminal escapes are dropped", arguments: [
            ("\u{1B}[32m✓\u{1B}[0m image — ready", "✓ image — ready"),
            ("\u{1B}[2K\u{1B}[1Gpulling", "pulling"),
            ("\u{1B}[?25lplain", "plain"),
            ("no escapes", "no escapes"),
        ])
        func escapes(raw: String, clean: String) {
            #expect(BuildLog.LineSplitter.stripEscapes(raw) == clean)
        }
    }

    @Test("The latest marked step, without its mark")
    func latestStep() {
        var log = BuildLog()
        #expect(log.step == nil)
        log.append(["IMAGE", "  ○ image — pulling…", "      1560168ac5fb already present"])
        #expect(log.step == "image — pulling…")
        log.append(["  ✓ image — ready"])
        #expect(log.step == "image — ready")
    }

    @Test("All of a create's output is kept, minus the blank lines it starts with")
    func wholeCreate() {
        var splitter = BuildLog.LineSplitter()
        var log = BuildLog()
        log.append(splitter.feed(Data(Self.createOutput.utf8)) + splitter.flush())
        #expect(log.lines.first == "SANDBOX")
        #expect(log.lines.contains("      5bbe8539825f already present"))
        #expect(log.step == "Created sandbox probe")
        #expect(log.text.hasPrefix("SANDBOX\n  Name:       probe\n"))
    }

    @Test("Past the limit, the oldest lines go")
    func capped() throws {
        var log = BuildLog()
        log.append((1...BuildLog.limit).map { "layer \($0)" })
        #expect(log.dropped == 0)
        log.append(["layer \(BuildLog.limit + 1)", "layer \(BuildLog.limit + 2)"])
        #expect(log.lines.count == BuildLog.limit)
        #expect(log.dropped == 2)
        #expect(log.lines.first == "layer 3")
        #expect(try #require(log.lines.last) == "layer \(BuildLog.limit + 2)")
    }
}

/// `BuildProgress`: sbx's sections as the steps of a build.
struct BuildProgressTests {
    private var lines: [String] { BuildLogTests.createOutput.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) }

    @Test func aFinishedBuildIsEveryStepDone() {
        let p = BuildProgress(lines)
        #expect(p.created)
        #expect(p.steps.map(\.heading) == ["SANDBOX", "IMAGE", "AGENT"])
        #expect(p.steps.map(\.title) == ["Settings", "Image", "Install"])
        #expect(p.steps.allSatisfy { $0.state == .done })
        #expect(p.steps[1].layers == 2)
        #expect(p.steps[1].detail == "2 layers")
    }

    @Test func midPullTheImageIsUnderWayAndInstallIsToCome() {
        let cut = Array(lines.prefix { !$0.contains("image — ready") })
        let p = BuildProgress(cut)
        #expect(!p.created)
        #expect(p.steps.map(\.state) == [.done, .current, .waiting])
        #expect(p.steps.last?.title == "Install")
    }

    @Test func aFailedStepStopsThere() {
        let p = BuildProgress(["SANDBOX", "  Name:   x", "IMAGE", "  ✗ image — pull failed: unauthorized"])
        #expect(p.steps.map(\.state) == [.done, .failed])
    }

    @Test func linesBeforeAnyHeadingAreTheirOwnStep() {
        let p = BuildProgress(["Removing old sandbox agate…", "", "SANDBOX", "  Name: agate"])
        #expect(p.steps.first?.title == "Starting")
        #expect(p.steps.first?.state == .done)
        #expect(p.steps[1].state == .current)
    }

    @Test(arguments: [("IMAGE", true), ("AGENT", true), ("  IMAGE", false), ("Image", false), ("OK", false),
                      ("4DF3940045ED", false)])
    func headings(line: String, isHeading: Bool) {
        // A digest in capitals has digits: headings are letters and spaces.
        #expect(BuildProgress.isHeading(line) == isHeading)
    }

    @Test func theLatestLayersSize() {
        #expect(BuildProgress.size("      3a1ff53c2c55 downloaded  360.5 MB") == "360.5 MB")
        #expect(BuildProgress.size("      3a1ff53c2c55 already present") == nil)
    }
}

/// `BuildLogTypesetter`: sbx's lines set to be read, every word kept.
struct BuildLogTypesetterTests {
    @Test func valuesLineUpDigestsShortenHomeIsTilde() {
        let digest = "4df3940045ede4e8c55c8dc24d1b434467ddc6f5b71e8a8ca5b6659caac50509"
        let pieces = BuildLogTypesetter.pieces([
            "  CPU:        11",
            "  Image:      docker.io/sbx/claude@sha256:\(digest)",
            "    Source:   \(NSHomeDirectory())/Library/x",
        ])
        #expect(pieces[0] == .pair(key: "CPU", value: "11", indent: 2, full: nil))
        guard case .pair(let key, let value, _, let full) = pieces[1] else { Issue.record("a pair"); return }
        #expect(key == "Image")
        #expect(value == "docker.io/sbx/claude@sha256:4df39400…c50509")
        #expect(full?.contains(digest) == true, "the whole digest on hover")
        guard case .pair(_, let source, let indent, _) = pieces[2] else { Issue.record("a pair"); return }
        #expect(source == "~/Library/x" && indent == 4)
    }

    @Test func aRunOfLayersIsOneLine() {
        let pieces = BuildLogTypesetter.pieces([
            "  ○ image — pulling…",
            "      4df3940045ed downloaded",
            "      fb0060493627 downloaded",
            "      3a1ff53c2c55 downloaded  360.5 MB",
            "  ✓ image — ready",
        ])
        #expect(pieces.count == 3)
        #expect(pieces[1] == .layers(count: 3, latest: "3a1ff53c2c55 downloaded  360.5 MB", indent: 6))
        #expect(pieces[2] == .text("✓ image — ready", indent: 2, full: nil))
    }
}
