import AudioToolbox
import Foundation

// MARK: - Helpers

extension String {
    /// Converts an ALL-CAPS or mixed-case string to Title Case,
    /// preserving leading numeric prefixes (e.g. "01 OVERTURE" → "01 Overture").
    func toTitleCase() -> String {
        let words = self.split(separator: " ")
        return words.map { word in
            let s = String(word)
            // Keep purely numeric tokens as-is (e.g. "01", "2025")
            if s.allSatisfy(\.isNumber) { return s }
            return s.prefix(1).uppercased() + s.dropFirst().lowercased()
        }.joined(separator: " ")
    }
}

// MARK: - Song Stub (lightweight placeholder for progressive loading)

struct SongStub: Identifiable {
    let id: UUID
    let fileURL: URL
    let relativePath: String
    let fileSize: Int64

    var displayName: String {
        let url = URL(fileURLWithPath: relativePath)
        let withoutExtension = url.deletingPathExtension().lastPathComponent
        return withoutExtension.isEmpty ? url.lastPathComponent : withoutExtension
    }
}

// MARK: - Project Metadata

struct ProjectMetadata: Codable {
    var name: String
    var createdAt: Date
    var updatedAt: Date
    var notes: String
    var projectVersions: [ProjectVersionEntry]

    private enum CodingKeys: String, CodingKey {
        case name, createdAt, updatedAt, notes, projectVersions
    }

    init(name: String, createdAt: Date, updatedAt: Date, notes: String, projectVersions: [ProjectVersionEntry] = []) {
        self.name = name
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.notes = notes
        self.projectVersions = projectVersions
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        notes = try container.decodeIfPresent(String.self, forKey: .notes) ?? ""
        projectVersions = try container.decodeIfPresent([ProjectVersionEntry].self, forKey: .projectVersions) ?? []
    }

    static func fresh(named name: String) -> ProjectMetadata {
        .init(name: name, createdAt: Date(), updatedAt: Date(), notes: "")
    }
}

// MARK: - Project-Level Version History

struct ProjectVersionEntry: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var label: String
    var userLabel: String?
    var saveType: VersionSaveType
    var isBookmarked: Bool
    var createdAt: Date
    var updatedAt: Date
    var songVersionMap: [String: UUID]  // songRelativePath -> OWSVersionPayload.id

    var displayName: String {
        userLabel ?? label
    }
}

struct ProjectTextFile: Identifiable, Hashable {
    let id: UUID
    var relativePath: String
    var content: String

    var displayName: String {
        let url = URL(fileURLWithPath: relativePath)
        let withoutExtension = url.deletingPathExtension().lastPathComponent
        return withoutExtension.isEmpty ? url.lastPathComponent : withoutExtension
    }
}

struct MidiAsset: Identifiable, Hashable {
    let id: UUID
    var relativePath: String
    var data: Data
    var title: String? = nil

    var displayName: String {
        let trimmedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedTitle.isEmpty {
            return trimmedTitle
        }
        let url = URL(fileURLWithPath: relativePath)
        let withoutExtension = url.deletingPathExtension().lastPathComponent
        let name = withoutExtension.isEmpty ? url.lastPathComponent : withoutExtension
        return name.toTitleCase()
    }
}

struct CueMapping: Identifiable, Codable, Hashable {
    let id: UUID
    var sectionPath: String
    var midiPath: String?
    var notes: String

    init(id: UUID = UUID(), sectionPath: String, midiPath: String?, notes: String = "") {
        self.id = id
        self.sectionPath = sectionPath
        self.midiPath = midiPath
        self.notes = notes
    }
}

struct PianoRollNote: Identifiable, Codable, Hashable {
    var id: UUID
    var trackIndex: Int
    var channel: Int
    var pitch: Int
    var velocity: Int
    var startTick: Int
    var duration: Int
    var muted: Bool
    var lyricSyllable: String?
    var articulationID: UUID?

