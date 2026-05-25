import Foundation
import ProjectKit

// MARK: - Direction Parser
//
// Static utility for parsing, manipulating, and querying direction markup
// embedded in lyrics text. The markup format is:
//
//   [[act.scene.subsection.direction - Description text]]
//
// Example: [[1.09.0.001 - Wide shot of the marketplace]]
//
// The lyrics string is the single source of truth. This parser extracts
// structured StoryboardDirection objects for UI consumption and provides
// utilities for stripping, renumbering, inserting, and range detection.

enum DirectionParser {

    // MARK: - Regex Pattern

    /// Matches: [[1.09.0.001 - Description text]]
    /// Groups: 1=act, 2=scene, 3=subsection, 4=direction, 5=description
    private static let pattern: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(
            pattern: #"\[\[(\d+)\.(\d+)\.(\d+)\.(\d+)\s*-\s*(.+?)\]\]"#,
            options: []
        )
    }()

    // MARK: - Parsing

    /// Parse all directions from a single song's lyrics text.
    ///
    /// - Parameters:
    ///   - lyrics: The raw lyrics string potentially containing `[[...]]` markup.
    ///   - songPath: The `relativePath` of the song (for associating directions with their source).
    /// - Returns: Array of parsed directions in the order they appear in the text.
    static func parseDirections(
        from lyrics: String,
        songPath: String
    ) -> [StoryboardDirection] {
        let nsString = lyrics as NSString
        let range = NSRange(location: 0, length: nsString.length)
        let matches = pattern.matches(in: lyrics, range: range)

        return matches.compactMap { match -> StoryboardDirection? in
            guard match.numberOfRanges == 6 else { return nil }
            guard let act = Int(nsString.substring(with: match.range(at: 1))),
                  let scene = Int(nsString.substring(with: match.range(at: 2))),
                  let subsection = Int(nsString.substring(with: match.range(at: 3))),
                  let direction = Int(nsString.substring(with: match.range(at: 4)))
            else { return nil }

            let description = nsString.substring(with: match.range(at: 5))
                .trimmingCharacters(in: .whitespaces)

            return StoryboardDirection(
                address: DirectionAddress(
                    act: act,
                    scene: scene,
                    subsection: subsection,
                    direction: direction
                ),
                descriptionText: description,
                songPath: songPath
            )
        }
    }

    /// Parse directions from all songs across the project.
    ///
    /// - Parameter librettoFiles: The array of `ProjectTextFile` from `ProjectStore`.
    /// - Returns: All directions from all songs, sorted by address.
    static func parseAllDirections(
        from librettoFiles: [ProjectTextFile]
    ) -> [StoryboardDirection] {
        librettoFiles.flatMap { file in
            parseDirections(from: file.content, songPath: file.relativePath)
        }
        .sorted { $0.address < $1.address }
    }

    // MARK: - Stripping

    /// Strip all direction markup from lyrics, returning clean libretto text.
    ///
    /// Removes `[[...]]` blocks and cleans up extra whitespace left behind.
    /// Used by pages that should not display directions (Compose, Mix, etc.)
    /// and for the Script page "hide directions" toggle.
    static func stripDirections(from lyrics: String) -> String {
        let nsString = lyrics as NSString
        let range = NSRange(location: 0, length: nsString.length)
        let stripped = pattern.stringByReplacingMatches(
            in: lyrics,
            range: range,
            withTemplate: ""
        )
        // Clean up triple+ newlines left by removed direction lines
        return stripped
            .replacingOccurrences(
                of: "\\n{3,}",
                with: "\n\n",
                options: .regularExpression
            )
    }

    // MARK: - Range Detection

    /// Find the character ranges of all direction markup in a string.
    ///
    /// Returns `[NSRange]` suitable for applying NSAttributedString attributes
    /// (e.g., hiding or styling direction text in the Script page's NSTextView).
    static func directionRanges(in lyrics: String) -> [NSRange] {
        let nsString = lyrics as NSString
        let fullRange = NSRange(location: 0, length: nsString.length)
        return pattern.matches(in: lyrics, range: fullRange).map(\.range)
    }

    // MARK: - Renumbering

    /// Renumber all directions within a single song's lyrics sequentially.
    ///
    /// Updates the direction number (4th component) starting from 001,
    /// while preserving the act/scene/subsection prefix and description text.
    ///
    /// - Parameters:
    ///   - lyrics: The song's lyrics containing direction markup.
    ///   - act: The act number to assign.
    ///   - scene: The scene number to assign.
    ///   - subsection: The subsection number to assign.
    /// - Returns: Updated lyrics with renumbered directions.
    static func renumberDirections(
        in lyrics: String,
        act: Int,
        scene: Int,
        subsection: Int
    ) -> String {
        let nsString = lyrics as NSString
        let fullRange = NSRange(location: 0, length: nsString.length)
        let matches = pattern.matches(in: lyrics, range: fullRange)

        guard !matches.isEmpty else { return lyrics }

        // Collect replacements forward (to assign sequential numbers)
        var replacements: [(NSRange, String)] = []
        var directionCounter = 1

        for match in matches {
            guard match.numberOfRanges == 6 else { continue }
            let description = nsString.substring(with: match.range(at: 5))
                .trimmingCharacters(in: .whitespaces)

            let newAddress = DirectionAddress(
                act: act,
                scene: scene,
                subsection: subsection,
                direction: directionCounter
            )
            let replacement = "[[\(newAddress.displayString) - \(description)]]"
            replacements.append((match.range, replacement))
            directionCounter += 1
        }

        // Apply replacements in reverse order to preserve character offsets
        let mutableResult = NSMutableString(string: lyrics)
        for (range, replacement) in replacements.reversed() {
            mutableResult.replaceCharacters(in: range, with: replacement)
        }

        return mutableResult as String
    }

    // MARK: - Insertion

    /// Insert a new direction at a given character position in the lyrics.
    ///
    /// - Parameters:
    ///   - lyrics: The existing lyrics text.
    ///   - characterIndex: Where to insert (clamped to string bounds).
    ///   - address: The direction address to use.
    ///   - description: The direction description text.
    /// - Returns: Updated lyrics with the new direction inserted.
    static func insertDirection(
        in lyrics: String,
        at characterIndex: Int,
        address: DirectionAddress,
        description: String
    ) -> String {
        let markup = "\n[[\(address.displayString) - \(description)]]\n"
        var mutable = lyrics
        let clampedIndex = min(max(characterIndex, 0), mutable.count)
        let idx = mutable.index(mutable.startIndex, offsetBy: clampedIndex)
        mutable.insert(contentsOf: markup, at: idx)
        return mutable
    }

    /// Compute the next available direction number for a given song.
    ///
    /// Finds the highest existing direction number in the lyrics for the
    /// specified act/scene/subsection and returns the next sequential value.
    static func nextDirectionNumber(
        in lyrics: String,
        act: Int,
        scene: Int,
        subsection: Int
    ) -> Int {
        let directions = parseDirections(from: lyrics, songPath: "")
        let matching = directions.filter {
            $0.address.act == act
            && $0.address.scene == scene
            && $0.address.subsection == subsection
        }
        let maxExisting = matching.map(\.address.direction).max() ?? 0
        return maxExisting + 1
    }

    // MARK: - Hierarchy Building

    /// Build a hierarchical grouping tree from a flat list of directions.
    ///
    /// Groups into: Act > Scene > (optional Subsection) > Directions.
    /// Used by the Storyboard page sidebar.
    ///
    /// - Parameters:
    ///   - directions: Flat sorted array of all directions.
    ///   - songDisplayNames: Optional mapping from songPath to display name for labels.
    /// - Returns: Array of top-level `DirectionGroup` nodes (one per act).
    static func buildHierarchy(
        from directions: [StoryboardDirection],
        songDisplayNames: [String: String] = [:]
    ) -> [DirectionGroup] {
        guard !directions.isEmpty else { return [] }

        let byAct = Dictionary(grouping: directions) { $0.address.act }

        return byAct.keys.sorted().map { act in
            let actDirections = byAct[act]!
            let byScene = Dictionary(grouping: actDirections) { $0.address.scene }

            let sceneGroups: [DirectionGroup] = byScene.keys.sorted().map { scene in
                let sceneDirections = byScene[scene]!
                let bySubsection = Dictionary(grouping: sceneDirections) { $0.address.subsection }

                // Look up song display name from first direction in this scene
                let songPath = sceneDirections.first?.songPath ?? ""
                let songName = songDisplayNames[songPath]

                let sceneLabel: String
                if let songName {
                    sceneLabel = String(format: "Scene %02d — %@", scene, songName)
                } else {
                    sceneLabel = String(format: "Scene %02d", scene)
                }

                if bySubsection.count == 1, bySubsection.keys.first == 0 {
                    // No subsections — flat list under scene
                    return DirectionGroup(
                        id: "act-\(act).scene-\(scene)",
                        label: sceneLabel,
                        songPath: songPath,
                        directions: sceneDirections.sorted { $0.address < $1.address }
                    )
                } else {
                    // Multiple subsections
                    let subsectionGroups: [DirectionGroup] = bySubsection.keys.sorted().map { sub in
                        DirectionGroup(
                            id: "act-\(act).scene-\(scene).sub-\(sub)",
                            label: sub == 0 ? "Main" : "Part \(sub)",
                            songPath: songPath,
                            directions: bySubsection[sub]!.sorted { $0.address < $1.address }
                        )
                    }
                    return DirectionGroup(
                        id: "act-\(act).scene-\(scene)",
                        label: sceneLabel,
                        songPath: songPath,
                        children: subsectionGroups
                    )
                }
            }

            return DirectionGroup(
                id: "act-\(act)",
                label: "Act \(act)",
                children: sceneGroups
            )
        }
    }

    // MARK: - Context Extraction

    /// Extract surrounding lyrics context around a direction's position.
    ///
    /// Returns the text immediately before and after the direction markup,
    /// useful for showing context in the Storyboard detail view.
    ///
    /// - Parameters:
    ///   - direction: The direction whose context to extract.
    ///   - lyrics: The full lyrics text containing the direction.
    ///   - lineCount: Number of lines of context before and after (default: 3).
    /// - Returns: Tuple of (before, after) context strings, or nil if not found.
    static func surroundingContext(
        for direction: StoryboardDirection,
        in lyrics: String,
        lineCount: Int = 3
    ) -> (before: String, after: String)? {
        let nsString = lyrics as NSString
        let fullRange = NSRange(location: 0, length: nsString.length)

        guard let match = pattern.firstMatch(in: lyrics, options: [], range: fullRange),
              match.numberOfRanges == 6
        else {
            // Try to find the specific direction by its markup
            guard let markupRange = (lyrics as NSString).range(of: direction.rawMarkup).toOptional() else {
                return nil
            }
            return extractContext(around: markupRange, in: lyrics, lineCount: lineCount)
        }

        // Find the specific match for this direction
        let matches = pattern.matches(in: lyrics, range: fullRange)
        for m in matches {
            guard m.numberOfRanges == 6 else { continue }
            let desc = nsString.substring(with: m.range(at: 5))
                .trimmingCharacters(in: .whitespaces)
            if desc == direction.descriptionText,
               let act = Int(nsString.substring(with: m.range(at: 1))),
               let scene = Int(nsString.substring(with: m.range(at: 2))),
               let sub = Int(nsString.substring(with: m.range(at: 3))),
               let dir = Int(nsString.substring(with: m.range(at: 4))),
               act == direction.address.act,
               scene == direction.address.scene,
               sub == direction.address.subsection,
               dir == direction.address.direction {
                return extractContext(around: m.range, in: lyrics, lineCount: lineCount)
            }
        }

        return nil
    }

    private static func extractContext(
        around range: NSRange,
        in text: String,
        lineCount: Int
    ) -> (before: String, after: String) {
        let lines = text.components(separatedBy: "\n")
        var currentOffset = 0
        var matchLineIndex: Int?

        for (index, line) in lines.enumerated() {
            let lineEnd = currentOffset + line.count + 1 // +1 for newline
            if range.location >= currentOffset && range.location < lineEnd {
                matchLineIndex = index
                break
            }
            currentOffset = lineEnd
        }

        guard let lineIdx = matchLineIndex else {
            return ("", "")
        }

        let beforeStart = max(0, lineIdx - lineCount)
        let afterEnd = min(lines.count, lineIdx + lineCount + 1)

        let beforeLines = lines[beforeStart..<lineIdx]
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let afterLines = lines[(lineIdx + 1)..<afterEnd]
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }

        return (
            before: beforeLines.joined(separator: "\n"),
            after: afterLines.joined(separator: "\n")
        )
    }
}

