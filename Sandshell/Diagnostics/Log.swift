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
            case .app: return Log.appLogger
            case .sbx: return Log.sbxLogger
            case .workspace: return Log.wsLogger
            }
        }
        var tag: String {
            switch self {
            case .app: return "app"
            case .sbx: return "sbx"
            case .workspace: return "workspace"
            }
        }
    }

    /// The on-disk mirror (created empty on first access so Console can open it).
    static let fileURL: URL = {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/Sandshell", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("Sandshell.log")
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

    private static let queue = DispatchQueue(label: "com.docker.sandshell.log")
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    private static func append(_ tag: String, _ level: String, _ message: String) {
        let line = "\(stamp.string(from: Date())) [\(tag)] \(level): \(message)\n"
        queue.async {
            guard let data = line.data(using: .utf8),
                  let handle = try? FileHandle(forWritingTo: fileURL) else { return }
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            handle.write(data)
        }
    }
}
