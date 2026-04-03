import Foundation

/// Generates mouth shape (viseme) keyframes from OWP lyric alignment data or phoneme input.
///
/// Two modes:
/// 1. **Singing** — Uses OWP lyric alignment entries that map syllables to notes with tick timing.
///    Converts each syllable's text to phonemes, then maps phonemes to Preston Blair visemes.
/// 2. **Speech** — Accepts timed phoneme data (e.g., from Rhubarb Lip Sync) and converts to viseme keyframes.
struct LipSyncEngine: Sendable {

    // MARK: - Types

    struct VisemeKeyframe: Sendable {
        var frame: Int
        var viseme: PrestonBlairViseme
        var duration: Int  // frames

        func toTimelineKeyframe() -> TimelineKeyframe {
            // Visemes use expression keyframes with the viseme label as the name
            TimelineKeyframe(
                frame: frame,
                kind: .expression,
                easing: .stepped,
                value: .expression(name: "viseme:\(viseme.token)")
            )
        }
    }

    struct TimedPhoneme: Sendable {
        var time: Double  // seconds
        var duration: Double  // seconds
        var phoneme: String
    }

    // MARK: - Singing Mode (from OWP)

    /// Generate viseme keyframes from OWP lyric alignment data.
    ///
    /// Uses the lyric alignment entries to map each syllable to its timing via the associated note,
    /// then determines the appropriate mouth shape.
    static func generateFromOWPAlignment(
        alignment: OWPLyricAlignment,
        notes: [OWPNote],
        songData: OWSSongData,
        fps: Int
    ) -> [VisemeKeyframe] {
        var result: [VisemeKeyframe] = []

        // Build note lookup by ID
        let notesByID: [UUID: OWPNote] = Dictionary(uniqueKeysWithValues: notes.map { ($0.id, $0) })

        // Sort entries by note start tick
        let sortedEntries = alignment.entries.sorted { entryA, entryB in
            let noteA = notesByID[entryA.noteID]
            let noteB = notesByID[entryB.noteID]
            return (noteA?.startTick ?? 0) < (noteB?.startTick ?? 0)
        }

        var lastEndFrame = 0

        for entry in sortedEntries {
            guard let note = notesByID[entry.noteID] else { continue }

            let startFrame = songData.tickToFrame(note.startTick, fps: fps)
            let endFrame = songData.tickToFrame(note.startTick + note.duration, fps: fps)
            let duration = max(1, endFrame - startFrame)

            // Insert rest viseme in gaps
            if startFrame > lastEndFrame + 2 {
                result.append(VisemeKeyframe(
                    frame: lastEndFrame,
                    viseme: .rest,
                    duration: startFrame - lastEndFrame
                ))
            }

            // Determine viseme from the syllable text
            let syllable = note.lyricSyllable ?? ""
            let viseme = syllableToViseme(syllable)

            result.append(VisemeKeyframe(
                frame: startFrame,
                viseme: viseme,
                duration: duration
            ))

            // For longer notes, add mouth movement
            if duration > fps / 4 {  // > quarter second
                // Open mouth wider at start, slightly close toward end
                let midFrame = startFrame + duration / 2
                let closeViseme = vowelCloseVariant(for: viseme)
                if closeViseme != viseme {
                    result.append(VisemeKeyframe(
                        frame: midFrame,
                        viseme: closeViseme,
                        duration: duration / 2
                    ))
                }
            }

            lastEndFrame = endFrame
        }

        // Final rest
        if let lastKF = result.last {
            result.append(VisemeKeyframe(
                frame: lastKF.frame + lastKF.duration,
                viseme: .rest,
                duration: fps / 2
            ))
        }

        return result
    }

    // MARK: - Speech Mode (from Rhubarb or phoneme data)

    /// Generate viseme keyframes from timed phoneme data.
    static func generateFromPhonemes(
        _ phonemes: [TimedPhoneme],
        fps: Int
    ) -> [VisemeKeyframe] {
        var result: [VisemeKeyframe] = []

        for phoneme in phonemes {
            let frame = Int((phoneme.time * Double(fps)).rounded())
            let duration = max(1, Int((phoneme.duration * Double(fps)).rounded()))
            let viseme = phonemeToViseme(phoneme.phoneme)

            result.append(VisemeKeyframe(
                frame: frame,
                viseme: viseme,
                duration: duration
            ))
        }

        return result
    }

