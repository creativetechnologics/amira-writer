import Foundation

/// Lightweight file-based log so the running app leaves a trail we can inspect
/// without having to pipe stdout from Console.app. Writes to
/// `~/Library/Logs/Amira/amira-writer.log`. Safe to call from any queue;
/// writes are serialized on a private background queue.
///
/// Also mirrors every line to stdout via `print` so the existing Console-based
/// debugging flow still works in Xcode / `log stream --process Opera`.
@available(macOS 26.0, *)
enum AppLog {
    private static let logDirectoryURL: URL = {
        let dir = FileManager.default
            .urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/Amira", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static let logFileURL: URL = logDirectoryURL.appendingPathComponent("amira-writer.log")

    private static let queue = DispatchQueue(label: "com.amira.writer.AppLog", qos: .utility)

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        f.timeZone = TimeZone.current
        return f
    }()

    /// Write a single-line log entry. Multi-line messages get newline-escaped
    /// to keep each entry on one line — easier to grep.
    static func log(_ tag: String, _ message: @autoclosure () -> String) {
        let text = message().replacingOccurrences(of: "\n", with: " ¬ ")
        let now = Date()
        let line = "[\(timestampFormatter.string(from: now))] [\(tag)] \(text)\n"
        // Mirror to stdout for Console.app / Xcode users.
        print(line, terminator: "")
        queue.async {
            append(line)
        }
    }

    /// Time a block and log its duration with a tag.
    @discardableResult
    static func time<T>(_ tag: String, _ label: String, _ body: () throws -> T) rethrows -> T {
        let start = Date()
        defer {
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            log(tag, "\(label) (\(ms) ms)")
        }
        return try body()
    }

    private static func append(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }
        if !FileManager.default.fileExists(atPath: logFileURL.path) {
            try? data.write(to: logFileURL, options: .atomic)
            return
        }
        do {
            let handle = try FileHandle(forWritingTo: logFileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            // Fallback: rewrite entire file (loses prior content if it was
            // corrupted; better than losing new events silently).
            try? data.write(to: logFileURL, options: .atomic)
        }
    }

    /// Trim log to the most-recent `maxBytes`. Called at startup to keep the
    /// file from growing without bound.
    static func rollIfLarge(maxBytes: Int = 5 * 1024 * 1024) {
        queue.async {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: logFileURL.path),
                  let size = attrs[.size] as? NSNumber,
                  size.intValue > maxBytes else { return }
            guard let handle = try? FileHandle(forReadingFrom: logFileURL) else { return }
            defer { try? handle.close() }
            let offset = UInt64(size.intValue - maxBytes / 2)
            try? handle.seek(toOffset: offset)
            let tail = (try? handle.readToEnd()) ?? Data()
            // Drop to the next newline so we don't cut mid-line.
            if let nl = tail.firstIndex(of: 0x0A) {
                let trimmed = tail.suffix(from: tail.index(after: nl))
                try? trimmed.write(to: logFileURL, options: .atomic)
            } else {
                try? tail.write(to: logFileURL, options: .atomic)
            }
        }
    }
}
