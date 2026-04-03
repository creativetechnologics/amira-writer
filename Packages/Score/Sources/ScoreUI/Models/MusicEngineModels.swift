import Foundation

// MARK: - Music Intelligence Engine — Shared Types

/// All types are Sendable + Codable for persistence in .ows playback snapshots.

// MARK: - Melodic Contour

/// Classification of a melodic line's overall shape.
enum MelodicContour: String, Codable, Sendable, CaseIterable {
    case ascending       // generally rises
    case descending      // generally falls
    case arch            // rises then falls
    case invertedArch    // falls then rises
    case constant        // stays within ~2 semitones
    case mixed           // no clear pattern
}

// MARK: - Musical Phrase

/// A detected musical phrase — a group of temporally contiguous notes
/// with a coherent melodic line, bounded by rests or large leaps.
struct MusicalPhrase: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var startTick: Int
    var endTick: Int                   // last note's startTick + duration
    var noteIDs: [UUID]                // ordered note IDs within phrase
    var startNoteIndex: Int            // index into the sorted notes array
    var endNoteIndex: Int              // inclusive
    var contour: MelodicContour
    var meanPitch: Double
    var pitchRange: Int                // maxPitch - minPitch within phrase

    init(
        id: UUID = UUID(),
        startTick: Int,
        endTick: Int,
        noteIDs: [UUID],
        startNoteIndex: Int,
        endNoteIndex: Int,
        contour: MelodicContour = .mixed,
        meanPitch: Double = 60,
        pitchRange: Int = 0
    ) {
        self.id = id
        self.startTick = startTick
        self.endTick = endTick
        self.noteIDs = noteIDs
        self.startNoteIndex = startNoteIndex
        self.endNoteIndex = endNoteIndex
        self.contour = contour
        self.meanPitch = meanPitch
        self.pitchRange = pitchRange
    }
}

// MARK: - Song Section

/// A structural section of a song (verse, chorus, bridge, etc.).
struct SongSection: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var type: SectionType
    var startTick: Int
    var endTick: Int
    var phraseIDs: [UUID]
    var confidence: Double             // 0.0–1.0
    var label: String                  // e.g. "Verse 1", "Chorus", "Bridge"

    init(
        id: UUID = UUID(),
        type: SectionType,
        startTick: Int,
        endTick: Int,
        phraseIDs: [UUID],
        confidence: Double,
        label: String
    ) {
        self.id = id
        self.type = type
        self.startTick = startTick
        self.endTick = endTick
        self.phraseIDs = phraseIDs
        self.confidence = confidence
        self.label = label
    }
}

/// Classification of song section types, including opera-specific types.
enum SectionType: String, Codable, Sendable, CaseIterable {
    case intro
    case verse
    case preChorus
    case chorus
    case bridge
    case outro
    case instrumental
    case recitative      // opera: speech-like singing
    case aria            // opera: lyrical solo passage
    case ensemble        // opera: multiple voices
    case unknown
}

// MARK: - Detected Key

/// Result of key detection from pitch distribution analysis.
struct DetectedKey: Codable, Hashable, Sendable {
    var root: Int              // pitch class 0–11 (0 = C, 1 = C#, ...)
    var isMinor: Bool
    var confidence: Double     // 0.0–1.0

    var rootName: String {
        let names = ["C", "C\u{266F}", "D", "E\u{266D}", "E", "F",
                     "F\u{266F}", "G", "A\u{266D}", "A", "B\u{266D}", "B"]
        return names[root % 12]
    }

    var modeName: String {
        isMinor ? "Minor" : "Major"
    }

    var displayName: String {
        "\(rootName) \(modeName)"
    }

    /// Pitch classes in this key's diatonic scale (0-indexed).
    var scalePitchClasses: Set<Int> {
        let majorIntervals = [0, 2, 4, 5, 7, 9, 11]
        let minorIntervals = [0, 2, 3, 5, 7, 8, 10]
        let intervals = isMinor ? minorIntervals : majorIntervals
        return Set(intervals.map { ($0 + root) % 12 })
    }
}

// MARK: - Structural Analysis

/// Complete structural analysis result for a song.
struct StructuralAnalysis: Codable, Sendable {
    var phrases: [MusicalPhrase]
    var sections: [SongSection]
    var detectedKey: DetectedKey?
    var phraseContours: [UUID: MelodicContour]  // phraseID → contour

