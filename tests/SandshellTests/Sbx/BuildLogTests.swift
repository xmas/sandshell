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
      Kit:        docker.io/sbx/github-ssh-kit:latest

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
