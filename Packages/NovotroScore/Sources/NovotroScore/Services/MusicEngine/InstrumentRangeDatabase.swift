import Foundation

// MARK: - InstrumentRangeDatabase

/// Static database of orchestral and vocal instrument profiles, providing
/// MIDI pitch ranges, comfortable ranges, transposition, GM program numbers,
/// and capabilities for all 22 instruments in Novotro Score's canonical order.
///
/// Profiles match `InstrumentMapping.canonicalOrder` names exactly.
enum InstrumentRangeDatabase {

    // MARK: - Types

    /// Classification of instrument families.
    enum InstrumentFamily: String, Sendable, CaseIterable {
        case vocal
        case woodwind
        case brass
        case percussion
        case keyboard
        case string
    }

    /// Performance capabilities an instrument supports.
    enum InstrumentCapability: String, Sendable, CaseIterable {
        case sustain
        case staccato
        case tremolo
        case pizzicato
        case arco
        case muted
        case glissando
        case trill
        case doubleStop
        case chord
    }

    /// Complete profile for one instrument.
    struct InstrumentProfile: Sendable {
        var name: String
        var midiProgramNumber: Int          // GM program number (-1 = no standard GM mapping)
        var absoluteRange: ClosedRange<Int> // full playable MIDI pitch range
        var comfortableRange: ClosedRange<Int>
        var transposition: Int              // semitones from concert pitch (0 = C, -2 = Bb, -7 = F)
        var isPolyphonic: Bool
        var capabilities: Set<InstrumentCapability>
        var family: InstrumentFamily
    }

    // MARK: - Public API

    /// Look up a profile by instrument display name (matches `InstrumentMapping.canonicalOrder`).
    static func profile(for name: String) -> InstrumentProfile? {
        profilesByName[name]
    }

    /// Look up a profile by GM program number (returns first match).
    static func profile(forGMProgram program: Int) -> InstrumentProfile? {
        allProfiles.first { $0.midiProgramNumber == program }
    }

    /// All 22 instrument profiles.
    static var allProfiles: [InstrumentProfile] {
        profiles
    }

    /// Clamp a MIDI pitch to the instrument's absolute range.
    /// Transposes by octaves if needed to bring the pitch in range.
    static func clampToRange(_ pitch: Int, instrument: String) -> Int {
        guard let prof = profilesByName[instrument] else { return pitch }
        let range = prof.absoluteRange
        if range.contains(pitch) { return pitch }

        // Try transposing by octaves toward the range.
        var p = pitch
        if p < range.lowerBound {
            while p < range.lowerBound { p += 12 }
        } else {
            while p > range.upperBound { p -= 12 }
        }
        // Final clamp in case octave transposition overshoots.
        return min(range.upperBound, max(range.lowerBound, p))
    }

    /// Check if a pitch is within the comfortable range.
    static func isInComfortableRange(_ pitch: Int, instrument: String) -> Bool {
        guard let prof = profilesByName[instrument] else { return true }
        return prof.comfortableRange.contains(pitch)
    }

    /// Transpose a pitch to the nearest octave within the instrument's comfortable range.
    static func transposeToComfortableRange(_ pitch: Int, instrument: String) -> Int {
        guard let prof = profilesByName[instrument] else { return pitch }
        let range = prof.comfortableRange
        if range.contains(pitch) { return pitch }

        var p = pitch
        if p < range.lowerBound {
            while p < range.lowerBound { p += 12 }
            // If we overshot, step back one octave if it's closer.
            if p > range.upperBound && (p - 12) >= prof.absoluteRange.lowerBound {
                p -= 12
            }
        } else {
            while p > range.upperBound { p -= 12 }
            if p < range.lowerBound && (p + 12) <= prof.absoluteRange.upperBound {
                p += 12
            }
        }
        return min(prof.absoluteRange.upperBound, max(prof.absoluteRange.lowerBound, p))
    }

    // MARK: - Profile Data