    /// Convert Rhubarb output shapes (A-H + X) to Preston Blair visemes.
    static func rhubarbShapeToViseme(_ shape: String) -> PrestonBlairViseme {
        switch shape.uppercased() {
        case "A": return .mbp       // Closed mouth (M, B, P)
        case "B": return .consonant // Slightly open (most consonants)
        case "C": return .e         // Open (E, EH)
        case "D": return .ai        // Wide open (A, I)
        case "E": return .o         // Rounded (O)
        case "F": return .u         // Tight rounded (U, OO)
        case "G": return .fv        // F, V shape
        case "H": return .l         // L shape
        case "X": return .rest      // Silence
        default: return .rest
        }
    }

    // MARK: - Phoneme → Viseme Mapping

    /// Map an IPA-like phoneme string to a Preston Blair viseme.
    static func phonemeToViseme(_ phoneme: String) -> PrestonBlairViseme {
        let p = phoneme.lowercased().trimmingCharacters(in: .whitespaces)

        switch p {
        // Vowels
        case "aa", "ae", "ah", "ay", "ai", "a", "i":
            return .ai
        case "eh", "ey", "ee", "ih", "iy", "e":
            return .e
        case "ao", "aw", "ow", "oh", "o":
            return .o
        case "uh", "uw", "oo", "u":
            return .u

        // Labials
        case "m", "b", "p":
            return .mbp

        // Labiodentals
        case "f", "v":
            return .fv

        // Liquids
        case "l", "el":
            return .l

        // Rounded glides
        case "w", "q":
            return .wq

        // Default consonants
        case "ch", "d", "dx", "g", "hh", "jh", "k", "n", "ng", "r",
             "s", "sh", "t", "th", "dh", "y", "z", "zh":
            return .consonant

        // Silence
        case "sil", "sp", "pau", "", "x":
            return .rest

        default:
            return .consonant
        }
    }

    // MARK: - Syllable → Viseme (simple heuristic)

    /// Determine the primary viseme for a syllable based on its leading/dominant sound.
    static func syllableToViseme(_ syllable: String) -> PrestonBlairViseme {
        let s = syllable.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return .rest }

        // Check for specific consonant clusters at start
        if s.hasPrefix("m") || s.hasPrefix("b") || s.hasPrefix("p") { return .mbp }
        if s.hasPrefix("f") || s.hasPrefix("v") { return .fv }
        if s.hasPrefix("w") || s.hasPrefix("qu") { return .wq }
        if s.hasPrefix("l") { return .l }

        // Find the first vowel to determine the primary mouth shape
        let vowels: [(String, PrestonBlairViseme)] = [
            ("oo", .u), ("ou", .o), ("ee", .e), ("ea", .e),
            ("ai", .ai), ("ay", .ai), ("ey", .e),
            ("ow", .o), ("oa", .o),
            ("a", .ai), ("e", .e), ("i", .ai), ("o", .o), ("u", .u),
        ]

        for (pattern, viseme) in vowels {
            if s.contains(pattern) { return viseme }
        }

        // Default to generic consonant shape
        return .consonant
    }

    /// For sustained notes, provide a slightly closed variant of the current viseme.
    private static func vowelCloseVariant(for viseme: PrestonBlairViseme) -> PrestonBlairViseme {
        switch viseme {
        case .ai: return .e       // wide → slightly less wide
        case .o: return .u        // round → tighter round
        case .e: return .consonant  // slightly close
        default: return viseme
        }
    }

    // MARK: - Timeline Integration

    /// Convert viseme keyframes to timeline keyframes for the mouth track.
    static func visemesToTimelineKeyframes(_ visemes: [VisemeKeyframe]) -> [TimelineKeyframe] {
        visemes.map { $0.toTimelineKeyframe() }
    }
}
