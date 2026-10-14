import AppKit
import CoreServices

// MARK: - Git status

/// Working-tree status for the repo containing a folder, from the host's git
/// (session workdirs are host paths). Paths are absolute.
struct GitStatus: Sendable, Equatable {
    enum Change: Sendable, Equatable {
        case modified, added, deleted, renamed, untracked, conflicted

        var badge: String {
            switch self {
            case .modified: "M"
            case .added: "A"
            case .deleted: "D"
            case .renamed: "R"
            case .untracked: "U"
            case .conflicted: "!"
            }
        }

        var color: NSColor {
            switch self {
            case .modified: .systemOrange
            case .added, .untracked: .systemGreen
            case .deleted, .conflicted: .systemRed
            case .renamed: .systemBlue
            }
        }
    }

    var repoRoot: String?
    var branch: String?
    var changes: [String: Change] = [:]
    /// Every folder that contains a change somewhere below it.
    var dirtyFolders: Set<String> = []

    static let empty = GitStatus()

    /// `git status --porcelain -z -b` for the repo containing `folder`.
    static func load(for folder: URL) async -> GitStatus {
        await Task.detached(priority: .utility) {
            guard let top = git(["-C", folder.path, "rev-parse", "--show-toplevel"])?
                .trimmingCharacters(in: .whitespacesAndNewlines), !top.isEmpty,
                  let raw = git(["-C", top, "status", "--porcelain=v1", "-z", "-b", "--untracked-files=all"])
            else { return .empty }
            var status = GitStatus(repoRoot: top)
            var fields = raw.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)[...]
            while let entry = fields.popFirst() {
                if entry.hasPrefix("## ") {
                    status.branch = entry.dropFirst(3).split(separator: ".").first.map(String.init)
                    continue
                }
                guard entry.count > 3 else { continue }
                let x = entry[entry.startIndex], y = entry[entry.index(after: entry.startIndex)]
                let path = top + "/" + entry.dropFirst(3)
                let change: Change
                switch (x, y) {
                case ("?", "?"): change = .untracked
                case ("U", _), (_, "U"), ("A", "A"), ("D", "D"): change = .conflicted
                case ("R", _), ("C", _): change = .renamed; _ = fields.popFirst()   // -z: original path follows
                case ("A", _): change = .added
                case ("D", _), (_, "D"): change = .deleted
                default: change = .modified
                }
                status.changes[path] = change
                var dir = (path as NSString).deletingLastPathComponent
                while dir.count >= top.count, status.dirtyFolders.insert(dir).inserted {
                    dir = (dir as NSString).deletingLastPathComponent
                }
            }
            return status
        }.value
    }

    /// Run git and return stdout, or nil on failure.
    nonisolated static func git(_ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.environment = ProcessInfo.processInfo.environment.merging(["GIT_OPTIONAL_LOCKS": "0"]) { _, b in b }
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }

    /// Run a git command that changes the repo; nil on success, else git's message.
    nonisolated static func change(_ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = args
        let err = Pipe()
        p.standardOutput = FileHandle.nullDevice
        p.standardError = err
        do { try p.run() } catch { return error.localizedDescription }
        let data = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus != 0 else { return nil }
        let message = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? "git exited with status \(p.terminationStatus)" : message
    }
}

// MARK: - Hunks

/// One file's unified diff split into hunks, so a single hunk can be staged,
/// unstaged or reverted with `git apply` (the repo is on the host: session
/// workdirs are host paths mounted into the sandbox).
struct FilePatch: Equatable, Sendable {
    /// `diff --git` / `index` / `---` / `+++` lines.
    var header: [String] = []
    /// Each hunk's lines, starting with its `@@` line.
    var hunks: [[String]] = []

    var isEmpty: Bool { hunks.isEmpty }

    init(_ diff: String) {
        var lines = diff.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        for line in lines {
            if line.hasPrefix("@@") { hunks.append([line]) }
            else if hunks.isEmpty { header.append(line) }
            else { hunks[hunks.count - 1].append(line) }
        }
    }

    /// A patch holding only hunk `index` (the file header plus that hunk).
    func patch(forHunk index: Int) -> String {
        (header + hunks[index]).joined(separator: "\n") + "\n"
    }

    enum Action: String, Sendable {
        case stage, unstage, revert

        /// `git apply` flags: stage → index; unstage → index, reversed;
        /// revert → working tree, reversed.
        var applyArgs: [String] {
            switch self {
            case .stage: ["--cached"]
            case .unstage: ["--cached", "-R"]
            case .revert: ["-R"]
            }
        }
    }

    /// Apply hunk `index` in `repo`; nil on success, else git's message.
    func apply(_ action: Action, hunk index: Int, repo: String) async -> String? {
        let patch = patch(forHunk: index)
        return await Task.detached(priority: .userInitiated) {
            let file = FileManager.default.temporaryDirectory
                .appendingPathComponent("sandshell-hunk-\(UUID().uuidString).patch")
            do { try patch.write(to: file, atomically: true, encoding: .utf8) } catch { return error.localizedDescription }
            defer { try? FileManager.default.removeItem(at: file) }
            return GitStatus.change(["-C", repo, "apply"] + action.applyArgs + ["--whitespace=nowarn", file.path])
        }.value
    }
}

// MARK: - File tree

/// A file or folder in the Files pane. Children load lazily and are reused
/// across refreshes (by URL), so NSOutlineView keeps its expansion state.
@MainActor
final class FileNode: NSObject {
    let url: URL
    let isDirectory: Bool
    var name: String { url.lastPathComponent }
    private(set) var children: [FileNode]?

    /// Hidden from the tree (VCS internals and Finder litter only — dotfiles show).
    static let ignored: Set<String> = [".git", ".DS_Store"]

    init(url: URL, isDirectory: Bool) {
        self.url = url
        self.isDirectory = isDirectory
    }

    var isLoaded: Bool { children != nil }

    func loadChildren() {
        guard isDirectory else { return }
        let fm = FileManager.default
        let urls = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey],
                                                 options: [])) ?? []
        let old = Dictionary((children ?? []).map { ($0.url, $0) }, uniquingKeysWith: { a, _ in a })
        children = urls
            .filter { !Self.ignored.contains($0.lastPathComponent) }
            .map { u in
                let dir = (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                if let existing = old[u], existing.isDirectory == dir { return existing }
                return FileNode(url: u, isDirectory: dir)
            }
            .sorted { a, b in
                if a.isDirectory != b.isDirectory { return a.isDirectory }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
    }

    /// Re-list every folder that's been loaded (after a file-system change).
    func reloadLoaded() {
        guard isLoaded else { return }
        loadChildren()
        children?.forEach { $0.reloadLoaded() }
    }
}

// MARK: - File-system watching

/// FSEvents on a folder tree; coalesces bursts (an agent writing many files)
/// into one callback per `latency`.
final class FileWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let onChange: @MainActor () -> Void

    init(path: String, latency: TimeInterval = 0.4, onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()
            DispatchQueue.main.async { MainActor.assumeIsolated { watcher.onChange() } }
        }
        stream = FSEventStreamCreate(nil, callback, &context, [path] as CFArray,
                                     FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency,
                                     FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer))
        if let stream {
            FSEventStreamSetDispatchQueue(stream, .main)
            FSEventStreamStart(stream)
        }
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit { stop() }
}