    init(
        phrases: [MusicalPhrase] = [],
        sections: [SongSection] = [],
        detectedKey: DetectedKey? = nil,
        phraseContours: [UUID: MelodicContour] = [:]
    ) {
        self.phrases = phrases
        self.sections = sections
        self.detectedKey = detectedKey
        self.phraseContours = phraseContours
    }

    // Custom coding for UUID-keyed dictionary
    private enum CodingKeys: String, CodingKey {
        case phrases, sections, detectedKey, phraseContoursArray
    }

    private struct PhraseContourEntry: Codable, Sendable {
        var phraseID: UUID
        var contour: MelodicContour
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(phrases, forKey: .phrases)
        try container.encode(sections, forKey: .sections)
        try container.encodeIfPresent(detectedKey, forKey: .detectedKey)
        let entries = phraseContours.map { PhraseContourEntry(phraseID: $0.key, contour: $0.value) }
        try container.encode(entries, forKey: .phraseContoursArray)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        phrases = try container.decode([MusicalPhrase].self, forKey: .phrases)
        sections = try container.decode([SongSection].self, forKey: .sections)
        detectedKey = try container.decodeIfPresent(DetectedKey.self, forKey: .detectedKey)
        let entries = try container.decodeIfPresent([PhraseContourEntry].self, forKey: .phraseContoursArray) ?? []
        phraseContours = Dictionary(uniqueKeysWithValues: entries.map { ($0.phraseID, $0.contour) })
    }
}

// MARK: - Smart Alignment Result

/// Enhanced alignment result with phrase-awareness and contour scoring.
struct SmartAlignmentResult: Sendable {
    struct Assignment: Sendable {
        var noteID: UUID
        var syllable: String
        var phraseID: UUID?
    }

    /// Warning for a phrase region where syllable count is a poor fit for note count.
    struct FitWarning: Sendable {
        var phraseIndex: Int           // 0-based lyric phrase index
        var syllableCount: Int
        var noteCount: Int
        var message: String            // e.g. "Phrase 3: 12 syllables for 5 notes"
    }

    var assignments: [Assignment]
    var unmatchedSyllables: [String]
    var unmatchedNotes: [UUID]
    var confidence: Double
    var phraseBreakAlignments: Int     // count of lyric line breaks aligned to phrase boundaries
    var contourScore: Double           // how well syllable stress aligns with melodic contour
    var fitWarnings: [FitWarning]      // phrases where syllable/note ratio is problematic

    /// Convert to the simple [UUID: String] format used by LyricsLaneView.previewAlignments.
    var previewDictionary: [UUID: String] {
        Dictionary(uniqueKeysWithValues: assignments.map { ($0.noteID, $0.syllable) })
    }

    /// Convert to the flat (noteID, syllable) format used by LyricAligner.AlignmentResult.
    var flatAssignments: [(noteID: UUID, syllable: String)] {
        assignments.map { ($0.noteID, $0.syllable) }
    }
}

// MARK: - Phrase Match

/// Describes how lyric phrases map to musical phrases in the DP-based optimal partition.
/// Each match groups one or more lyric phrases with one or more musical phrases.
struct PhraseMatch: Sendable {
    var lyricPhraseIndices: [Int]      // indices into lyric phrases array
    var musicalPhraseIndices: [Int]    // indices into musical phrases array
    var syllableCount: Int             // total syllables in matched lyric phrases
    var noteCount: Int                 // total notes in matched musical phrases

    /// How mismatched the syllable/note counts are (0 = perfect, 1 = completely off).
    var mismatchRatio: Double {
        let maxCount = max(syllableCount, noteCount)
        guard maxCount > 0 else { return 0 }
        return Double(abs(syllableCount - noteCount)) / Double(maxCount)
    }
}

// MARK: - Syllable Elasticity

/// Range of possible syllable counts for a word, with a preferred (default) count.
/// Used by the elastic alignment system to compress/expand uncertain words to fit note counts.
struct SyllableRange: Sendable, Equatable {
    let min: Int           // fewest syllables (compressed, e.g. "fire" → 1)
    let preferred: Int     // default count from syllabify() (e.g. "fire" → 2)
    let max: Int           // most syllables (expanded, e.g. "every" → 3)