    init(
        id: UUID = UUID(),
        trackIndex: Int,
        channel: Int,
        pitch: Int,
        velocity: Int,
        startTick: Int,
        duration: Int,
        muted: Bool = false,
        lyricSyllable: String? = nil,
        articulationID: UUID? = nil
    ) {
        self.id = id
        self.trackIndex = trackIndex
        self.channel = channel
        self.pitch = min(max(pitch, 0), 127)
        self.velocity = min(max(velocity, 1), 127)
        self.startTick = startTick
        self.duration = max(1, duration)
        self.muted = muted
        self.lyricSyllable = lyricSyllable
        self.articulationID = articulationID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        trackIndex = try container.decode(Int.self, forKey: .trackIndex)
        channel = try container.decode(Int.self, forKey: .channel)
        pitch = min(max(try container.decode(Int.self, forKey: .pitch), 0), 127)
        velocity = min(max(try container.decode(Int.self, forKey: .velocity), 1), 127)
        startTick = try container.decode(Int.self, forKey: .startTick)
        duration = max(1, try container.decode(Int.self, forKey: .duration))
        muted = try container.decodeIfPresent(Bool.self, forKey: .muted) ?? false
        lyricSyllable = try container.decodeIfPresent(String.self, forKey: .lyricSyllable)
        articulationID = try container.decodeIfPresent(UUID.self, forKey: .articulationID)
    }
}

/// An articulation entry in an expression map. Links a display name to a
/// key-switch pitch or CC value used to trigger it during playback.
struct ArticulationEntry: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String              // e.g. "Legato", "Staccato", "Pizzicato"
    var shortName: String         // e.g. "leg", "stac", "pizz"
    var keySwitchPitch: Int?      // MIDI note to send before the sounding note
    var ccNumber: Int?            // CC number to send (alternative to keyswitch)
    var ccValue: Int?             // CC value to send
    var colorHex: String?

    init(
        id: UUID = UUID(),
        name: String,
        shortName: String = "",
        keySwitchPitch: Int? = nil,
        ccNumber: Int? = nil,
        ccValue: Int? = nil,
        colorHex: String? = nil
    ) {
        self.id = id
        self.name = name
        self.shortName = shortName.isEmpty ? String(name.prefix(4).lowercased()) : shortName
        self.keySwitchPitch = keySwitchPitch
        self.ccNumber = ccNumber
        self.ccValue = ccValue
        self.colorHex = colorHex
    }
}

/// An expression map: a named collection of articulation entries.
struct ExpressionMap: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var articulations: [ArticulationEntry]

    init(id: UUID = UUID(), name: String, articulations: [ArticulationEntry] = []) {
        self.id = id
        self.name = name
        self.articulations = articulations
    }

    /// Built-in default expression map with common orchestral articulations.
    static let orchestralDefault = ExpressionMap(
        name: "Orchestral Default",
        articulations: [
            ArticulationEntry(name: "Natural", shortName: "nat", colorHex: "88AACC"),
            ArticulationEntry(name: "Legato", shortName: "leg", keySwitchPitch: 24, colorHex: "66CC66"),
            ArticulationEntry(name: "Staccato", shortName: "stac", keySwitchPitch: 25, colorHex: "CC6666"),
            ArticulationEntry(name: "Pizzicato", shortName: "pizz", keySwitchPitch: 26, colorHex: "CC9944"),
            ArticulationEntry(name: "Tremolo", shortName: "trem", keySwitchPitch: 27, colorHex: "9966CC"),
            ArticulationEntry(name: "Marcato", shortName: "marc", keySwitchPitch: 28, colorHex: "CCCC44"),
            ArticulationEntry(name: "Spiccato", shortName: "spic", keySwitchPitch: 29, colorHex: "44CCCC"),
        ]
    )
}

struct NoteGroup: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var noteIDs: [UUID]
    var colorHex: String?

    init(id: UUID = UUID(), name: String, noteIDs: [UUID], colorHex: String? = nil) {
        self.id = id
        self.name = name
        self.noteIDs = noteIDs
        self.colorHex = colorHex
    }
}

// MARK: - Score Annotations

/// A text annotation placed on the score (dynamics, tempo, expression text).
struct ScoreAnnotation: Identifiable, Codable, Hashable {
    var id: UUID
    var tick: Int
    var text: String
    var kind: ScoreAnnotationKind
    var trackIndex: Int?  // nil = applies to all staves

    init(id: UUID = UUID(), tick: Int, text: String, kind: ScoreAnnotationKind = .expression, trackIndex: Int? = nil) {
        self.id = id
        self.tick = tick
        self.text = text
        self.kind = kind
        self.trackIndex = trackIndex
    }
}

enum ScoreAnnotationKind: String, Codable, CaseIterable, Identifiable {
    case dynamic     // ppp, pp, p, mp, mf, f, ff, fff, sfz, fp
    case tempo       // "Allegro", "rit.", "a tempo"
    case expression  // "con brio", "dolce", "legato"
    case rehearsal   // "A", "B" (alternative to rehearsal marks)

