import Foundation
import ProjectKit

// MARK: - Backward Compatibility

/// Alias so existing code referencing `MiniMaxClient` still compiles.
typealias MiniMaxClient = LLMClient

// MARK: - Write-Specific Types

/// A suggestion the LLM made that can be applied to the libretto.
struct LLMSuggestion: Identifiable, Equatable, Codable {
    let id: UUID
    let originalLine: String
    let suggestedLine: String
    let lineIndex: Int        // 0-based index into the libretto lines
    /// The scene this suggestion targets (nil = active scene in scene mode).
    let scenePath: String?
    let sceneName: String?
    var applied: Bool = false

    init(originalLine: String, suggestedLine: String, lineIndex: Int, scenePath: String?, sceneName: String?) {
        self.id = UUID()
        self.originalLine = originalLine
        self.suggestedLine = suggestedLine
        self.lineIndex = lineIndex
        self.scenePath = scenePath
        self.sceneName = sceneName
    }
}

/// An undo-able action performed by the LLM on the libretto.
struct LLMUndoEntry: Identifiable {
    let id = UUID()
    let description: String
    /// Scene mode: full libretto text of the active scene before the change.
    let previousContent: String
    /// Scene mode: the specific scene path this snapshot belongs to.
    let undoScenePath: String?
    /// Show mode: per-scene snapshots before the change (path -> content).
    let sceneSnapshots: [String: String]?
    let timestamp: Date

    /// Scene mode initializer.
    init(description: String, previousContent: String, scenePath: String, timestamp: Date) {
        self.description = description
        self.previousContent = previousContent
        self.undoScenePath = scenePath
        self.sceneSnapshots = nil
        self.timestamp = timestamp
    }

    /// Show mode initializer.
    init(description: String, sceneSnapshots: [String: String], timestamp: Date) {
        self.description = description
        self.previousContent = ""
        self.undoScenePath = nil
        self.sceneSnapshots = sceneSnapshots
        self.timestamp = timestamp
    }
}

// MARK: - LLMChatSession + Write Suggestions

extension LLMChatSession {
    /// Decode Write-specific suggestions from the session's `additionalJSON` blob.
    var writeSuggestions: [LLMSuggestion]? {
        guard let data = additionalJSON else { return nil }
        return try? JSONDecoder().decode([LLMSuggestion].self, from: data)
    }

    /// Encode Write-specific suggestions into the session's `additionalJSON` blob.
    mutating func setWriteSuggestions(_ suggestions: [LLMSuggestion]?) {
        guard let suggestions else { additionalJSON = nil; return }
        additionalJSON = try? JSONEncoder().encode(suggestions)
    }
}

// MARK: - Write-Specific Suggestion Parsing

@available(macOS 14.0, *)
extension LLMClient {

    /// Scene mode: parse suggestions against a single scene's lines.
    static func parseSuggestions(from text: String, librettoLines: [String]) -> [LLMSuggestion] {
        extractSuggestPairs(from: text).compactMap { pair in
            if let lineIndex = librettoLines.firstIndex(where: {
                $0.trimmingCharacters(in: .whitespacesAndNewlines) == pair.original
            }) {
                return LLMSuggestion(originalLine: pair.original, suggestedLine: pair.replacement,
                                     lineIndex: lineIndex, scenePath: nil, sceneName: nil)
            }
            // Fuzzy match
            if !librettoLines.isEmpty {
                let best = librettoLines.enumerated().min(by: { a, b in
                    levenshteinDistance(a.element.trimmingCharacters(in: .whitespacesAndNewlines), pair.original) <
                    levenshteinDistance(b.element.trimmingCharacters(in: .whitespacesAndNewlines), pair.original)
                })
                if let best {
                    let distance = levenshteinDistance(best.element.trimmingCharacters(in: .whitespacesAndNewlines), pair.original)
                    if distance < max(pair.original.count / 2, 10) {
                        return LLMSuggestion(originalLine: pair.original, suggestedLine: pair.replacement,
                                             lineIndex: best.offset, scenePath: nil, sceneName: nil)
                    }
                }
            }
            return nil
        }
    }

    /// Show mode: expand each suggestion across ALL scenes that contain the original line.
    /// Returns one suggestion per (scene, occurrence) -- so "Firebase Ridge" in 5 scenes = 5 suggestions.
    static func parseSuggestionsAcrossScenes(
        from text: String,
        sceneFiles: [(path: String, name: String, lines: [String])]
    ) -> [LLMSuggestion] {
        let pairs = extractSuggestPairs(from: text)
        var results: [LLMSuggestion] = []

        for pair in pairs {
            for scene in sceneFiles {
                // Find ALL occurrences of the original line in this scene
                for (lineIdx, line) in scene.lines.enumerated() {
                    if line.trimmingCharacters(in: .whitespacesAndNewlines) == pair.original {
                        results.append(LLMSuggestion(
                            originalLine: pair.original,
                            suggestedLine: pair.replacement,
                            lineIndex: lineIdx,
                            scenePath: scene.path,
                            sceneName: scene.name
                        ))
                    }
                }
            }
        }
        return results
    }

    /// Simple Levenshtein distance for fuzzy line matching.
    private static func levenshteinDistance(_ s1: String, _ s2: String) -> Int {
        let a = Array(s1), b = Array(s2)
        let m = a.count, n = b.count
        if m == 0 { return n }
        if n == 0 { return m }

        var prev = Array(0...n)
        var curr = [Int](repeating: 0, count: n + 1)

        for i in 1...m {
            curr[0] = i
            for j in 1...n {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                curr[j] = min(prev[j] + 1, curr[j - 1] + 1, prev[j - 1] + cost)
            }
            swap(&prev, &curr)
        }
        return prev[n]
    }
}
