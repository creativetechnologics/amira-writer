import Foundation

// MARK: - Script Card Models
//
// Structured sidecar that replaces wall-of-text bracket markup as the
// canonical source of direction/action/camera/tag data for the Write
// workspace. The .ows lyrics field stays untouched and human-readable;
// these cards live in `<project>/Metadata/script-cards.json`.
//
// Existing bracket DSL is supported by:
//   1. Importing legacy markup into cards on first open (transient, not
//      written back automatically — see ScriptCardImporter in WriteUI).
//   2. Exporting cards back to bracket DSL for downstream Animate
//      compatibility (see ScriptCardDSLExporter).
//
// Schema is versioned. Bump `ScriptDocumentCards.schemaVersion` and add a
// migration when fields change shape.

// MARK: - Root document

public struct ScriptDocumentCards: Codable, Sendable, Equatable {
    public static let currentSchemaVersion: Int = 1

    public var schemaVersion: Int
    /// Keyed by `ProjectTextFile.relativePath` (e.g. "Songs/Verse_One.ows").
    public var songs: [String: SongScriptCards]
    public var updatedAt: Date

    public init(
        schemaVersion: Int = ScriptDocumentCards.currentSchemaVersion,
        songs: [String: SongScriptCards] = [:],
        updatedAt: Date = Date()
    ) {
        self.schemaVersion = schemaVersion
        self.songs = songs
        self.updatedAt = updatedAt
    }
}

public struct SongScriptCards: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var songRelativePath: String
    public var scenes: [ScriptScene]
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        songRelativePath: String,
        scenes: [ScriptScene] = [],
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.songRelativePath = songRelativePath
        self.scenes = scenes
        self.updatedAt = updatedAt
    }
}

// MARK: - Scene

public struct ScriptScene: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    /// Optional human label, e.g. "Marketplace, dawn".
    public var label: String?
    /// Reference into the host song's lyrics.
    public var lyricAnchor: LyricAnchor?
    /// Numbered legacy direction cards: `[[1.01.0.001 - …]]`.
    public var directions: [LegacyDirectionCard]
    /// Action/storyboarding prose: `[ Luke crosses the bridge ]`.
    public var actions: [ActionCard]
    /// Camera/cinematography shot cards: `[camera: zoom_in | …]`.
    public var shots: [ScriptShotCard]

    public init(
        id: UUID = UUID(),
        label: String? = nil,
        lyricAnchor: LyricAnchor? = nil,
        directions: [LegacyDirectionCard] = [],
        actions: [ActionCard] = [],
        shots: [ScriptShotCard] = []
    ) {
        self.id = id
        self.label = label
        self.lyricAnchor = lyricAnchor
        self.directions = directions
        self.actions = actions
        self.shots = shots
    }
}

// MARK: - Shot card

public struct ScriptShotCard: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var label: String?
    /// Director's natural-language framing intent ("camera slowly finds Luke").
    public var direction: String
    /// Action/blocking prose specific to this shot.
    public var action: String
    public var camera: CameraSpec
    public var tags: TagSet
    public var characterFraming: ShotCharacterFramingSpec
    public var setting: ShotSettingSpec
    public var timing: TimingSpec
    public var lyricAnchor: LyricAnchor?
    public var status: CardStatus
    public var provenance: CardProvenance

    public init(
        id: UUID = UUID(),
        label: String? = nil,
        direction: String = "",
        action: String = "",
        camera: CameraSpec = CameraSpec(),
        tags: TagSet = TagSet(),
        characterFraming: ShotCharacterFramingSpec = ShotCharacterFramingSpec(),
        setting: ShotSettingSpec = ShotSettingSpec(),
        timing: TimingSpec = TimingSpec(),
        lyricAnchor: LyricAnchor? = nil,
        status: CardStatus = .manual,
        provenance: CardProvenance = CardProvenance(source: .manual)
    ) {
        self.id = id
        self.label = label
        self.direction = direction
        self.action = action
        self.camera = camera
        self.tags = tags
        self.characterFraming = characterFraming
        self.setting = setting
        self.timing = timing
        self.lyricAnchor = lyricAnchor
        self.status = status
        self.provenance = provenance
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case label
        case direction
        case action
        case camera
        case tags
        case characterFraming
        case setting
        case timing
        case lyricAnchor
        case status
        case provenance
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        label = try container.decodeIfPresent(String.self, forKey: .label)
        direction = try container.decodeIfPresent(String.self, forKey: .direction) ?? ""
        action = try container.decodeIfPresent(String.self, forKey: .action) ?? ""
        camera = try container.decodeIfPresent(CameraSpec.self, forKey: .camera) ?? CameraSpec()
        tags = try container.decodeIfPresent(TagSet.self, forKey: .tags) ?? TagSet()
        characterFraming = try container.decodeIfPresent(
            ShotCharacterFramingSpec.self,
            forKey: .characterFraming
        ) ?? ShotCharacterFramingSpec()
        setting = try container.decodeIfPresent(ShotSettingSpec.self, forKey: .setting) ?? ShotSettingSpec()
        timing = try container.decodeIfPresent(TimingSpec.self, forKey: .timing) ?? TimingSpec()
        lyricAnchor = try container.decodeIfPresent(LyricAnchor.self, forKey: .lyricAnchor)
        status = try container.decodeIfPresent(CardStatus.self, forKey: .status) ?? .manual
        provenance = try container.decodeIfPresent(CardProvenance.self, forKey: .provenance)
            ?? CardProvenance(source: .manual)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(label, forKey: .label)
        try container.encode(direction, forKey: .direction)
        try container.encode(action, forKey: .action)
        try container.encode(camera, forKey: .camera)
        try container.encode(tags, forKey: .tags)
        if !characterFraming.isEmpty {
            try container.encode(characterFraming, forKey: .characterFraming)
        }
        if !setting.isEmpty {
            try container.encode(setting, forKey: .setting)
        }
        try container.encode(timing, forKey: .timing)
        try container.encodeIfPresent(lyricAnchor, forKey: .lyricAnchor)
        try container.encode(status, forKey: .status)
        try container.encode(provenance, forKey: .provenance)
    }
}