    var id: String { rawValue }

    var displayFont: (size: CGFloat, italic: Bool, bold: Bool) {
        switch self {
        case .dynamic:    return (14, true, true)
        case .tempo:      return (11, false, true)
        case .expression: return (10, true, false)
        case .rehearsal:  return (12, false, true)
        }
    }
}

enum TrackRole: String, Codable, CaseIterable, Identifiable {
    case instrument
    case vocal

    var id: String { rawValue }

    var title: String {
        switch self {
        case .instrument:
            return "Instrument"
        case .vocal:
            return "Vocal"
        }
    }
}

enum VocalGender: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case male
    case female

    var id: String { rawValue }

    var title: String {
        rawValue.capitalized
    }
}

enum PlaybackRenderMode: String, Codable, CaseIterable, Identifiable {
    case midi = "MIDI"
    case audio = "Audio"
    case both = "Both"

    var id: String { rawValue }

    var includesMIDI: Bool {
        self != .audio
    }

    var includesAudio: Bool {
        self != .midi
    }
}

enum PlayheadFollowMode: String, CaseIterable, Identifiable {
    case off = "Off"
    case center = "Center"
    case page = "Page"

    var id: String { rawValue }
}

struct LyricCue: Identifiable, Codable, Hashable {
    var id: UUID
    var trackKey: String
    var tick: Int
    var durationTicks: Int
    var text: String

    init(
        id: UUID = UUID(),
        trackKey: String,
        tick: Int,
        durationTicks: Int = 480,
        text: String
    ) {
        self.id = id
        self.trackKey = trackKey
        self.tick = max(0, tick)
        self.durationTicks = max(1, durationTicks)
        self.text = text
    }
}

// MARK: - Lyric Alignment (Phase 3)

/// A single mapping entry linking a tokenized lyric syllable to a piano roll note.
/// Used for bidirectional sync between the libretto sidebar and the lyrics lane.
struct LyricAlignmentEntry: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    /// Index into the tokenized word list from the libretto text.
    var wordIndex: Int
    /// Stable token identity for the target lyric word (preferred over positional index).
    var tokenID: UUID?
    /// Syllable index within the word (0-based). `-1` means whole-word mapping.
    var syllableIndex: Int
    /// The PianoRollNote this syllable is bound to.
    var noteID: UUID
    /// Whether a human has reviewed/confirmed this mapping (vs. AI-suggested).
    var confirmed: Bool

    init(
        id: UUID = UUID(),
        wordIndex: Int,
        tokenID: UUID? = nil,
        syllableIndex: Int,
        noteID: UUID,
        confirmed: Bool = false
    ) {
        self.id = id
        self.wordIndex = wordIndex
        self.tokenID = tokenID
        self.syllableIndex = syllableIndex
        self.noteID = noteID
        self.confirmed = confirmed
    }
}

/// A complete alignment mapping for one vocal track in one song.
/// Keeps the libretto text clean — alignment metadata lives here, not inline.
struct LyricAlignment: Codable, Hashable, Sendable {
    /// Relative path of the song this alignment belongs to.
    var songPath: String
    /// The instrument mapping key for the vocal track.
    var trackKey: String
    /// Ordered entries mapping syllable positions to note IDs.
    var entries: [LyricAlignmentEntry]

    /// Fraction of syllables that have been aligned (0.0–1.0).
    var coverage: Double {
        guard !entries.isEmpty else { return 0 }
        let confirmed = entries.filter(\.confirmed).count
        return Double(confirmed) / Double(entries.count)
    }
}

struct AudioClip: Identifiable, Codable, Hashable {
    var id: UUID
    var displayName: String
    var filePath: String
    var trackKey: String?
    var trackID: UUID?         // MixTrack UUID for per-track submix routing
    var startTick: Int
    var durationTicks: Int
    var offsetTicks: Int       // how far into the source audio to start playing (for trimmed/split clips)
    var gainDB: Double
    var pan: Double            // -1.0 (full left) to 1.0 (full right)
    var muted: Bool
    var fadeInTicks: Int       // fade-in duration in ticks (0 = no fade)
    var fadeOutTicks: Int      // fade-out duration in ticks (0 = no fade)
    var fadeInExponent: Double // curve exponent: 1.0 = linear, <1 = log, >1 = exp
    var fadeOutExponent: Double
    var stretchRatio: Double   // 1.0 = natural speed, >1 = longer, <1 = shorter
    var pitchCents: Float      // total pitch shift in cents (semitones*100 + fine cents)

