import Foundation
import os

/// Unified logging + an on-disk mirror. Every message goes to the system console
/// (Console.app / `log stream`, filterable by the "Sandshell" subsystem) *and* is
/// appended to `~/Library/Logs/Sandshell/Sandshell.log`, which the sidebar Console
/// button opens directly (`open -a Console …` tails the file live). The on-disk
/// copy exists because Console.app can't be launched pre-filtered, so the raw log
/// is the most reliable way to see what `sbx` is doing when a build hangs.
enum Log {
    static let subsystem = Bundle.main.bundleIdentifier ?? "com.docker.sandshell"

    private static let appLogger = Logger(subsystem: subsystem, category: "app")
    private static let sbxLogger = Logger(subsystem: subsystem, category: "sbx")
    private static let wsLogger = Logger(subsystem: subsystem, category: "workspace")

    enum Category {
        case app, sbx, workspace
        var logger: Logger {
            switch self {
            case .app: Log.appLogger
            case .sbx: Log.sbxLogger
            case .workspace: Log.wsLogger
            }
        }
        var tag: String {
            switch self {
            case .app: "app"
            case .sbx: "sbx"
            case .workspace: "workspace"
            }
        }
    }

    /// The on-disk mirror (created empty on first access so Console can open it).
    static let fileURL: URL = {
        let dir = URL.libraryDirectory.appending(path: "Logs/Sandshell", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: "Sandshell.log")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        return url
    }()

    static func info(_ category: Category, _ message: @autoclosure () -> String) {
        let m = message()
        category.logger.info("\(m, privacy: .public)")
        append(category.tag, "INFO", m)
    }

    static func error(_ category: Category, _ message: @autoclosure () -> String) {
        let m = message()
        category.logger.error("\(m, privacy: .public)")
        append(category.tag, "ERROR", m)
    }

    // MARK: File mirror

    /// Lines waiting to be appended, written in order by one task.
    private static let pending: AsyncStream<String>.Continuation = {
        let (lines, continuation) = AsyncStream.makeStream(of: String.self)
        Task(priority: .utility) {
            for await line in lines {
                guard let handle = try? FileHandle(forWritingTo: fileURL) else { continue }
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: Data(line.utf8))
            }
        }
        return continuation
    }()

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    private static func append(_ tag: String, _ level: String, _ message: String) {
        pending.yield("\(stamp.string(from: Date())) [\(tag)] \(level): \(message)\n")
    }
}

/// Every `!` and `&` command you ran from a chat, for auditing what ran where:
/// `~/Library/Logs/Sandshell/commands.log` (Help ▸ Show Command Log), one JSON
/// object a line — `ran` (when, which app, where, the folder, the command, the
/// session) then `exited` (status, seconds) or `failed` (why). On the Mac,
/// outside every sandbox's mounts, so no agent can edit it; only you can read
/// it (0600). Nothing is written while the app hosts unit tests.
struct CommandLog: Sendable {
    let url: URL?

    static let shared = CommandLog(url: AppDelegate.isHostingTests ? nil
        : URL.libraryDirectory.appending(path: "Logs/Sandshell/commands.log"))

    /// One line's fields; `time` and `app` are added.
    func record(_ fields: [String: JSONValue]) {
        guard let url else { return }
        var line = fields
        line["time"] = .string(Date.now.ISO8601Format())
        line["app"] = .string(Bundle.main.bundleIdentifier ?? "?")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(JSONValue.object(line)), let url = created() else { return }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data + Data("\n".utf8))
    }

    /// The file, made (empty, yours only) if it isn't there yet — to append
    /// to, or for Console to open.
    func created() -> URL? {
        guard let url else { return nil }
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path(percentEncoded: false)) {
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            fm.createFile(atPath: url.path(percentEncoded: false), contents: nil, attributes: [.posixPermissions: 0o600])
        }
        return url
    }

    /// The lines so far, oldest first (tests, and anything that audits).
    func entries() -> [JSONValue] {
        guard let url, let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { try? JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }
    }
}
