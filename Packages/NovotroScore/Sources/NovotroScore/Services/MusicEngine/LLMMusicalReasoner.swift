import Foundation

// MARK: - LLMMusicalReasoner

/// Prompt templates and response parsers for musical reasoning with a local LLM.
///
/// All methods are pure functions — they build prompt strings and parse response
/// strings without calling the LLM directly. The caller (`ProjectStore`) is
/// responsible for wiring prompts through `LLMClient.generate()`.
enum LLMMusicalReasoner {

    // MARK: - System Prompt

    private static let musicianSystemPrompt = """
        You are a knowledgeable music theory expert and opera composition assistant. \
        You analyze melodies, harmonies, lyrics, and orchestration with precision. \
        Keep responses concise and actionable. Use standard music terminology.
        """

    // MARK: - Prompt Builders

    /// Build a prompt to evaluate how well lyrics fit the melody.
    static func evaluateLyricMelodyFitPrompt(
        lyrics: String,
        melodySummary: String,
        key: DetectedKey
    ) -> (system: String, user: String) {
        let user = """
            Evaluate how well these lyrics fit the melody. \
            Rate the fit from 1 to 10 and explain your reasoning.

            Key: \(key.displayName)

            Melody summary:
            \(melodySummary)

            Lyrics:
            \(lyrics.prefix(2000))

            Respond in this format:
            SCORE: [1-10]
            STRENGTHS:
            - [strength 1]
            - [strength 2]
            SUGGESTIONS:
            - [suggestion 1]
            - [suggestion 2]
            """
        return (system: musicianSystemPrompt, user: user)
    }

    /// Build a prompt to suggest chord progressions for a melody.
    static func suggestChordProgressionPrompt(
        melodySummary: String,
        key: DetectedKey,
        style: String
    ) -> (system: String, user: String) {
        let user = """
            Suggest a chord progression for this melody. \
            Use standard chord symbols (e.g. Cm7, G/B, Fdim).

            Key: \(key.displayName)
            Style: \(style.isEmpty ? "operatic" : style)

            Melody summary:
            \(melodySummary)

            List 4-8 chords per phrase. Use Roman numeral analysis and provide \
            the chord symbols. One chord per line.
            """
        return (system: musicianSystemPrompt, user: user)
    }

    /// Build a prompt to describe the musical style of a piece.
    static func describeMusicalStylePrompt(
        key: DetectedKey,
        chords: [DetectedChord],
        tempoRange: ClosedRange<Double>
    ) -> (system: String, user: String) {
        let chordNames = chords.prefix(16).map { $0.displayName }.joined(separator: " → ")
        let user = """
            Describe the musical style and character of this piece based on:

            Key: \(key.displayName)
            Tempo: \(Int(tempoRange.lowerBound))–\(Int(tempoRange.upperBound)) BPM
            Chord progression: \(chordNames)

            Describe the mood, genre influences, harmonic language, and any notable \
            compositional features in 3-5 sentences.
            """
        return (system: musicianSystemPrompt, user: user)
    }

    /// Build a prompt to suggest instrument arrangements.
    static func suggestArrangementPrompt(
        melodySummary: String,
        chords: [DetectedChord],
        key: DetectedKey,
        availableInstruments: [String]
    ) -> (system: String, user: String) {
        let chordNames = chords.prefix(16).map { $0.displayName }.joined(separator: " → ")
        let instrumentList = availableInstruments.joined(separator: ", ")
        let user = """
            Suggest an orchestral arrangement for this piece.

            Key: \(key.displayName)
            Chord progression: \(chordNames)
            Available instruments: \(instrumentList)

            Melody summary:
            \(melodySummary)

            For each instrument you recommend, specify:
            INSTRUMENT: [name]
            STYLE: [sustained/arpeggiated/rhythmic/countermelody/doubling]
            REASONING: [why this instrument and style]

            Suggest 3-5 instruments.
            """
        return (system: musicianSystemPrompt, user: user)
    }

    /// Build a freeform musical prompt with contextual information.
    static func freeformPrompt(
        userQuery: String,
        key: DetectedKey?,
        chords: [DetectedChord],
        melodySummary: String?
    ) -> (system: String, user: String) {
        var context = ""
        if let key = key {
            context += "Key: \(key.displayName)\n"
        }
        if !chords.isEmpty {
            let chordNames = chords.prefix(16).map { $0.displayName }.joined(separator: " → ")
            context += "Chords: \(chordNames)\n"
        }
        if let summary = melodySummary, !summary.isEmpty {
            context += "Melody: \(summary)\n"
        }

        let user: String
        if context.isEmpty {
            user = userQuery
        } else {
            user = """
                Musical context:
                \(context)
                Question: \(userQuery)
                """
        }
        return (system: musicianSystemPrompt, user: user)
    }

    // MARK: - Melody Summarizer