    init(
        id: UUID = UUID(),
        displayName: String,
        filePath: String,
        trackKey: String? = nil,
        trackID: UUID? = nil,
        startTick: Int = 0,
        durationTicks: Int = 1920,
        offsetTicks: Int = 0,
        gainDB: Double = 0,
        pan: Double = 0,
        muted: Bool = false,
        fadeInTicks: Int = 0,
        fadeOutTicks: Int = 0,
        fadeInExponent: Double = 1.0,
        fadeOutExponent: Double = 1.0,
        stretchRatio: Double = 1.0,
        pitchCents: Float = 0
    ) {
        self.id = id
        self.displayName = displayName
        self.filePath = filePath
        self.trackKey = trackKey
        self.trackID = trackID
        self.startTick = max(0, startTick)
        self.durationTicks = max(1, durationTicks)
        self.offsetTicks = max(0, offsetTicks)
        self.gainDB = min(max(gainDB, -24), 12)
        self.pan = min(max(pan, -1), 1)
        self.muted = muted
        self.fadeInTicks = max(0, fadeInTicks)
        self.fadeOutTicks = max(0, fadeOutTicks)
        self.fadeInExponent = min(max(fadeInExponent, 0.1), 4.0)
        self.fadeOutExponent = min(max(fadeOutExponent, 0.1), 4.0)
        self.stretchRatio = min(max(stretchRatio, 0.25), 4.0)
        self.pitchCents = min(max(pitchCents, -2400), 2400)
    }
}

struct TempoPoint: Codable, Hashable, Identifiable {
    var tick: Int
    var bpm: Double

    var id: String {
        "\(tick)-\(Int((bpm * 1000).rounded()))"
    }
}

/// A single piano roll automation point: tick position, normalized value, and unique ID.
struct PianoRollAutoPoint: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    var tick: Int
    var value: Double  // Normalized 0.0–1.0 (maps to type-specific range)

    init(id: UUID = UUID(), tick: Int, value: Double) {
        self.id = id
        self.tick = max(0, tick)
        self.value = min(1.0, max(0.0, value))
    }
}

/// Type of MIDI automation lane for the piano roll.
enum AutomationLaneType: String, CaseIterable, Codable, Identifiable, Sendable {
    case pitchBend = "Pitch Bend"
    case cc1Modulation = "CC1 Modulation"
    case cc7Volume = "CC7 Volume"
    case cc10Pan = "CC10 Pan"
    case cc11Expression = "CC11 Expression"
    case cc64Sustain = "CC64 Sustain"
    case aftertouch = "Aftertouch"

    var id: String { rawValue }

    /// MIDI CC number (nil for pitch bend / aftertouch).
    var ccNumber: Int? {
        switch self {
        case .pitchBend, .aftertouch: return nil
        case .cc1Modulation: return 1
        case .cc7Volume: return 7
        case .cc10Pan: return 10
        case .cc11Expression: return 11
        case .cc64Sustain: return 64
        }
    }

    /// Maximum value in MIDI units.
    var maxMidiValue: Int {
        switch self {
        case .pitchBend: return 16383
        default: return 127
        }
    }

    /// Center value for bipolar types (pitch bend). Nil for unipolar.
    var centerValue: Int? {
        switch self {
        case .pitchBend: return 8192
        case .cc10Pan: return 64
        default: return nil
        }
    }

    /// Convert normalized 0–1 to MIDI value.
    func midiValue(fromNormalized v: Double) -> Int {
        Int((v * Double(maxMidiValue)).rounded())
    }

    /// Convert MIDI value to normalized 0–1.
    func normalized(fromMidi midi: Int) -> Double {
        Double(midi) / Double(max(1, maxMidiValue))
    }

    /// Display string for a normalized value.
    func displayString(forNormalized v: Double) -> String {
        let midi = midiValue(fromNormalized: v)
        switch self {
        case .pitchBend: return "\(midi - 8192)"
        case .cc64Sustain: return midi >= 64 ? "On" : "Off"
        default: return "\(midi)"
        }
    }
}

/// Keyed storage for all piano roll automation lanes.
struct PianoRollAutomationData: Codable, Hashable, Sendable {
    var lanes: [String: [PianoRollAutoPoint]] = [:]

    func points(for type: AutomationLaneType) -> [PianoRollAutoPoint] {
        (lanes[type.rawValue] ?? []).sorted(by: { $0.tick < $1.tick })
    }