    /// 1.0 = perfectly certain (min == max), 0.0 = uncertain (min < max).
    var certainty: Double {
        min == max ? 1.0 : 0.0
    }

    /// Whether this word can change syllable count.
    var isElastic: Bool { min < max }

    /// Create a fixed (non-elastic) range.
    static func fixed(_ count: Int) -> SyllableRange {
        SyllableRange(min: count, preferred: count, max: count)
    }
}

/// A word with elastic syllable information for alignment.
/// Contains syllable variants for each possible count in the range.
struct ElasticWord: Sendable {
    let word: String
    /// Syllable strings for each possible count: e.g. `[1: ["fire"], 2: ["fi", "re"]]`
    let syllableVariants: [Int: [String]]
    let range: SyllableRange
}

// MARK: - Melodic Mutation

/// A proposed set of MIDI modifications when lyrics need more or fewer notes.
struct MelodicMutation: Sendable {
    var notesToInsert: [PianoRollNote]
    var notesToRemove: [UUID]
    var notesToModify: [NoteModification]
    var description: String            // human-readable summary
    var confidence: Double             // 0.0–1.0

    struct NoteModification: Sendable {
        var noteID: UUID
        var newPitch: Int?
        var newDuration: Int?
        var newStartTick: Int?
    }

    /// True if this mutation makes no changes.
    var isEmpty: Bool {
        notesToInsert.isEmpty && notesToRemove.isEmpty && notesToModify.isEmpty
    }

    /// Total number of changes proposed.
    var changeCount: Int {
        notesToInsert.count + notesToRemove.count + notesToModify.count
    }
}

// MARK: - Phrase Detection Config

/// Configuration for phrase boundary detection.
struct PhraseDetectionConfig: Sendable {
    /// Minimum gap in beats to force a phrase break.
    var gapThresholdBeats: Double = 1.0
    /// Pitch interval in semitones that suggests a new phrase.
    var pitchJumpThreshold: Int = 12
    /// Weight of rhythmic pattern change in break scoring (0–1).
    var rhythmChangeWeight: Double = 0.3
    /// Snap phrase boundaries to nearest bar line when within 1 beat.
    var snapToBarLine: Bool = true
    /// Minimum number of notes in a phrase.
    var minPhraseLengthNotes: Int = 3
}

// MARK: - Alignment Config

/// Configuration for smart lyric alignment.
struct SmartAlignmentConfig: Sendable {
    var useStructuralAnalysis: Bool = true
    var useContourAwareness: Bool = true
    var respectPhraseBreaks: Bool = true
    var stressMatchingWeight: Double = 0.3
}

// MARK: - Mutation Config

/// Configuration for melodic mutation proposals.
struct MelodicMutationConfig: Sendable {
    var maxInsertions: Int = 8
    var maxRemovals: Int = 4
    /// Prefer splitting existing long notes over inserting new pitches.
    var preferSplitOverInsert: Bool = true
    /// New notes must follow the existing melodic contour.
    var preserveContour: Bool = true
    /// New notes must stay within the detected key's scale.
    var respectScale: Bool = true
}

// MARK: - Phase 2: Chord & Harmony Types

/// A detected chord at a specific beat position.
struct DetectedChord: Codable, Hashable, Sendable {
    var tick: Int                   // position in ticks
    var durationTicks: Int          // how long this chord is active
    var root: Int                   // pitch class 0–11
    var quality: String             // e.g. "", "m", "7", "dim", "aug"
    var bassNote: Int?              // pitch class of lowest note (for inversions)
    var pitchClasses: Set<Int>      // all pitch classes present

    /// Display name like "Cm7" or "G/B".
    var displayName: String {
        let noteNames = ["C", "C\u{266F}", "D", "E\u{266D}", "E", "F",
                         "F\u{266F}", "G", "A\u{266D}", "A", "B\u{266D}", "B"]
        let rootName = noteNames[root % 12]
        if let bass = bassNote, bass != root {
            let bassName = noteNames[bass % 12]
            return "\(rootName)\(quality)/\(bassName)"
        }
        return "\(rootName)\(quality)"
    }