    /// Build a compact textual summary of a melody for use in LLM prompts.
    ///
    /// Describes the pitch range, contour, note count, duration, and rhythmic
    /// characteristics in a format the LLM can reason about.
    static func buildMelodySummary(
        notes: [PianoRollNote],
        key: DetectedKey,
        ticksPerQuarter: Int
    ) -> String {
        guard !notes.isEmpty else { return "(empty melody)" }

        let sorted = notes.sorted { $0.startTick < $1.startTick }
        let pitches = sorted.map(\.pitch)
        let minPitch = pitches.min() ?? 60
        let maxPitch = pitches.max() ?? 60
        let tpq = max(1, ticksPerQuarter)

        let totalBeats = Double((sorted.last?.startTick ?? 0) + (sorted.last?.duration ?? 0) - (sorted.first?.startTick ?? 0))
            / Double(tpq)

        // Pitch class names
        let noteNames = ["C", "C#", "D", "Eb", "E", "F", "F#", "G", "Ab", "A", "Bb", "B"]

        // First few note names with octave
        let firstNotes = sorted.prefix(8).map { note -> String in
            let pc = note.pitch % 12
            let octave = note.pitch / 12 - 1
            let beats = String(format: "%.1f", Double(note.duration) / Double(tpq))
            return "\(noteNames[pc])\(octave)(\(beats)b)"
        }

        // Contour: opening intervals
        var intervals: [Int] = []
        for i in 1..<min(sorted.count, 8) {
            intervals.append(sorted[i].pitch - sorted[i - 1].pitch)
        }
        let intervalStr = intervals.map { $0 >= 0 ? "+\($0)" : "\($0)" }.joined(separator: ", ")

        return """
            \(sorted.count) notes over \(String(format: "%.1f", totalBeats)) beats in \(key.displayName). \
            Range: \(noteNames[minPitch % 12])\(minPitch / 12 - 1) to \(noteNames[maxPitch % 12])\(maxPitch / 12 - 1) \
            (\(maxPitch - minPitch) semitones). \
            Opening notes: \(firstNotes.joined(separator: " ")). \
            Opening intervals: \(intervalStr).
            """
    }

    // MARK: - Response Parsers

    /// Parse a lyric-melody fit evaluation response.
    static func parseLyricFitResponse(_ raw: String) -> LyricFitResult {
        var score = 5
        var strengths: [String] = []
        var suggestions: [String] = []

        let lines = raw.components(separatedBy: "\n")
        var section: String?

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.uppercased().hasPrefix("SCORE:") {
                let numStr = trimmed.dropFirst(6).trimmingCharacters(in: .whitespaces)
                if let n = Int(numStr.prefix(while: { $0.isNumber })), (1...10).contains(n) {
                    score = n
                }
            } else if trimmed.uppercased().hasPrefix("STRENGTHS:") {
                section = "strengths"
            } else if trimmed.uppercased().hasPrefix("SUGGESTIONS:") {
                section = "suggestions"
            } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                let content = String(trimmed.dropFirst(2))
                if section == "strengths" {
                    strengths.append(content)
                } else if section == "suggestions" {
                    suggestions.append(content)
                }
            }
        }

        return LyricFitResult(
            overallScore: score,
            strengths: strengths,
            suggestions: suggestions,
            rawResponse: raw
        )
    }

    /// Parse chord suggestion response into an array of chord symbols.
    static func parseChordSuggestionResponse(_ raw: String) -> [String] {
        let lines = raw.components(separatedBy: "\n")
        var chords: [String] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Look for lines that look like chord symbols (start with A-G)
            if let first = trimmed.first, "ABCDEFG".contains(first) {
                // Extract just the chord symbol (first word)
                let symbol = trimmed.components(separatedBy: .whitespaces).first ?? trimmed
                if symbol.count <= 10 { // reasonable chord symbol length
                    chords.append(symbol)
                }
            } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                let content = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                if let first = content.first, "ABCDEFG".contains(first) {
                    let symbol = content.components(separatedBy: .whitespaces).first ?? content
                    if symbol.count <= 10 {
                        chords.append(symbol)
                    }
                }
            }
        }
        return chords
    }

    /// Parse style description response (pass-through with cleanup).
    static func parseStyleDescription(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Parse arrangement suggestion response.
    static func parseArrangementSuggestion(_ raw: String) -> ArrangementSuggestion {
        var entries: [ArrangementSuggestion.InstrumentSuggestionEntry] = []
        let lines = raw.components(separatedBy: "\n")

        var currentInstrument: String?
        var currentStyle: String?
        var currentReasoning: String?

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.uppercased().hasPrefix("INSTRUMENT:") {
                // Flush previous entry
                if let inst = currentInstrument {
                    entries.append(.init(
                        instrument: inst,
                        style: currentStyle ?? "sustained",
                        reasoning: currentReasoning ?? ""
                    ))
                }
                currentInstrument = String(trimmed.dropFirst(11)).trimmingCharacters(in: .whitespaces)
                currentStyle = nil
                currentReasoning = nil
            } else if trimmed.uppercased().hasPrefix("STYLE:") {
                currentStyle = String(trimmed.dropFirst(6)).trimmingCharacters(in: .whitespaces).lowercased()
            } else if trimmed.uppercased().hasPrefix("REASONING:") {
                currentReasoning = String(trimmed.dropFirst(10)).trimmingCharacters(in: .whitespaces)
            }
        }

        // Flush last entry
        if let inst = currentInstrument {
            entries.append(.init(
                instrument: inst,
                style: currentStyle ?? "sustained",
                reasoning: currentReasoning ?? ""
            ))
        }

        return ArrangementSuggestion(instrumentSuggestions: entries, rawResponse: raw)
    }
}