    mutating func setPoints(_ points: [PianoRollAutoPoint], for type: AutomationLaneType) {
        lanes[type.rawValue] = points.sorted(by: { $0.tick < $1.tick })
    }
}

struct PianoRollOverride: Codable {
    var midiPath: String
    var notes: [PianoRollNote]
    var lengthTicks: Int
    var ticksPerQuarter: Int
}

/// Describes what kind of instrument source is assigned to a mapping.
enum InstrumentSourceType: String, Codable, Hashable, Sendable {
    /// Apple AVAudioUnitSampler playing a SoundFont (.sf2/.sf3/.dls) file.
    case soundFont
    /// A system-installed Audio Unit instrument plugin (v3 or v2 wrapped).
    case audioUnit
}

struct InstrumentMapping: Identifiable, Codable, Hashable {
    var id: UUID
    var channelKey: String
    var songPath: String?
    var displayName: String
    var trackRoleRaw: String?
    var builtInInstrumentID: String?

    // MARK: - Instrument Source
    var instrumentSourceType: InstrumentSourceType?  // nil defaults to .soundFont for backward compat
    var sf2Path: String?
    /// Backup copy of the SF2 filename for fallback search if absolute path breaks.
    var sf2FileName: String?
    /// Audio Unit component identifiers (used when instrumentSourceType == .audioUnit)
    var auComponentType: UInt32?
    var auComponentSubType: UInt32?
    var auComponentManufacturer: UInt32?
    var auPresetData: Data?  // serialized AU preset state

    var colorHex: String?
    var bankMSB: Int
    var bankLSB: Int
    var program: Int
    var gainDB: Double
    var muted: Bool
    var sortOrder: Int?

    // MARK: - Voice Synthesis (vocal tracks only)
    var vocalGender: VocalGender?
    var voiceType: VoicePart?           // Soprano/Alto/Tenor/Bass assignment for vocal tracks
    var synthEngine: String?            // "mbrola" (kept for backward compat, ignored at runtime)
    var voiceID: String?                // Voice database: "us1", "us2" (MBROLA)
    var voiceGainDB: Double?            // Rendered vocal gain, default 0.0 (range -12 to +12)
    var vibratoDepth: Double?           // Vibrato depth in cents, default 25, range 0-100
    var vibratoRate: Double?            // Vibrato rate in Hz, default 5.5, range 3-8

    // MARK: - Dual Instrument Assignment
    /// Nested SoundFont assignment (replaces flat sf2Path/bankMSB/etc.)
    var soundFont: SoundFontAssignment?
    /// Nested Audio Unit assignment (replaces flat auComponentType/etc.)
    var audioUnit: AudioUnitAssignment?
    /// Which source is currently active for playback
    var activeSource: InstrumentSourceType = .soundFont
    /// Per-track override — nil means follow master toggle
    var pinnedSource: InstrumentSourceType?

    /// Effective source considering pinned override
    var effectiveSource: InstrumentSourceType {
        pinnedSource ?? activeSource
    }