public struct ShotSettingSpec: Codable, Sendable, Equatable {
    public var timeOfDay: String?
    public var interiorExterior: String?
    public var weatherAtmosphere: String?
    public var lightSource: String?
    public var lens: String?
    public var cameraAngle: String?
    public var depthOfField: String?
    public var continuityNotes: String?

    public init(
        timeOfDay: String? = nil,
        interiorExterior: String? = nil,
        weatherAtmosphere: String? = nil,
        lightSource: String? = nil,
        lens: String? = nil,
        cameraAngle: String? = nil,
        depthOfField: String? = nil,
        continuityNotes: String? = nil
    ) {
        self.timeOfDay = timeOfDay
        self.interiorExterior = interiorExterior
        self.weatherAtmosphere = weatherAtmosphere
        self.lightSource = lightSource
        self.lens = lens
        self.cameraAngle = cameraAngle
        self.depthOfField = depthOfField
        self.continuityNotes = continuityNotes
    }

    public var isEmpty: Bool {
        (timeOfDay ?? "").isEmpty
            && (interiorExterior ?? "").isEmpty
            && (weatherAtmosphere ?? "").isEmpty
            && (lightSource ?? "").isEmpty
            && (lens ?? "").isEmpty
            && (cameraAngle ?? "").isEmpty
            && (depthOfField ?? "").isEmpty
            && (continuityNotes ?? "").isEmpty
    }
}

public struct ShotCharacterFramingSpec: Codable, Sendable, Equatable {
    public var left: [String]
    public var middle: [String]
    public var right: [String]
    public var leftFacing: String?
    public var middleFacing: String?
    public var rightFacing: String?

    public init(
        left: [String] = [],
        middle: [String] = [],
        right: [String] = [],
        leftFacing: String? = nil,
        middleFacing: String? = nil,
        rightFacing: String? = nil
    ) {
        self.left = left
        self.middle = middle
        self.right = right
        self.leftFacing = leftFacing
        self.middleFacing = middleFacing
        self.rightFacing = rightFacing
    }

    public var allCharacters: [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for character in left + middle + right {
            let trimmed = character.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let key = trimmed.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            ordered.append(trimmed)
        }
        return ordered
    }

    public var isEmpty: Bool {
        left.isEmpty && middle.isEmpty && right.isEmpty
            && (leftFacing ?? "").isEmpty
            && (middleFacing ?? "").isEmpty
            && (rightFacing ?? "").isEmpty
    }
}

// MARK: - Camera

public struct CameraSpec: Codable, Sendable, Equatable {
    /// Shot framing (extreme_wide, wide, medium, close, extreme_close, …).
    /// Mirrors Animate's `CameraShot` raw values; free string for forward
    /// compatibility with new framings.
    public var shotSize: String?
    /// Optional starting framing for a movement shot.
    public var fromShotSize: String?
    /// Optional ending framing for a movement shot.
    public var toShotSize: String?
    /// Movement keyword (zoom_in, pan_left, track, hold, …). Mirrors
    /// Animate's `CameraMovement` raw values.
    public var movement: String?
    /// Subject of focus (a character slug, prop slug, or free text).
    public var focus: String?
    /// Editorial intent (establishing, reveal, reaction, isolation, …).
    public var intent: String?
    /// Camera label / shot ID like "A1" or "Cam 03".
    public var label: String?
    /// Free-form notes the LLM or director added that don't map to a slot.
    public var notes: String?

    public init(
        shotSize: String? = nil,
        fromShotSize: String? = nil,
        toShotSize: String? = nil,
        movement: String? = nil,
        focus: String? = nil,
        intent: String? = nil,
        label: String? = nil,
        notes: String? = nil
    ) {
        self.shotSize = shotSize
        self.fromShotSize = fromShotSize
        self.toShotSize = toShotSize
        self.movement = movement
        self.focus = focus
        self.intent = intent
        self.label = label
        self.notes = notes
    }

