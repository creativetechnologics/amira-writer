import Foundation

// MARK: - Animate Prompt Parser
//
// Static utility for detecting curly-brace animate prompts embedded in
// lyrics text. These are instructions destined for Novotro Animate:
//
//   {camera: zoom_in | from=wide | to=close | bars=17-24}
//   {enter: "Johnny" | position=center_left | facing=camera}
//   {scene: "Mountain Valley" | bg=mountain_valley_dawn | lighting=day}
//   {lipsync: "Lucas" | mode=singing | bars=3-4}
//   {emotion: "Lucas" | expression=immediate_focus | bar=3}
//   {exit: "Johnny"}
//   {action: "Amira" | picks up journal | bars=37-38}
//   {INSTRUMENTAL: Ancient Waters motif returns}
//
// Single curly braces are used for animate prompts. Triple curly braces
// {{{...}}} are used for meta markers (SUMMARY, SCENE). Double brackets
// [[...]] are used for direction markup. Single brackets [...] are used
// for narrative storyboarding.

enum AnimatePromptParser {

    // MARK: - Regex Pattern

    /// Matches single-brace animate prompts {keyword: ...} but NOT triple-brace
    /// meta markers {{{...}}}. Supports any keyword-style tag followed by a colon,
    /// including multiline prompt bodies.
    private static let pattern: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(
            pattern: #"(?<!\{)\{([A-Za-z_][A-Za-z0-9_\-]*\s*:[\s\S]*?)\}(?!\})"#,
            options: []
        )
    }()

    // MARK: - Range Detection

    /// Find the character ranges of all animate prompts in a string.
    ///
    /// Returns `[NSRange]` suitable for applying temporary attributes
    /// (e.g., hiding or styling prompt text in the editor's NSTextView).
    static func promptRanges(in text: String) -> [NSRange] {
        let nsString = text as NSString
        let fullRange = NSRange(location: 0, length: nsString.length)
        return pattern.matches(in: text, range: fullRange).map(\.range)
    }
}