    var inferredVocalGender: VocalGender? {
        if let vocalGender { return vocalGender }

        switch voiceType {
        case .tenor?, .bass?:
            return .male
        case .soprano?, .alto?:
            return .female
        case nil:
            break
        }

        switch voiceID?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "us1", "male":
            return .male
        case "us2", "female":
            return .female
        default:
            return nil
        }
    }

    var resolvedVocalGender: VocalGender {
        vocalGender ?? inferredVocalGender ?? .male
    }

    /// True when the track can't fully participate in source toggling
    var isIncomplete: Bool {
        switch effectiveSource {
        case .soundFont: return soundFont == nil
        case .audioUnit: return audioUnit == nil
        }
    }

    /// True when only one of the two slots is filled
    var isMissingAlternateSource: Bool {
        soundFont == nil || audioUnit == nil
    }

    /// The effective source type — defaults to .soundFont if nil (backward compat).
    var effectiveSourceType: InstrumentSourceType {
        instrumentSourceType ?? .soundFont
    }

    /// AudioComponentDescription for Audio Unit loading. Nil if not an AU mapping.
    var audioComponentDescription: AudioComponentDescription? {
        guard effectiveSourceType == .audioUnit,
              let type = auComponentType,
              let subType = auComponentSubType,
              let mfr = auComponentManufacturer else { return nil }
        return AudioComponentDescription(
            componentType: type,
            componentSubType: subType,
            componentManufacturer: mfr,
            componentFlags: 0,
            componentFlagsMask: 0
        )
    }

    init(
        id: UUID = UUID(),
        channelKey: String,
        songPath: String? = nil,
        displayName: String,
        trackRole: TrackRole = .instrument,
        builtInInstrumentID: String? = nil,
        instrumentSourceType: InstrumentSourceType? = nil,
        sf2Path: String? = nil,
        sf2FileName: String? = nil,
        auComponentType: UInt32? = nil,
        auComponentSubType: UInt32? = nil,
        auComponentManufacturer: UInt32? = nil,
        auPresetData: Data? = nil,
        colorHex: String? = nil,
        bankMSB: Int = 0,
        bankLSB: Int = 0,
        program: Int = 0,
        gainDB: Double = 0,
        muted: Bool = false,
        sortOrder: Int? = nil,
        vocalGender: VocalGender? = nil,
        synthEngine: String? = nil,
        voiceID: String? = nil,
        voiceGainDB: Double? = nil,
        vibratoDepth: Double? = nil,
        vibratoRate: Double? = nil
    ) {
        self.id = id
        self.channelKey = channelKey
        self.songPath = songPath
        self.displayName = displayName
        self.trackRoleRaw = trackRole.rawValue
        self.builtInInstrumentID = builtInInstrumentID
        self.instrumentSourceType = instrumentSourceType
        self.sf2Path = sf2Path
        self.sf2FileName = sf2FileName ?? (sf2Path as NSString?)?.lastPathComponent
        self.auComponentType = auComponentType
        self.auComponentSubType = auComponentSubType
        self.auComponentManufacturer = auComponentManufacturer
        self.auPresetData = auPresetData
        self.colorHex = colorHex
        self.bankMSB = min(max(bankMSB, 0), 127)
        self.bankLSB = min(max(bankLSB, 0), 127)
        self.program = min(max(program, 0), 127)
        self.gainDB = min(max(gainDB, -24), 12)
        self.muted = muted
        self.sortOrder = sortOrder
        self.vocalGender = vocalGender
        self.synthEngine = synthEngine
        self.voiceID = voiceID
        self.voiceGainDB = voiceGainDB
        self.vibratoDepth = vibratoDepth
        self.vibratoRate = vibratoRate
    }

    var trackRole: TrackRole {
        get {
            TrackRole(rawValue: trackRoleRaw ?? "") ?? .instrument
        }
        set {
            trackRoleRaw = newValue.rawValue
        }
    }

    /// Canonical instrument order matching the V5 FLP standard arrangement.
    /// Maps display names to sort indices.
    static let canonicalOrder: [String: Int] = [
        "Amira": 0, "Luke": 1, "Johnny": 2,
        "Flutes": 3, "Oboes": 4, "Clarinets": 5, "Bassoons": 6,
        "French Horns": 7, "Trumpets": 8, "Trombones": 9, "Tuba": 10,
        "Timpani": 11, "Percussion": 12, "Bells/Celesta": 13,
        "Harp": 14, "Piano": 15, "Organ": 16,
        "Violins I": 17, "Violins II": 18, "Violas": 19, "Cellos": 20, "Double Basses": 21,
    ]

    /// Returns the effective sort order: explicit sortOrder, then canonical lookup, then Int.max.
    var effectiveSortOrder: Int {
        if let so = sortOrder { return so }
        if let canonical = Self.canonicalOrder[displayName] { return canonical }
        return Int.max
    }

    // MARK: - Migration Decoder

    private enum CodingKeys: String, CodingKey {
        case id, channelKey, songPath, displayName, trackRoleRaw
        case builtInInstrumentID, sf2Path, sf2FileName, colorHex
        case instrumentSourceType
        case auComponentType, auComponentSubType, auComponentManufacturer, auPresetData
        case bankMSB, bankLSB, program, gainDB, muted, sortOrder
        case vocalGender, synthEngine, voiceID, voiceGainDB, vibratoDepth, vibratoRate
        case soundFont, audioUnit, activeSource, pinnedSource
        // Legacy keys for migration
        case voicePresetID, voiceSpeed
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        channelKey = try c.decode(String.self, forKey: .channelKey)
        songPath = try c.decodeIfPresent(String.self, forKey: .songPath)
        displayName = try c.decode(String.self, forKey: .displayName)
        trackRoleRaw = try c.decodeIfPresent(String.self, forKey: .trackRoleRaw)
        builtInInstrumentID = try c.decodeIfPresent(String.self, forKey: .builtInInstrumentID)

        // Instrument source type (nil = legacy soundFont)
        instrumentSourceType = try c.decodeIfPresent(InstrumentSourceType.self, forKey: .instrumentSourceType)

        sf2Path = try c.decodeIfPresent(String.self, forKey: .sf2Path)
        sf2FileName = try c.decodeIfPresent(String.self, forKey: .sf2FileName)
        // Migration: derive sf2FileName from sf2Path if not present
        if sf2FileName == nil, let path = sf2Path, !path.isEmpty {
            sf2FileName = (path as NSString).lastPathComponent
        }

        // Audio Unit fields
        auComponentType = try c.decodeIfPresent(UInt32.self, forKey: .auComponentType)
        auComponentSubType = try c.decodeIfPresent(UInt32.self, forKey: .auComponentSubType)
        auComponentManufacturer = try c.decodeIfPresent(UInt32.self, forKey: .auComponentManufacturer)
        auPresetData = try c.decodeIfPresent(Data.self, forKey: .auPresetData)

        colorHex = try c.decodeIfPresent(String.self, forKey: .colorHex)
        bankMSB = min(max(try c.decodeIfPresent(Int.self, forKey: .bankMSB) ?? 0, 0), 127)
        bankLSB = min(max(try c.decodeIfPresent(Int.self, forKey: .bankLSB) ?? 0, 0), 127)
        program = min(max(try c.decodeIfPresent(Int.self, forKey: .program) ?? 0, 0), 127)
        gainDB = min(max(try c.decodeIfPresent(Double.self, forKey: .gainDB) ?? 0, -24), 12)
        muted = try c.decodeIfPresent(Bool.self, forKey: .muted) ?? false
        sortOrder = try c.decodeIfPresent(Int.self, forKey: .sortOrder)

        // Voice fields
        vocalGender = try c.decodeIfPresent(VocalGender.self, forKey: .vocalGender)
        synthEngine = try c.decodeIfPresent(String.self, forKey: .synthEngine)
        voiceID = try c.decodeIfPresent(String.self, forKey: .voiceID)
        voiceGainDB = try c.decodeIfPresent(Double.self, forKey: .voiceGainDB)
        vibratoDepth = try c.decodeIfPresent(Double.self, forKey: .vibratoDepth)
        vibratoRate = try c.decodeIfPresent(Double.self, forKey: .vibratoRate)

        // Migration: if old voicePresetID exists but new fields don't, set defaults
        if synthEngine == nil, let oldPreset = try? c.decodeIfPresent(String.self, forKey: .voicePresetID) {
            synthEngine = "mbrola"
            if oldPreset.hasPrefix("am") || oldPreset.hasPrefix("bm") {
                voiceID = "us2"
            } else {
                voiceID = "us1"
            }
        }

        // Dual instrument assignment fields
        soundFont = try c.decodeIfPresent(SoundFontAssignment.self, forKey: .soundFont)
        audioUnit = try c.decodeIfPresent(AudioUnitAssignment.self, forKey: .audioUnit)
        activeSource = try c.decodeIfPresent(InstrumentSourceType.self, forKey: .activeSource) ?? .soundFont
        pinnedSource = try c.decodeIfPresent(InstrumentSourceType.self, forKey: .pinnedSource)

        // Migration: if new nested fields are absent, synthesize from legacy flat fields
        if soundFont == nil {
            let legacyPath = sf2Path ?? ""
            let legacyFileName = sf2FileName
            if !legacyPath.isEmpty || legacyFileName != nil {
                soundFont = SoundFontAssignment(
                    sf2RelativePath: nil,  // legacy paths are absolute
                    sf2FileName: legacyFileName,
                    resolvedPath: legacyPath.isEmpty ? nil : legacyPath,
                    bankMSB: bankMSB,
                    bankLSB: bankLSB,
                    program: program
                )
            }
        }

        if audioUnit == nil {
            if let auType = auComponentType,
               let auSubType = auComponentSubType,
               let auManuf = auComponentManufacturer {
                audioUnit = AudioUnitAssignment(
                    componentType: auType,
                    componentSubType: auSubType,
                    componentManufacturer: auManuf,
                    presetData: auPresetData
                )
            }
        }

        // If no activeSource was decoded, infer from legacy instrumentSourceType
        if !c.contains(.activeSource) {
            if let legacyType = instrumentSourceType {
                activeSource = legacyType
            }
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(channelKey, forKey: .channelKey)
        try c.encodeIfPresent(songPath, forKey: .songPath)
        try c.encode(displayName, forKey: .displayName)
        try c.encodeIfPresent(trackRoleRaw, forKey: .trackRoleRaw)
        try c.encodeIfPresent(builtInInstrumentID, forKey: .builtInInstrumentID)
        try c.encodeIfPresent(instrumentSourceType, forKey: .instrumentSourceType)
        let persistedSF2Path = soundFont?.sf2RelativePath ?? sf2Path
        let persistedSF2FileName =
            soundFont?.sf2FileName
            ?? sf2FileName
            ?? (persistedSF2Path as NSString?)?.lastPathComponent
        try c.encodeIfPresent(persistedSF2Path, forKey: .sf2Path)
        try c.encodeIfPresent(persistedSF2FileName, forKey: .sf2FileName)
        try c.encodeIfPresent(auComponentType, forKey: .auComponentType)
        try c.encodeIfPresent(auComponentSubType, forKey: .auComponentSubType)
        try c.encodeIfPresent(auComponentManufacturer, forKey: .auComponentManufacturer)
        try c.encodeIfPresent(auPresetData, forKey: .auPresetData)
        try c.encodeIfPresent(colorHex, forKey: .colorHex)
        try c.encode(bankMSB, forKey: .bankMSB)
        try c.encode(bankLSB, forKey: .bankLSB)
        try c.encode(program, forKey: .program)
        try c.encode(gainDB, forKey: .gainDB)
        try c.encode(muted, forKey: .muted)
        try c.encodeIfPresent(sortOrder, forKey: .sortOrder)
        try c.encodeIfPresent(vocalGender, forKey: .vocalGender)
        try c.encodeIfPresent(synthEngine, forKey: .synthEngine)
        try c.encodeIfPresent(voiceID, forKey: .voiceID)
        try c.encodeIfPresent(voiceGainDB, forKey: .voiceGainDB)
        try c.encodeIfPresent(vibratoDepth, forKey: .vibratoDepth)
        try c.encodeIfPresent(vibratoRate, forKey: .vibratoRate)
        try c.encodeIfPresent(soundFont, forKey: .soundFont)
        try c.encodeIfPresent(audioUnit, forKey: .audioUnit)
        try c.encode(activeSource, forKey: .activeSource)
        try c.encodeIfPresent(pinnedSource, forKey: .pinnedSource)
    }

    // MARK: - Master Toggle

    /// Apply master instrument mode to all unpinned mappings.
    static func applyMasterToggle(
        to mappings: inout [String: InstrumentMapping],
        mode: InstrumentSourceType
    ) {
        for key in mappings.keys {
            guard mappings[key]?.pinnedSource == nil else { continue }
            switch mode {
            case .soundFont:
                if mappings[key]?.soundFont != nil {
                    mappings[key]?.activeSource = .soundFont
                    mappings[key]?.instrumentSourceType = .soundFont
                }
            case .audioUnit:
                if mappings[key]?.audioUnit != nil {
                    mappings[key]?.activeSource = .audioUnit
                    mappings[key]?.instrumentSourceType = .audioUnit
                }
            }
        }
    }
}

