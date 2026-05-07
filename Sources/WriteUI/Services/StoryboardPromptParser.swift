import Foundation

// MARK: - Storyboard Prompt Parser
//
// Static utility for detecting single-bracket storyboarding prompts
// embedded in lyrics text. The markup format is:
//
//   [camera track from medium to wide, bars 25 to 32]
//
// Canonical Animate DSL now also uses single brackets, so this parser must
// exclude any recognized Animate [tag: ...] blocks.

enum StoryboardPromptParser {

    // MARK: - Regex Pattern

    /// Matches single-bracket prompts [text] but NOT double-bracket directions [[text]].
    /// Animate [tag: ...] ranges are filtered out separately.
    private static let pattern: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(
            pattern: #"(?<!\[)\[([^\[\]]+)\](?!\])"#,
            options: []
        )
    }()

    // MARK: - Range Detection

    /// Find the character ranges of all storyboarding prompts in a string.
    ///
    /// Returns `[NSRange]` suitable for applying temporary attributes
    /// (e.g., hiding or styling prompt text in the editor's NSTextView).
    /// Accepts optional pre-computed animate prompt ranges to avoid forcing
    /// `AnimatePromptParser.canonicalPromptRanges()` to run a second full-text
    /// regex scan (it is already called once by the caller for coloring).
    /// When nil, this method falls back to running it independently (old behavior).
    static func promptRanges(in text: String, animateRanges: [NSRange]? = nil) -> [NSRange] {
        let nsString = text as NSString
        let fullRange = NSRange(location: 0, length: nsString.length)
        let keys: Set<String>
        if let animateRanges {
            keys = Set(animateRanges.map { "\($0.location):\($0.length)" })
        } else {
            keys = Set(AnimatePromptParser.canonicalPromptRanges(in: text).map { "\($0.location):\($0.length)" })
        }
        return pattern.matches(in: text, range: fullRange)
            .map(\.range)
            .filter { !keys.contains("\($0.location):\($0.length)") }
    }
}