    /// Roman numeral relative to a key.
    func romanNumeral(in key: DetectedKey) -> String {
        let interval = ((root - key.root) % 12 + 12) % 12
        let numerals = ["I", "bII", "II", "bIII", "III", "IV",
                        "#IV", "V", "bVI", "VI", "bVII", "VII"]
        let numeral = numerals[interval]
        let isMinorChord = quality.hasPrefix("m") && !quality.hasPrefix("maj")
        return isMinorChord ? numeral.lowercased() : numeral
    }
}

/// A chord progression analysis result.
struct ChordProgressionResult: Codable, Sendable {
    var chords: [DetectedChord]
    var key: DetectedKey?
    var commonProgressions: [String]  // detected patterns like "I-IV-V-I"

    // Custom coding for Set<Int> in DetectedChord
    init(chords: [DetectedChord] = [], key: DetectedKey? = nil, commonProgressions: [String] = []) {
        self.chords = chords
        self.key = key
        self.commonProgressions = commonProgressions
    }
}

/// A voice in 4-part harmony (SATB).
enum VoicePart: String, Codable, Sendable, CaseIterable {
    case soprano
    case alto
    case tenor
    case bass
}

/// A single chord voicing in 4-part harmony.
struct HarmonyVoicing: Codable, Sendable {
    var tick: Int
    var durationTicks: Int
    var soprano: Int               // MIDI pitch
    var alto: Int
    var tenor: Int
    var bass: Int

    /// All four pitches as an array (S, A, T, B).
    var pitches: [Int] { [soprano, alto, tenor, bass] }

    /// Get the pitch for a specific voice part.
    func pitch(for part: VoicePart) -> Int {
        switch part {
        case .soprano: return soprano
        case .alto: return alto
        case .tenor: return tenor
        case .bass: return bass
        }
    }
}

/// Result of harmonization.
struct HarmonizationResult: Sendable {
    var voicings: [HarmonyVoicing]
    var key: DetectedKey
    var violations: [String]       // voice-leading violations found
    var score: Double              // quality score 0–1
}

// MARK: - Phase 3: Instrument Intelligence Types

/// Configuration for instrument part generation.
struct PartGenerationConfig: Sendable {
    /// Velocity multiplier relative to melody velocity (0.0–1.0).
    var velocityScale: Double = 0.8
    /// Rhythm density multiplier (0.5 = half notes, 1.0 = quarters, 2.0 = eighths).
    var rhythmDensity: Double = 1.0
    /// Include 7ths in arpeggiated patterns.
    var useChordExtensions: Bool = false
}

/// A generated instrument part ready for preview/acceptance.
struct GeneratedPart: Sendable {
    var instrumentName: String
    var style: String              // GenerationStyle rawValue
    var notes: [PianoRollNote]
    var trackIndex: Int
    var channel: Int
}

// MARK: - Phase 4: LLM Integration Types

/// Result of LLM lyric-melody fit evaluation.
struct LyricFitResult: Sendable {
    var overallScore: Int           // 1–10
    var strengths: [String]
    var suggestions: [String]
    var rawResponse: String
}

/// LLM suggestion for instrument arrangement.
struct ArrangementSuggestion: Sendable {
    var instrumentSuggestions: [InstrumentSuggestionEntry]
    var rawResponse: String

    struct InstrumentSuggestionEntry: Sendable {
        var instrument: String
        var style: String
        var reasoning: String
    }
}

// MARK: - Phase 5: Style Analysis & Composition Types

/// Melodic characteristics of a piece — density, intervals, range, contour.
struct MelodicProfile: Codable, Sendable {
    var noteDensity: Double          // notes per beat
    var leapFrequency: Double        // fraction of intervals > 4 semitones
    var averageInterval: Double      // mean absolute interval in semitones
    var pitchRange: Int              // max - min pitch
    var contourDistribution: [MelodicContour: Double]  // fraction per contour type

