import Foundation
#if canImport(os)
import os
#endif

/// Subsystem-scoped structured logger.
/// Writes to os.Logger (Console.app/Instruments) AND to /tmp/<subsystem>-debug.log
/// so both developer observability and agent grep workflows are supported.
public enum AmiraLogger {
    public enum Subsystem: String, CaseIterable, Sendable {
        case write = "Write"
        case score = "Score"
        case animate = "Animate"
        case mix = "Mix"
        case opera = "Opera"
        case projectKit = "ProjectKit"

        var osSubsystem: String { "com.amira.writer.\(rawValue.lowercased())" }
        var fileName: String { "/tmp/\(rawValue.lowercased())-debug.log" }
    }

    public static func log(_ subsystem: Subsystem, _ message: String) {
        let ts = AmiraDateFormatter.iso8601Full.string(from: Date())
        let line = "[\(ts)] [\(subsystem.rawValue)] \(message)\n"

        #if canImport(os)
        if #available(macOS 11.0, *) {
            let logger = Logger(subsystem: subsystem.osSubsystem, category: "default")
            logger.log("\(line, privacy: .public)")
        }
        #endif

        if let data = line.data(using: .utf8),
           let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: subsystem.fileName)) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        }
    }
}
