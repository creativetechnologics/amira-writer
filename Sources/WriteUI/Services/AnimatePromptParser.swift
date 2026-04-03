import Foundation

// MARK: - Animate Prompt Parser
//
// Static utility for detecting Animate/libretto direction prompts embedded in
// lyrics text.
//
// Canonical modern form:
//   [camera: zoom_in | from=wide | to=close | bars=17-24]
//   [cinematography: push_in | from=medium | to=close | bars=17-24]
//   [enter: "Johnny" | position=center_left | facing=camera]
//   [scene: "Mountain Valley" | bg=mountain_valley_dawn | lighting=day]
//   [lipsync: "Lucas" | mode=singing | bars=3-4]
//
// Legacy form still recognized for compatibility:
//   {camera: zoom_in | from=wide | to=close | bars=17-24}
//
// Double brackets [[...]] are numbered direction markup. Triple curly braces
// are meta blocks. Single brackets may now be either Animate DSL or narrative
// storyboarding, depending on the tag.

enum AnimatePromptParser {

    private static let supportedTags: Set<String> = [
        "scene",
        "camera",
        "cinematography",
        "enter",
        "exit",
        "move",
        "emotion",
        "action",
        "gesture",
        "object",
        "object_move",
        "object_state",
        "object_visibility",
        "prop",
        "prop_move",
        "prop_state",
        "prop_visibility",
        "lipsync",
        "pause",
        "sfx",
        "transition"
    ]

    /// Matches legacy single-brace animate prompts {keyword: ...} but NOT
    /// triple-brace meta markers {{{...}}}. Supports multiline prompt bodies.
    private static let legacyCurlyPattern: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(
            pattern: #"(?<!\{)\{([A-Za-z_][A-Za-z0-9_\-]*\s*:[\s\S]*?)\}(?!\})"#,
            options: []
        )
    }()

    /// Matches canonical single-bracket Animate DSL but not [[...]] blocks.
    private static let canonicalBracketPattern: NSRegularExpression = {
        let tagPattern = supportedTags.sorted().joined(separator: "|")
        let pattern = "(?<!\\[)\\[((?:\(tagPattern))\\s*:[^\\[\\]]+)\\](?!\\])"
        // swiftlint:disable:next force_try
        return try! NSRegularExpression(pattern: pattern, options: [])
    }()

    static func promptRanges(in text: String) -> [NSRange] {
        let nsString = text as NSString
        let fullRange = NSRange(location: 0, length: nsString.length)
        return mergedRanges(
            legacyCurlyPattern.matches(in: text, range: fullRange).map(\.range)
                + canonicalPromptRanges(in: text)
        )
    }

    static func canonicalPromptRanges(in text: String) -> [NSRange] {
        let nsString = text as NSString
        let fullRange = NSRange(location: 0, length: nsString.length)
        return canonicalBracketPattern.matches(in: text, range: fullRange).map(\.range)
    }

    private static func mergedRanges(_ ranges: [NSRange]) -> [NSRange] {
        guard !ranges.isEmpty else { return [] }
        let sorted = ranges.sorted {
            if $0.location == $1.location {
                return $0.length < $1.length
            }
            return $0.location < $1.location
        }

        var merged: [NSRange] = []
        for range in sorted {
            guard let last = merged.last else {
                merged.append(range)
                continue
            }

            let lastEnd = last.location + last.length
            if range.location <= lastEnd {
                let newEnd = max(lastEnd, range.location + range.length)
                merged[merged.count - 1] = NSRange(location: last.location, length: newEnd - last.location)
            } else {
                merged.append(range)
            }
        }

        return merged
    }
}