    private static let profiles: [InstrumentProfile] = [
        // ── Vocals ──────────────────────────────────────────────────────
        InstrumentProfile(
            name: "Amira",
            midiProgramNumber: -1,
            absoluteRange: 60...84,       // C4–C6 (soprano)
            comfortableRange: 62...79,    // D4–G5
            transposition: 0,
            isPolyphonic: false,
            capabilities: [.sustain],
            family: .vocal
        ),
        InstrumentProfile(
            name: "Luke",
            midiProgramNumber: -1,
            absoluteRange: 48...72,       // C3–C5 (tenor)
            comfortableRange: 50...69,    // D3–A4
            transposition: 0,
            isPolyphonic: false,
            capabilities: [.sustain],
            family: .vocal
        ),
        InstrumentProfile(
            name: "Johnny",
            midiProgramNumber: -1,
            absoluteRange: 41...67,       // F2–G4 (baritone)
            comfortableRange: 43...64,    // G2–E4
            transposition: 0,
            isPolyphonic: false,
            capabilities: [.sustain],
            family: .vocal
        ),

        // ── Woodwinds ───────────────────────────────────────────────────
        InstrumentProfile(
            name: "Flutes",
            midiProgramNumber: 73,
            absoluteRange: 60...96,       // C4–C7
            comfortableRange: 65...88,    // F4–E6
            transposition: 0,
            isPolyphonic: false,
            capabilities: [.sustain, .staccato, .trill, .tremolo],
            family: .woodwind
        ),
        InstrumentProfile(
            name: "Oboes",
            midiProgramNumber: 68,
            absoluteRange: 58...91,       // Bb3–G6
            comfortableRange: 60...84,    // C4–C6
            transposition: 0,
            isPolyphonic: false,
            capabilities: [.sustain, .staccato, .trill],
            family: .woodwind
        ),
        InstrumentProfile(
            name: "Clarinets",
            midiProgramNumber: 71,
            absoluteRange: 50...89,       // D3–F6 (concert pitch)
            comfortableRange: 52...84,    // E3–C6
            transposition: -2,            // Bb instrument
            isPolyphonic: false,
            capabilities: [.sustain, .staccato, .trill, .glissando],
            family: .woodwind
        ),
        InstrumentProfile(
            name: "Bassoons",
            midiProgramNumber: 70,
            absoluteRange: 34...72,       // Bb1–C5
            comfortableRange: 36...65,    // C2–F4
            transposition: 0,
            isPolyphonic: false,
            capabilities: [.sustain, .staccato, .trill],
            family: .woodwind
        ),

        // ── Brass ───────────────────────────────────────────────────────
        InstrumentProfile(
            name: "French Horns",
            midiProgramNumber: 60,
            absoluteRange: 34...77,       // Bb1–F5 (concert pitch)
            comfortableRange: 41...69,    // F2–A4
            transposition: -7,            // F instrument
            isPolyphonic: false,
            capabilities: [.sustain, .staccato, .muted],
            family: .brass
        ),
        InstrumentProfile(
            name: "Trumpets",
            midiProgramNumber: 56,
            absoluteRange: 55...82,       // G3–Bb5 (concert pitch)
            comfortableRange: 57...77,    // A3–F5
            transposition: -2,            // Bb instrument
            isPolyphonic: false,
            capabilities: [.sustain, .staccato, .muted, .trill],
            family: .brass
        ),
        InstrumentProfile(
            name: "Trombones",
            midiProgramNumber: 57,
            absoluteRange: 34...72,       // Bb1–C5
            comfortableRange: 40...65,    // E2–F4
            transposition: 0,
            isPolyphonic: false,
            capabilities: [.sustain, .staccato, .glissando, .muted],
            family: .brass
        ),
        InstrumentProfile(
            name: "Tuba",
            midiProgramNumber: 58,
            absoluteRange: 24...60,       // C1–C4
            comfortableRange: 28...53,    // E1–F3
            transposition: 0,
            isPolyphonic: false,
            capabilities: [.sustain, .staccato],
            family: .brass
        ),

        // ── Percussion ──────────────────────────────────────────────────
        InstrumentProfile(
            name: "Timpani",
            midiProgramNumber: -1,
            absoluteRange: 36...60,       // C2–C4
            comfortableRange: 40...55,    // E2–G3
            transposition: 0,
            isPolyphonic: true,
            capabilities: [.sustain, .tremolo],
            family: .percussion
        ),
        InstrumentProfile(
            name: "Percussion",
            midiProgramNumber: -1,
            absoluteRange: 35...81,       // GM percussion range
            comfortableRange: 35...81,
            transposition: 0,
            isPolyphonic: true,
            capabilities: [.staccato],
            family: .percussion
        ),
        InstrumentProfile(
            name: "Bells/Celesta",
            midiProgramNumber: 8,         // GM Celesta
            absoluteRange: 60...96,       // C4–C7
            comfortableRange: 65...91,    // F4–G6
            transposition: 0,
            isPolyphonic: true,
            capabilities: [.sustain, .staccato, .trill],
            family: .percussion
        ),

        // ── Keyboards ───────────────────────────────────────────────────
        InstrumentProfile(
            name: "Harp",
            midiProgramNumber: 46,
            absoluteRange: 24...103,      // C1–G7
            comfortableRange: 28...96,    // E1–C7
            transposition: 0,
            isPolyphonic: true,
            capabilities: [.sustain, .glissando, .chord],
            family: .keyboard
        ),
        InstrumentProfile(
            name: "Piano",
            midiProgramNumber: 0,
            absoluteRange: 21...108,      // A0–C8
            comfortableRange: 28...96,    // E1–C7
            transposition: 0,
            isPolyphonic: true,
            capabilities: [.sustain, .staccato, .chord, .trill, .tremolo],
            family: .keyboard
        ),
        InstrumentProfile(
            name: "Organ",
            midiProgramNumber: 19,        // GM Church Organ
            absoluteRange: 24...108,      // C1–C8
            comfortableRange: 36...96,    // C2–C7
            transposition: 0,
            isPolyphonic: true,
            capabilities: [.sustain, .chord, .tremolo],
            family: .keyboard
        ),

        // ── Strings ─────────────────────────────────────────────────────
        InstrumentProfile(
            name: "Violins I",
            midiProgramNumber: 40,
            absoluteRange: 55...100,      // G3–E7
            comfortableRange: 55...88,    // G3–E6
            transposition: 0,
            isPolyphonic: false,
            capabilities: [.sustain, .staccato, .tremolo, .pizzicato, .arco, .trill, .doubleStop],
            family: .string
        ),
        InstrumentProfile(
            name: "Violins II",
            midiProgramNumber: 40,
            absoluteRange: 55...100,      // G3–E7
            comfortableRange: 55...84,    // G3–C6
            transposition: 0,
            isPolyphonic: false,
            capabilities: [.sustain, .staccato, .tremolo, .pizzicato, .arco, .trill, .doubleStop],
            family: .string
        ),
        InstrumentProfile(
            name: "Violas",
            midiProgramNumber: 41,
            absoluteRange: 48...91,       // C3–G6
            comfortableRange: 48...81,    // C3–A5
            transposition: 0,
            isPolyphonic: false,
            capabilities: [.sustain, .staccato, .tremolo, .pizzicato, .arco, .trill],
            family: .string
        ),
        InstrumentProfile(
            name: "Cellos",
            midiProgramNumber: 42,
            absoluteRange: 36...76,       // C2–E5
            comfortableRange: 36...69,    // C2–A4
            transposition: 0,
            isPolyphonic: false,
            capabilities: [.sustain, .staccato, .tremolo, .pizzicato, .arco, .trill],
            family: .string
        ),
        InstrumentProfile(
            name: "Double Basses",
            midiProgramNumber: 43,
            absoluteRange: 24...60,       // C1–C4
            comfortableRange: 28...55,    // E1–G3
            transposition: 0,
            isPolyphonic: false,
            capabilities: [.sustain, .staccato, .pizzicato, .arco],
            family: .string
        ),
    ]

    /// Name → profile lookup dictionary for O(1) access.
    private static let profilesByName: [String: InstrumentProfile] = {
        Dictionary(uniqueKeysWithValues: profiles.map { ($0.name, $0) })
    }()
}