struct ProjectChannelProfile: Identifiable, Hashable {
    let id: UUID
    let key: String
    let baseKey: String
    var displayName: String
    var aliases: [String]
    var songPaths: [String]
    var midiChannels: [Int]
    var defaultProgram: Int?
    var sortOrder: Int?

    /// Returns the effective sort order: explicit, then canonical lookup, then Int.max.
    var effectiveSortOrder: Int {
        if let so = sortOrder { return so }
        if let canonical = InstrumentMapping.canonicalOrder[displayName] { return canonical }
        return Int.max
    }
}

// MARK: - Piano Roll

struct ParsedPianoRoll {
    var trackNames: [Int: String]
    var channelPrograms: [Int: Int]
    var trackChannelPrograms: [Int: [Int: Int]]
    var notes: [PianoRollNote]
    var tempoEvents: [TempoPoint]
    var initialTempoBPM: Double
    var ticksPerQuarter: Int
    var lengthTicks: Int
    var timeSignatureEvents: [(tick: Int, numerator: Int, denominator: Int)] = []
    var keySignatureEvents: [(tick: Int, sharpsFlats: Int, isMinor: Bool)] = []
    /// MIDI FF 05 lyric events extracted during import.
    var lyricEvents: [(tick: Int, text: String, trackIndex: Int)] = []
}
