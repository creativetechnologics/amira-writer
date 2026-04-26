import Foundation

// MARK: - Bracket DSL Parser
//
// Pure-Foundation parser for the `[tag: primary | k=v | k=v]` form used
// throughout the Animate / Write workspaces. Lives in ProjectKit so the
// Write importer and the round-trip tests can both reach it without
// pulling AnimateUI or WriteUI in.
//
// The parser is intentionally small and forgiving: unknown tags are kept
// (the caller decides what to do with them), unknown parameter keys are
// preserved, and quoted values lose only their surrounding quotes.

public struct BracketDSL: Equatable, Sendable {
    public var tag: String
    public var primary: String
    public var parameters: [String: String]

    public init(tag: String, primary: String, parameters: [String: String]) {
        self.tag = tag
        self.primary = primary
        self.parameters = parameters
    }
}

public enum BracketDSLParser {

    /// Parse a single `[...]` bracket. Returns `nil` if the input is not a
    /// well-formed `[tag: …]` block.
    public static func parse(_ raw: String) -> BracketDSL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let stripped = stripOuterBrackets(trimmed)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let colonIndex = stripped.firstIndex(of: ":") else { return nil }
        let tag = stripped[..<colonIndex]
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !tag.isEmpty else { return nil }

        let body = stripped[stripped.index(after: colonIndex)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let segments = splitOnPipe(body)
        guard let first = segments.first else { return nil }
        let primary = unquote(first)

        var parameters: [String: String] = [:]
        for segment in segments.dropFirst() {
            guard let eq = segment.firstIndex(of: "=") else { continue }
            let key = segment[..<eq]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let value = segment[segment.index(after: eq)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { continue }
            parameters[key] = unquote(value)
        }

        return BracketDSL(tag: tag, primary: primary, parameters: parameters)
    }

    /// Split a parameter list on `|`, respecting double-quoted segments.
    public static func splitOnPipe(_ body: String) -> [String] {
        var segments: [String] = []
        var current = ""
        var inQuotes = false
        for char in body {
            if char == "\"" {
                inQuotes.toggle()
                current.append(char)
            } else if char == "|", !inQuotes {
                segments.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
                current = ""
            } else {
                current.append(char)
            }
        }
        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty {
            segments.append(tail)
        }
        return segments
    }

    public static func stripOuterBrackets(_ raw: String) -> String {
        var s = raw
        if s.hasPrefix("[") { s.removeFirst() }
        if s.hasSuffix("]") { s.removeLast() }
        return s
    }

    public static func unquote(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("\""), s.hasSuffix("\""), s.count >= 2 {
            s.removeFirst()
            s.removeLast()
        }
        return s
    }
}