// MARK: - NSRange Helper

private extension NSRange {
    func toOptional() -> NSRange? {
        location == NSNotFound ? nil : self
    }
}

// MARK: - Summary Parser

/// Parses `{{{SUMMARY}}}...{{{/SUMMARY}}}` markup blocks from scene lyrics.
enum SummaryParser {
    private static let pattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"\{\{\{SUMMARY\}\}\}\s*\n?([\s\S]*?)\n?\s*\{\{\{/SUMMARY\}\}\}"#,
            options: []
        )
    }()

    /// Legacy double-brace pattern for backwards compatibility during migration.
    private static let legacyPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"\{\{SUMMARY\}\}\s*\n?([\s\S]*?)\n?\s*\{\{/SUMMARY\}\}"#,
            options: []
        )
    }()

    /// Extract summary text from scene content, or nil if no summary block exists.
    /// Checks triple-brace first, falls back to legacy double-brace.
    static func extractSummary(from content: String) -> String? {
        let nsString = content as NSString
        let range = NSRange(location: 0, length: nsString.length)
        let match = pattern.firstMatch(in: content, range: range)
            ?? legacyPattern.firstMatch(in: content, range: range)
        guard let match, match.numberOfRanges >= 2 else { return nil }
        let summaryText = nsString.substring(with: match.range(at: 1))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return summaryText.isEmpty ? nil : summaryText
    }

    /// Return the NSRange of the full summary block (for hiding in the editor).
    /// Checks triple-brace first, falls back to legacy double-brace.
    static func summaryRange(in content: String) -> NSRange? {
        summaryRanges(in: content).first
    }

    /// Return the NSRanges of all summary blocks (for hiding in the editor).
    static func summaryRanges(in content: String) -> [NSRange] {
        let nsString = content as NSString
        let range = NSRange(location: 0, length: nsString.length)
        var ranges = pattern.matches(in: content, range: range).map(\.range)
        ranges.append(contentsOf: legacyPattern.matches(in: content, range: range).map(\.range))
        return ranges.sorted { $0.location < $1.location }
    }
}
