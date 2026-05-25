import Foundation

/// Thread-safe, Sendable-safe ISO8601 formatters shared across the entire app.
public enum AmiraDateFormatter {
    /// Standard ISO8601 (no fractional seconds).
    public nonisolated(unsafe) static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// ISO8601 with fractional seconds (for log/audit timestamps).
    public nonisolated(unsafe) static let iso8601Full: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Compact ISO8601 with colons replaced — safe for file system paths.
    public static func compact(_ date: Date) -> String {
        iso8601.string(from: date).replacingOccurrences(of: ":", with: "-")
    }

    /// Parse that tries full first, then basic.
    public static func parse(_ value: String) -> Date? {
        iso8601Full.date(from: value) ?? iso8601.date(from: value)
    }
}