    // Custom Codable for [MelodicContour: Double] (enum-keyed dictionaries)
    private enum CodingKeys: String, CodingKey {
        case noteDensity, leapFrequency, averageInterval, pitchRange, contourDistributionRaw
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(noteDensity, forKey: .noteDensity)
        try container.encode(leapFrequency, forKey: .leapFrequency)
        try container.encode(averageInterval, forKey: .averageInterval)
        try container.encode(pitchRange, forKey: .pitchRange)
        let raw = Dictionary(uniqueKeysWithValues: contourDistribution.map { ($0.key.rawValue, $0.value) })
        try container.encode(raw, forKey: .contourDistributionRaw)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        noteDensity = try container.decode(Double.self, forKey: .noteDensity)
        leapFrequency = try container.decode(Double.self, forKey: .leapFrequency)
        averageInterval = try container.decode(Double.self, forKey: .averageInterval)
        pitchRange = try container.decode(Int.self, forKey: .pitchRange)
        let raw = try container.decode([String: Double].self, forKey: .contourDistributionRaw)
        contourDistribution = Dictionary(uniqueKeysWithValues: raw.compactMap { pair in
            guard let contour = MelodicContour(rawValue: pair.key) else { return nil }
            return (contour, pair.value)
        })
    }

    init(
        noteDensity: Double,
        leapFrequency: Double,
        averageInterval: Double,
        pitchRange: Int,
        contourDistribution: [MelodicContour: Double]
    ) {
        self.noteDensity = noteDensity
        self.leapFrequency = leapFrequency
        self.averageInterval = averageInterval
        self.pitchRange = pitchRange
        self.contourDistribution = contourDistribution
    }
}

/// Rhythmic characteristics — syncopation, variety, note durations, rests.
struct RhythmicProfile: Codable, Sendable {
    var syncopationIndex: Double     // fraction of notes on off-beats
    var rhythmicVariety: Double      // unique durations / total notes
    var averageDurationBeats: Double
    var dottedNoteFrequency: Double  // fraction of dotted durations
    var restFrequency: Double        // fraction of inter-note gaps > 0.5 beats
}

/// Harmonic complexity metrics — chord density, functional strength, extensions.
struct HarmonicComplexity: Codable, Sendable {
    var chordDensity: Double         // chords per bar (4 beats)
    var functionalStrength: Double   // fraction of I/IV/V/vi chords
    var extensionUsage: Double       // fraction with 7th+ extensions
    var chromaticism: Double         // fraction with root outside key
}

/// Combined musical style profile with sub-analyses and genre inference.
struct MusicalStyleProfile: Codable, Sendable {
    var melodicProfile: MelodicProfile
    var rhythmicProfile: RhythmicProfile
    var harmonicComplexity: HarmonicComplexity
    var genreHints: [String]         // e.g. ["operatic", "romantic", "through-composed"]
}

/// A named musical motif registered from selected notes, with pitch/rhythm snapshots.
struct Leitmotif: Identifiable, Codable, Sendable {
    var id: UUID
    var name: String
    var noteIDs: [UUID]              // original note IDs in the piano roll
    var pitchPattern: [Int]          // MIDI pitches (snapshot for transformation)
    var rhythmPattern: [Int]         // durations in ticks
    var intervalPattern: [Int]       // intervals between consecutive notes

    init(
        id: UUID = UUID(),
        name: String,
        noteIDs: [UUID],
        pitchPattern: [Int],
        rhythmPattern: [Int],
        intervalPattern: [Int]
    ) {
        self.id = id
        self.name = name
        self.noteIDs = noteIDs
        self.pitchPattern = pitchPattern
        self.rhythmPattern = rhythmPattern
        self.intervalPattern = intervalPattern
    }
}

/// Motif variation types for leitmotif transformations.
enum VariationType: String, Codable, Sendable, CaseIterable {
    case inversion
    case retrograde
    case augmentation
    case diminution
    case transposition

    var displayName: String {
        switch self {
        case .inversion:     return "Inversion"
        case .retrograde:    return "Retrograde"
        case .augmentation:  return "Augmentation"
        case .diminution:    return "Diminution"
        case .transposition: return "Transposition"
        }
    }
}

/// Constraints for algorithmic melody generation.
struct MelodyConstraints: Sendable {
    var key: DetectedKey
    var pitchRange: ClosedRange<Int>     // e.g. 60...84 (C4–C6)
    var durationBeats: Double            // total length
    var contour: MelodicContour          // desired shape
    var noteDensity: Double              // notes per beat (default ~2.0)
    var startTick: Int                   // where to place the generated melody
    var ticksPerQuarter: Int
    var channel: Int                     // MIDI channel for generated notes
    var trackIndex: Int
    var velocity: Int                    // default velocity (e.g. 80)
}