    public var isEmpty: Bool {
        shotSize == nil && fromShotSize == nil && toShotSize == nil && movement == nil && focus == nil
            && intent == nil && label == nil && (notes ?? "").isEmpty
    }
}

// MARK: - Tags

public struct TagSet: Codable, Sendable, Equatable {
    public var characters: [String]
    public var places: [String]
    public var props: [String]
    public var mood: [String]
    public var lighting: [String]
    public var landmarks: [String]
    public var automation: [String]

    public init(
        characters: [String] = [],
        places: [String] = [],
        props: [String] = [],
        mood: [String] = [],
        lighting: [String] = [],
        landmarks: [String] = [],
        automation: [String] = []
    ) {
        self.characters = characters
        self.places = places
        self.props = props
        self.mood = mood
        self.lighting = lighting
        self.landmarks = landmarks
        self.automation = automation
    }

    public var isEmpty: Bool {
        characters.isEmpty && places.isEmpty && props.isEmpty
            && mood.isEmpty && lighting.isEmpty && landmarks.isEmpty
            && automation.isEmpty
    }
}

// MARK: - Timing

public struct TimingSpec: Codable, Sendable, Equatable {
    public var startBar: Int?
    public var endBar: Int?
    public var startBeat: Int?
    public var endBeat: Int?
    public var startFrame: Int?
    public var endFrame: Int?

    public init(
        startBar: Int? = nil,
        endBar: Int? = nil,
        startBeat: Int? = nil,
        endBeat: Int? = nil,
        startFrame: Int? = nil,
        endFrame: Int? = nil
    ) {
        self.startBar = startBar
        self.endBar = endBar
        self.startBeat = startBeat
        self.endBeat = endBeat
        self.startFrame = startFrame
        self.endFrame = endFrame
    }

    public var isEmpty: Bool {
        startBar == nil && endBar == nil && startBeat == nil
            && endBeat == nil && startFrame == nil && endFrame == nil
    }
}

// MARK: - Anchor

/// Position of a card relative to the host song's lyric text.
///
/// Lines are 0-based and refer to the `\n`-separated lines of the active
/// lyrics. `excerpt` is the first non-empty lyric line in the range — used
/// purely for human display so cards stay legible if line numbers drift.
public struct LyricAnchor: Codable, Sendable, Equatable, Hashable {
    public var startLine: Int
    public var endLine: Int
    public var excerpt: String

    public init(startLine: Int, endLine: Int, excerpt: String) {
        self.startLine = startLine
        self.endLine = max(endLine, startLine)
        self.excerpt = excerpt
    }
}

// MARK: - Status / provenance

public enum CardStatus: String, Codable, Sendable, Equatable {
    /// Authored or edited by the user directly.
    case manual
    /// Reconstructed from legacy bracket markup at open time.
    case importedLegacy
    /// LLM-proposed; awaiting director review.
    case llmProposed
    /// LLM-proposed and accepted by the director.
    case llmAccepted
}

public struct CardProvenance: Codable, Sendable, Equatable {
    public enum Source: String, Codable, Sendable {
        case manual
        case importedLegacy
        case llmProposed
        case llmAccepted
    }

    public var source: Source
    public var generatedAt: Date?
    public var llmModel: String?
    /// If the card was reconstructed from raw bracket markup that didn't
    /// fully decompose into structured fields, the original substring is
    /// preserved here for round-trip fidelity.
    public var originalRawMarkup: String?

    public init(
        source: Source,
        generatedAt: Date? = nil,
        llmModel: String? = nil,
        originalRawMarkup: String? = nil
    ) {
        self.source = source
        self.generatedAt = generatedAt
        self.llmModel = llmModel
        self.originalRawMarkup = originalRawMarkup
    }
}

// MARK: - Legacy direction / action cards

/// Mirrors `[[a.s.sub.dir - description]]` numbered direction markup.
public struct LegacyDirectionCard: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    /// Stored as `"1.09.0.001"` so cards do not depend on WriteUI types.
    public var address: String
    public var descriptionText: String
    public var lyricAnchor: LyricAnchor?
    /// Always present for these cards.
    public var originalRawMarkup: String

    public init(
        id: UUID = UUID(),
        address: String,
        descriptionText: String,
        lyricAnchor: LyricAnchor? = nil,
        originalRawMarkup: String
    ) {
        self.id = id
        self.address = address
        self.descriptionText = descriptionText
        self.lyricAnchor = lyricAnchor
        self.originalRawMarkup = originalRawMarkup
    }
}

/// Mirrors a single-bracket narrative `[ ... ]` action.
public struct ActionCard: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var text: String
    public var lyricAnchor: LyricAnchor?
    public var originalRawMarkup: String
    public var tags: TagSet

    public init(
        id: UUID = UUID(),
        text: String,
        lyricAnchor: LyricAnchor? = nil,
        originalRawMarkup: String,
        tags: TagSet = TagSet()
    ) {
        self.id = id
        self.text = text
        self.lyricAnchor = lyricAnchor
        self.originalRawMarkup = originalRawMarkup
        self.tags = tags
    }
}
