import Foundation
import simd

// MARK: - Animate Metadata (stored in Animate/animate.json inside OWP)

struct AnimateMetadata: Codable, Sendable {
    var createdDate: Date
    var fps: Int
    var resolution: Resolution

    struct Resolution: Codable, Sendable {
        var width: Int
        var height: Int
    }
}

// MARK: - All Images Organizer

enum ImageLibraryOrganizeCategory: String, Codable, Sendable, Hashable, CaseIterable, Identifiable {
    case costumes
    case props
    case vehicles

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .costumes: "Costumes"
        case .props: "Props"
        case .vehicles: "Vehicles"
        }
    }

    var singularName: String {
        switch self {
        case .costumes: "Costume"
        case .props: "Prop"
        case .vehicles: "Vehicle"
        }
    }

    var systemImage: String {
        switch self {
        case .costumes: "tshirt"
        case .props: "shippingbox"
        case .vehicles: "car"
        }
    }
}

struct ImageLibraryOrganizeItem: Identifiable, Codable, Sendable, Hashable {
    var id: UUID
    var category: ImageLibraryOrganizeCategory
    var title: String
    var imagePaths: [String]
    var notes: String
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        category: ImageLibraryOrganizeCategory,
        title: String,
        imagePaths: [String] = [],
        notes: String = "",
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.category = category
        self.title = title
        self.imagePaths = imagePaths
        self.notes = notes
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

struct ImageLibraryOrganizeManifest: Codable, Sendable {
    var schemaVersion: Int = 1
    var items: [ImageLibraryOrganizeItem] = []
}

// MARK: - Scenes

struct AnimationScene: Identifiable, Codable, Sendable {
    var id: UUID
    var name: String
    var backgroundID: UUID?
    var characterIDs: [UUID]
    var characterSlugs: [String] = []
    var objectSetups: [ObjectSetup] = []
    var keyframes: [SceneKeyframe]
    var owpSongPath: String
    var defaultAudioPath: String? = nil
    var tracks: [String: TimelineTrack] = [:]
    var directionTemplate: SceneDirectionTemplate? = nil
    var automationProfile: SceneAutomationProfile? = nil
    var shots: [AnimationSceneShot] = []
    var animationStylePreset: AnimationStylePreset? = nil
}

/// Persistence format for scenes.json inside Animate/ directory.
struct AnimateSceneData: Codable, Sendable {
    var owsSongPath: String
    var backgroundID: UUID?
    var characterIDs: [UUID]
    var characterSlugs: [String] = []
    var objectSetups: [ObjectSetup] = []
    var keyframes: [SceneKeyframe]
    var defaultAudioPath: String? = nil
    var tracks: [String: TimelineTrack]
    var directionTemplate: SceneDirectionTemplate? = nil
    var automationProfile: SceneAutomationProfile? = nil
    var shots: [AnimationSceneShot] = []

    enum CodingKeys: String, CodingKey {
        case owsSongPath
        case backgroundID
        case characterIDs
        case characterSlugs
        case objectSetups
        case keyframes
        case defaultAudioPath
        case tracks
        case directionTemplate
        case automationProfile
        case shots
    }

    init(
        owsSongPath: String,
        backgroundID: UUID?,
        characterIDs: [UUID],
        characterSlugs: [String] = [],
        objectSetups: [ObjectSetup] = [],
        keyframes: [SceneKeyframe],
        defaultAudioPath: String? = nil,
        tracks: [String: TimelineTrack],
        directionTemplate: SceneDirectionTemplate? = nil,
        automationProfile: SceneAutomationProfile? = nil,
        shots: [AnimationSceneShot] = []
    ) {
        self.owsSongPath = owsSongPath
        self.backgroundID = backgroundID
        self.characterIDs = characterIDs
        self.characterSlugs = characterSlugs
        self.objectSetups = objectSetups
        self.keyframes = keyframes
        self.defaultAudioPath = defaultAudioPath
        self.tracks = tracks
        self.directionTemplate = directionTemplate
        self.automationProfile = automationProfile
        self.shots = shots
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        owsSongPath = try container.decode(String.self, forKey: .owsSongPath)
        backgroundID = try container.decodeIfPresent(UUID.self, forKey: .backgroundID)
        characterIDs = try container.decodeIfPresent([UUID].self, forKey: .characterIDs) ?? []
        characterSlugs = try container.decodeIfPresent([String].self, forKey: .characterSlugs) ?? []
        objectSetups = try container.decodeIfPresent([ObjectSetup].self, forKey: .objectSetups) ?? []
        keyframes = try container.decodeIfPresent([SceneKeyframe].self, forKey: .keyframes) ?? []
        defaultAudioPath = try container.decodeIfPresent(String.self, forKey: .defaultAudioPath)
        tracks = try container.decodeIfPresent([String: TimelineTrack].self, forKey: .tracks) ?? [:]
        directionTemplate = try container.decodeIfPresent(SceneDirectionTemplate.self, forKey: .directionTemplate)
        automationProfile = try container.decodeIfPresent(SceneAutomationProfile.self, forKey: .automationProfile)
        shots = try container.decodeIfPresent([AnimationSceneShot].self, forKey: .shots) ?? []
    }
}

struct AnimationSceneShot: Identifiable, Codable, Sendable, Hashable {
    enum Source: String, Codable, Sendable, CaseIterable, Hashable {
        case manual
        case inferred
        case presetApplied = "preset_applied"
        case scriptSync = "script_sync"

        var displayName: String {
            switch self {
            case .manual: "Manual"
            case .inferred: "Inferred"
            case .presetApplied: "Preset"
            case .scriptSync: "Script"
            }
        }
    }

    var id: UUID
    var name: String
    var startFrame: Int
    var endFrame: Int
    var cameraShot: CameraShot?
    var shotIntent: ShotIntent?
    var focusCharacterID: UUID?
    var focusCharacterSlug: String?
    var presetID: UUID?
    var notes: String
    var source: Source
    var lockedBoundaries: Bool
    var sourceDirectionTags: [String]
    var sourceLineNumber: Int?
    var sourceLyricExcerpt: String?
    var scriptSyncRunID: UUID?
    var shotFrameGeneration: ShotFrameGeneration? = nil
    var shotBackgroundPlate: ShotBackgroundPlate? = nil

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case startFrame
        case endFrame
        case cameraShot
        case shotIntent
        case focusCharacterID
        case focusCharacterSlug
        case presetID
        case notes
        case source
        case lockedBoundaries
        case sourceDirectionTags
        case sourceLineNumber
        case sourceLyricExcerpt
        case scriptSyncRunID
        case shotFrameGeneration
        case shotBackgroundPlate
    }

    init(
        id: UUID = UUID(),
        name: String,
        startFrame: Int,
        endFrame: Int,
        cameraShot: CameraShot? = nil,
        shotIntent: ShotIntent? = nil,
        focusCharacterID: UUID? = nil,
        focusCharacterSlug: String? = nil,
        presetID: UUID? = nil,
        notes: String = "",
        source: Source = .manual,
        lockedBoundaries: Bool = false,
        sourceDirectionTags: [String] = [],
        sourceLineNumber: Int? = nil,
        sourceLyricExcerpt: String? = nil,
        scriptSyncRunID: UUID? = nil
    ) {
        self.id = id
        self.name = name
        self.startFrame = startFrame
        self.endFrame = endFrame
        self.cameraShot = cameraShot
        self.shotIntent = shotIntent
        self.focusCharacterID = focusCharacterID
        self.focusCharacterSlug = focusCharacterSlug
        self.presetID = presetID
        self.notes = notes
        self.source = source
        self.lockedBoundaries = lockedBoundaries
        self.sourceDirectionTags = sourceDirectionTags
        self.sourceLineNumber = sourceLineNumber
        self.sourceLyricExcerpt = sourceLyricExcerpt
        self.scriptSyncRunID = scriptSyncRunID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        startFrame = try container.decodeIfPresent(Int.self, forKey: .startFrame) ?? 0
        endFrame = try container.decodeIfPresent(Int.self, forKey: .endFrame) ?? startFrame
        cameraShot = try container.decodeIfPresent(CameraShot.self, forKey: .cameraShot)
        shotIntent = try container.decodeIfPresent(ShotIntent.self, forKey: .shotIntent)
        focusCharacterID = try container.decodeIfPresent(UUID.self, forKey: .focusCharacterID)
        focusCharacterSlug = try container.decodeIfPresent(String.self, forKey: .focusCharacterSlug)
        presetID = try container.decodeIfPresent(UUID.self, forKey: .presetID)
        notes = try container.decodeIfPresent(String.self, forKey: .notes) ?? ""
        source = try container.decodeIfPresent(Source.self, forKey: .source) ?? .manual
        lockedBoundaries = try container.decodeIfPresent(Bool.self, forKey: .lockedBoundaries) ?? false
        sourceDirectionTags = try container.decodeIfPresent([String].self, forKey: .sourceDirectionTags) ?? []
        sourceLineNumber = try container.decodeIfPresent(Int.self, forKey: .sourceLineNumber)
        sourceLyricExcerpt = try container.decodeIfPresent(String.self, forKey: .sourceLyricExcerpt)
        scriptSyncRunID = try container.decodeIfPresent(UUID.self, forKey: .scriptSyncRunID)
        shotFrameGeneration = try container.decodeIfPresent(ShotFrameGeneration.self, forKey: .shotFrameGeneration)
        shotBackgroundPlate = try container.decodeIfPresent(ShotBackgroundPlate.self, forKey: .shotBackgroundPlate)
    }

    var durationFrames: Int {
        max(1, endFrame - startFrame + 1)
    }
}

struct SceneDirectionTemplate: Codable, Sendable, Hashable {
    var defaultCameraShot: CameraShot?
    var focusCharacterID: UUID?
    var focusCharacterSlug: String?
    var notes: String

    init(
        defaultCameraShot: CameraShot? = nil,
        focusCharacterID: UUID? = nil,
        focusCharacterSlug: String? = nil,
        notes: String = ""
    ) {
        self.defaultCameraShot = defaultCameraShot
        self.focusCharacterID = focusCharacterID
        self.focusCharacterSlug = focusCharacterSlug
        self.notes = notes
    }

    var isEmpty: Bool {
        defaultCameraShot == nil &&
            focusCharacterID == nil &&
            focusCharacterSlug == nil &&
            notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

struct SceneShotPresetCharacterCue: Codable, Sendable, Hashable {
    var characterSlug: String
    var facing: FacingDirection?
    var viewAngle: AngleView?
    var pose: CharacterPackagePose?
    var expression: String?
    var action: String?

    var isEmpty: Bool {
        facing == nil &&
            viewAngle == nil &&
            pose == nil &&
            (expression?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) &&
            (action?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }
}

struct SceneShotPreset: Identifiable, Codable, Sendable, Hashable {
    var id: UUID
    var name: String
    var notes: String
    var shotIntent: ShotIntent?
    var cameraShot: CameraShot?
    var defaultCameraShot: CameraShot?
    var focusCharacterSlug: String?
    var characterCues: [SceneShotPresetCharacterCue]
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        notes: String = "",
        shotIntent: ShotIntent? = nil,
        cameraShot: CameraShot? = nil,
        defaultCameraShot: CameraShot? = nil,
        focusCharacterSlug: String? = nil,
        characterCues: [SceneShotPresetCharacterCue] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.notes = notes
        self.shotIntent = shotIntent
        self.cameraShot = cameraShot
        self.defaultCameraShot = defaultCameraShot
        self.focusCharacterSlug = focusCharacterSlug
        self.characterCues = characterCues
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

enum ShotIntent: String, Codable, Sendable, CaseIterable, Hashable {
    case establishing
    case reveal
    case reaction
    case handoff
    case dialogue
    case movement
    case confrontation
    case insert
    case transition
    case emotional

    var displayName: String {
        switch self {
        case .establishing: "Establishing"
        case .reveal: "Reveal"
        case .reaction: "Reaction"
        case .handoff: "Handoff"
        case .dialogue: "Dialogue"
        case .movement: "Movement"
        case .confrontation: "Confrontation"
        case .insert: "Insert"
        case .transition: "Transition"
        case .emotional: "Emotional"
        }
    }

    /// Baseline framing to use when intent is known but no explicit shot was authored.
    var recommendedCameraShot: CameraShot {
        switch self {
        case .establishing:
            .extremeWide
        case .reveal:
            .mediumClose
        case .reaction:
            .close
        case .handoff:
            .medium
        case .dialogue:
            .mediumClose
        case .movement:
            .wide
        case .confrontation:
            .mediumClose
        case .insert:
            .extremeClose
        case .transition:
            .wide
        case .emotional:
            .close
        }
    }

    /// Optional lightweight motion bias to pair with the inferred fallback framing.
    var recommendedCameraMovement: CameraMovement? {
        switch self {
        case .reveal, .insert, .emotional:
            .zoomIn
        case .handoff, .movement:
            .track
        case .establishing, .reaction, .dialogue, .confrontation, .transition:
            nil
        }
    }
}

enum ShadowStyle: String, Codable, Sendable, CaseIterable, Hashable {
    case none
    case contact
    case softGround = "soft_ground"
    case dramaticStage = "dramatic_stage"

    var displayName: String {
        switch self {
        case .none: "None"
        case .contact: "Contact"
        case .softGround: "Soft Ground"
        case .dramaticStage: "Dramatic Stage"
        }
    }

    var isVisible: Bool {
        self != .none
    }

    var offset: SIMD2<Float> {
        switch self {
        case .none:
            .zero
        case .contact:
            SIMD2<Float>(10, 16)
        case .softGround:
            SIMD2<Float>(18, 24)
        case .dramaticStage:
            SIMD2<Float>(34, 18)
        }
    }

    var scale: SIMD2<Float> {
        switch self {
        case .none:
            SIMD2<Float>(1, 1)
        case .contact:
            SIMD2<Float>(1.00, 0.24)
        case .softGround:
            SIMD2<Float>(1.08, 0.32)
        case .dramaticStage:
            SIMD2<Float>(1.28, 0.38)
        }
    }

    var baseOpacity: Float {
        switch self {
        case .none:
            0
        case .contact:
            0.16
        case .softGround:
            0.22
        case .dramaticStage:
            0.28
        }
    }
}

struct SceneKeyframe: Identifiable, Codable, Sendable {
    var id: UUID
    var frame: Int
    var characterPositions: [UUID: CharacterTransform]
}

struct CharacterTransform: Codable, Sendable {
    var x: Double
    var y: Double
    var rotation: Double
    var scaleX: Double
    var scaleY: Double
    var opacity: Double
    var zOrder: Int

    static let identity = CharacterTransform(
        x: 0, y: 0, rotation: 0,
        scaleX: 1, scaleY: 1, opacity: 1, zOrder: 0
    )
}

// MARK: - Characters

enum CharacterCanvasRenderMode: String, Codable, Sendable, CaseIterable, Hashable {
    case packagePreview
    case rigDrawingSets

    var displayName: String {
        switch self {
        case .packagePreview: "Package Preview"
        case .rigDrawingSets: "Rig Drawing Sets"
        }
    }
}

struct CharacterInspirationBatchJob: Identifiable, Codable, Sendable, Hashable {
    enum Kind: String, Codable, Sendable, Hashable {
        case inspiration
        case loraCandidate = "lora_candidate"
        case unknown

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            let rawValue = try container.decode(String.self)
            self = Self(rawValue: rawValue) ?? .unknown
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }
    }

    var id: UUID
    var kind: Kind
    var title: String
    var batchName: String
    var metadataPath: String
    var outputRootPath: String
    var state: String
    var promptCount: Int
    var submittedAt: Date
    var lastCheckedAt: Date?
    var remoteUpdatedAt: Date?
    var remoteStartedAt: Date?
    var remoteFinishedAt: Date?
    var remoteSuccessfulCount: Int?
    var downloadedImagePaths: [String]
    var autoImportedImagePaths: [String]
    var lastErrorMessage: String?

    init(
        id: UUID = UUID(),
        kind: Kind = .inspiration,
        title: String,
        batchName: String,
        metadataPath: String,
        outputRootPath: String,
        state: String,
        promptCount: Int,
        submittedAt: Date = Date(),
        lastCheckedAt: Date? = nil,
        remoteUpdatedAt: Date? = nil,
        remoteStartedAt: Date? = nil,
        remoteFinishedAt: Date? = nil,
        remoteSuccessfulCount: Int? = nil,
        downloadedImagePaths: [String] = [],
        autoImportedImagePaths: [String] = [],
        lastErrorMessage: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.batchName = batchName
        self.metadataPath = metadataPath
        self.outputRootPath = outputRootPath
        self.state = state
        self.promptCount = promptCount
        self.submittedAt = submittedAt
        self.lastCheckedAt = lastCheckedAt
        self.remoteUpdatedAt = remoteUpdatedAt
        self.remoteStartedAt = remoteStartedAt
        self.remoteFinishedAt = remoteFinishedAt
        self.remoteSuccessfulCount = remoteSuccessfulCount
        self.downloadedImagePaths = downloadedImagePaths
        self.autoImportedImagePaths = autoImportedImagePaths
        self.lastErrorMessage = lastErrorMessage
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .inspiration
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "Inspiration Batch"
        batchName = try c.decodeIfPresent(String.self, forKey: .batchName) ?? ""
        metadataPath = try c.decodeIfPresent(String.self, forKey: .metadataPath) ?? ""
        outputRootPath = try c.decodeIfPresent(String.self, forKey: .outputRootPath) ?? ""
        state = try c.decodeIfPresent(String.self, forKey: .state) ?? "JOB_STATE_PENDING"
        promptCount = try c.decodeIfPresent(Int.self, forKey: .promptCount) ?? 0
        submittedAt = try c.decodeIfPresent(Date.self, forKey: .submittedAt) ?? Date(timeIntervalSinceReferenceDate: 0)
        lastCheckedAt = try c.decodeIfPresent(Date.self, forKey: .lastCheckedAt)
        remoteUpdatedAt = try c.decodeIfPresent(Date.self, forKey: .remoteUpdatedAt)
        remoteStartedAt = try c.decodeIfPresent(Date.self, forKey: .remoteStartedAt)
        remoteFinishedAt = try c.decodeIfPresent(Date.self, forKey: .remoteFinishedAt)
        remoteSuccessfulCount = try c.decodeIfPresent(Int.self, forKey: .remoteSuccessfulCount)
        downloadedImagePaths = try c.decodeIfPresent([String].self, forKey: .downloadedImagePaths) ?? []
        autoImportedImagePaths = try c.decodeIfPresent([String].self, forKey: .autoImportedImagePaths) ?? []
        lastErrorMessage = try c.decodeIfPresent(String.self, forKey: .lastErrorMessage)
    }

    var isTerminal: Bool {
        switch state {
        case "JOB_STATE_SUCCEEDED", "JOB_STATE_FAILED", "JOB_STATE_CANCELLED", "JOB_STATE_EXPIRED":
            return true
        default:
            return false
        }
    }
}

enum CharacterWardrobeType: String, Codable, Sendable, CaseIterable, Identifiable, Hashable {
    case soldier
    case civilian

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .soldier: "Soldier"
        case .civilian: "Civilian"
        }
    }
}

enum CharacterGenderType: String, Codable, Sendable, CaseIterable, Identifiable, Hashable {
    case person
    case male
    case female

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .person: "Person"
        case .male: "Male"
        case .female: "Female"
        }
    }

    var promptNoun: String {
        switch self {
        case .person: "person"
        case .male: "man"
        case .female: "woman"
        }
    }
}


struct CharacterExpressionReferenceSet: Identifiable, Codable, Sendable, Hashable {
    var id: String { presetID }
    var presetID: String
    var displayName: String
    var variants: [CharacterLookDevelopmentVariant]
    var approvedVariantID: UUID?

    init(
        presetID: String,
        displayName: String,
        variants: [CharacterLookDevelopmentVariant] = [],
        approvedVariantID: UUID? = nil
    ) {
        self.presetID = presetID
        self.displayName = displayName
        self.variants = variants
        self.approvedVariantID = approvedVariantID
    }

    var approvedVariant: CharacterLookDevelopmentVariant? {
        guard let approvedVariantID else { return variants.last }
        return variants.first(where: { $0.id == approvedVariantID }) ?? variants.last
    }
}

struct AnimationCharacter: Identifiable, Codable, Sendable {
    static let currentSchemaVersion = 3

    var schemaVersion: Int
    var id: UUID
    var sortOrder: Int?
    var name: String
    var description: String
    var owpSlug: String
    var storageSlug: String?
    var renderMode: CharacterCanvasRenderMode?
    var preferredViewAngle: AngleView?
    var parts: [RigPart]

    var profileImagePath: String?
    var backstory: String
    var personality: String
    var notes: String
    var defaultWardrobeType: CharacterWardrobeType
    var genderType: CharacterGenderType
    var age: Int?
    var inspirationImagePaths: [String]
    var curatedInspirationImagePaths: [String]
    /// Paths already reviewed by the user. Any path in inspirationImagePaths
    /// that is NOT in this set is treated as "new" and flagged with a green
    /// dot in the gallery until the user interacts with the thumbnail.
    var reviewedInspirationImagePaths: Set<String> = []
    var inspirationReferenceImagePath: String?
    var inspirationRatings: [String: Int]?
    var inspirationNotes: [String: String]?
    /// Paths the user has explicitly rejected. Rejected images stay in the
    /// library but are visually de-emphasized in galleries and excluded from
    /// default curation logic.
    var inspirationRejectedPaths: Set<String> = []
    var inspirationBatchJobs: [CharacterInspirationBatchJob]
    var referenceImagePaths: [String]
    var animatedImagePaths: [String]
    var lookDevelopmentSlots: [CharacterLookDevelopmentSlot]
    var masterReferenceSheetPrompt: String
    var masterReferenceSourceImagePaths: [String]
    var masterReferenceSheetVariants: [CharacterLookDevelopmentVariant]
    var approvedMasterReferenceSheetVariantID: UUID?
    var headTurnaroundSheetPrompt: String
    var headTurnaroundSheetVariants: [CharacterLookDevelopmentVariant]
    var approvedHeadTurnaroundSheetVariantID: UUID?
    var headTurnaroundSlots: [CharacterPoseSlot]
    var expressionReferenceSets: [CharacterExpressionReferenceSet]
    var costumeReferenceSets: [CharacterCostumeReferenceSet]
    var models3D: [Character3DModel]
    var activeLORAFilename: String?
    var activeLORATriggerWord: String?
    var activeLORAWeight: Double?

    init(
        schemaVersion: Int = Self.currentSchemaVersion,
        id: UUID,
        sortOrder: Int? = nil,
        name: String,
        description: String,
        owpSlug: String,
        storageSlug: String? = nil,
        renderMode: CharacterCanvasRenderMode? = nil,
        preferredViewAngle: AngleView? = nil,
        parts: [RigPart],
        profileImagePath: String? = nil,
        backstory: String = "",
        personality: String = "",
        notes: String = "",
        defaultWardrobeType: CharacterWardrobeType = .soldier,
        genderType: CharacterGenderType = .person,
        age: Int? = nil,
        inspirationImagePaths: [String] = [],
        curatedInspirationImagePaths: [String] = [],
        reviewedInspirationImagePaths: Set<String> = [],
        inspirationReferenceImagePath: String? = nil,
        inspirationRatings: [String: Int]? = nil,
        inspirationNotes: [String: String]? = nil,
        inspirationRejectedPaths: Set<String> = [],
        inspirationBatchJobs: [CharacterInspirationBatchJob] = [],
        referenceImagePaths: [String] = [],
        animatedImagePaths: [String] = [],
        lookDevelopmentSlots: [CharacterLookDevelopmentSlot] = [],
        masterReferenceSheetPrompt: String = "",
        masterReferenceSourceImagePaths: [String] = [],
        masterReferenceSheetVariants: [CharacterLookDevelopmentVariant] = [],
        approvedMasterReferenceSheetVariantID: UUID? = nil,
        headTurnaroundSheetPrompt: String = "",
        headTurnaroundSheetVariants: [CharacterLookDevelopmentVariant] = [],
        approvedHeadTurnaroundSheetVariantID: UUID? = nil,
        headTurnaroundSlots: [CharacterPoseSlot] = [],
        expressionReferenceSets: [CharacterExpressionReferenceSet] = [],
        costumeReferenceSets: [CharacterCostumeReferenceSet] = [],
        models3D: [Character3DModel] = [],
        activeLORAFilename: String? = nil,
        activeLORATriggerWord: String? = nil,
        activeLORAWeight: Double? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.sortOrder = sortOrder
        self.name = name
        self.description = description
        self.owpSlug = owpSlug
        self.storageSlug = storageSlug
        self.renderMode = renderMode
        self.preferredViewAngle = preferredViewAngle
        self.parts = parts
        self.profileImagePath = profileImagePath
        self.backstory = backstory
        self.personality = personality
        self.notes = notes
        self.defaultWardrobeType = defaultWardrobeType
        self.genderType = genderType
        self.age = age
        self.inspirationImagePaths = inspirationImagePaths
        self.curatedInspirationImagePaths = curatedInspirationImagePaths
        self.reviewedInspirationImagePaths = reviewedInspirationImagePaths
        self.inspirationReferenceImagePath = inspirationReferenceImagePath
        self.inspirationRatings = inspirationRatings
        self.inspirationNotes = inspirationNotes
        self.inspirationRejectedPaths = inspirationRejectedPaths
        self.inspirationBatchJobs = inspirationBatchJobs
        self.referenceImagePaths = referenceImagePaths
        self.animatedImagePaths = animatedImagePaths
        self.lookDevelopmentSlots = lookDevelopmentSlots
        self.masterReferenceSheetPrompt = masterReferenceSheetPrompt
        self.masterReferenceSourceImagePaths = masterReferenceSourceImagePaths
        self.masterReferenceSheetVariants = masterReferenceSheetVariants
        self.approvedMasterReferenceSheetVariantID = approvedMasterReferenceSheetVariantID
        self.headTurnaroundSheetPrompt = headTurnaroundSheetPrompt
        self.headTurnaroundSheetVariants = headTurnaroundSheetVariants
        self.approvedHeadTurnaroundSheetVariantID = approvedHeadTurnaroundSheetVariantID
        self.headTurnaroundSlots = headTurnaroundSlots
        self.expressionReferenceSets = expressionReferenceSets
        self.costumeReferenceSets = costumeReferenceSets
        self.models3D = models3D
        self.activeLORAFilename = activeLORAFilename
        self.activeLORATriggerWord = activeLORATriggerWord
        self.activeLORAWeight = activeLORAWeight
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 0
        id = try c.decode(UUID.self, forKey: .id)
        sortOrder = try c.decodeIfPresent(Int.self, forKey: .sortOrder)
        name = try c.decode(String.self, forKey: .name)
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        owpSlug = try c.decodeIfPresent(String.self, forKey: .owpSlug) ?? ""
        storageSlug = try c.decodeIfPresent(String.self, forKey: .storageSlug)
        renderMode = try c.decodeIfPresent(CharacterCanvasRenderMode.self, forKey: .renderMode)
        preferredViewAngle = try c.decodeIfPresent(AngleView.self, forKey: .preferredViewAngle)
        parts = try c.decodeIfPresent([RigPart].self, forKey: .parts) ?? []
        profileImagePath = try c.decodeIfPresent(String.self, forKey: .profileImagePath)
        backstory = try c.decodeIfPresent(String.self, forKey: .backstory) ?? ""
        personality = try c.decodeIfPresent(String.self, forKey: .personality) ?? ""
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        defaultWardrobeType = try c.decodeIfPresent(CharacterWardrobeType.self, forKey: .defaultWardrobeType) ?? .soldier
        genderType = try c.decodeIfPresent(CharacterGenderType.self, forKey: .genderType) ?? .person
        age = try c.decodeIfPresent(Int.self, forKey: .age)
        inspirationImagePaths = try c.decodeIfPresent([String].self, forKey: .inspirationImagePaths) ?? []
        curatedInspirationImagePaths = try c.decodeIfPresent([String].self, forKey: .curatedInspirationImagePaths) ?? []
        reviewedInspirationImagePaths = Set(try c.decodeIfPresent([String].self, forKey: .reviewedInspirationImagePaths) ?? [])
        inspirationReferenceImagePath = try c.decodeIfPresent(String.self, forKey: .inspirationReferenceImagePath)
        inspirationRatings = try c.decodeIfPresent([String: Int].self, forKey: .inspirationRatings)
        inspirationNotes = try c.decodeIfPresent([String: String].self, forKey: .inspirationNotes)
        inspirationRejectedPaths = Set(try c.decodeIfPresent([String].self, forKey: .inspirationRejectedPaths) ?? [])
        inspirationBatchJobs = try c.decodeIfPresent([CharacterInspirationBatchJob].self, forKey: .inspirationBatchJobs) ?? []
        referenceImagePaths = try c.decodeIfPresent([String].self, forKey: .referenceImagePaths) ?? []
        animatedImagePaths = try c.decodeIfPresent([String].self, forKey: .animatedImagePaths) ?? []
        lookDevelopmentSlots = try c.decodeIfPresent([CharacterLookDevelopmentSlot].self, forKey: .lookDevelopmentSlots) ?? []
        masterReferenceSheetPrompt = try c.decodeIfPresent(String.self, forKey: .masterReferenceSheetPrompt) ?? ""
        masterReferenceSourceImagePaths = try c.decodeIfPresent([String].self, forKey: .masterReferenceSourceImagePaths) ?? []
        masterReferenceSheetVariants = try c.decodeIfPresent([CharacterLookDevelopmentVariant].self, forKey: .masterReferenceSheetVariants) ?? []
        approvedMasterReferenceSheetVariantID = try c.decodeIfPresent(UUID.self, forKey: .approvedMasterReferenceSheetVariantID)
        headTurnaroundSheetPrompt = try c.decodeIfPresent(String.self, forKey: .headTurnaroundSheetPrompt) ?? ""
        headTurnaroundSheetVariants = try c.decodeIfPresent([CharacterLookDevelopmentVariant].self, forKey: .headTurnaroundSheetVariants) ?? []
        approvedHeadTurnaroundSheetVariantID = try c.decodeIfPresent(UUID.self, forKey: .approvedHeadTurnaroundSheetVariantID)
        headTurnaroundSlots = try c.decodeIfPresent([CharacterPoseSlot].self, forKey: .headTurnaroundSlots) ?? []
        expressionReferenceSets = try c.decodeIfPresent([CharacterExpressionReferenceSet].self, forKey: .expressionReferenceSets) ?? []
        costumeReferenceSets = try c.decodeIfPresent([CharacterCostumeReferenceSet].self, forKey: .costumeReferenceSets) ?? []
        models3D = try c.decodeIfPresent([Character3DModel].self, forKey: .models3D) ?? []
        activeLORAFilename = try c.decodeIfPresent(String.self, forKey: .activeLORAFilename)
        activeLORATriggerWord = try c.decodeIfPresent(String.self, forKey: .activeLORATriggerWord)
        activeLORAWeight = try c.decodeIfPresent(Double.self, forKey: .activeLORAWeight)
    }

    var resolvedRenderMode: CharacterCanvasRenderMode {
        renderMode ?? .packagePreview
    }

    var approvedMasterReferenceSheetVariant: CharacterLookDevelopmentVariant? {
        guard let approvedMasterReferenceSheetVariantID else { return masterReferenceSheetVariants.last }
        return masterReferenceSheetVariants.first(where: { $0.id == approvedMasterReferenceSheetVariantID })
            ?? masterReferenceSheetVariants.last
    }

    var approvedHeadTurnaroundSheetVariant: CharacterLookDevelopmentVariant? {
        guard let approvedHeadTurnaroundSheetVariantID else { return headTurnaroundSheetVariants.last }
        return headTurnaroundSheetVariants.first(where: { $0.id == approvedHeadTurnaroundSheetVariantID })
            ?? headTurnaroundSheetVariants.last
    }

    func expressionLibraryEntry(for presetID: String) -> CharacterExpressionReferenceSet? {
        expressionReferenceSets.first { $0.presetID == presetID }
    }

    var assetFolderSlug: String {
        let trimmed = storageSlug?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? owpSlug : trimmed
    }
}

// MARK: - Character 3D Models

struct Character3DModel: Codable, Identifiable, Sendable {
    var id: UUID = UUID()
    var costumeName: String        // Links to a CostumeReferenceSet name
    var modelFileName: String      // e.g. "mark-military-medic.glb"
    var modelFormat: String        // "glb", "usdz", "obj"
    var notes: String = ""
    var dateAdded: Date = Date()

    init(
        id: UUID = UUID(),
        costumeName: String,
        modelFileName: String,
        modelFormat: String,
        notes: String = "",
        dateAdded: Date = Date()
    ) {
        self.id = id
        self.costumeName = costumeName
        self.modelFileName = modelFileName
        self.modelFormat = modelFormat
        self.notes = notes
        self.dateAdded = dateAdded
    }
}

struct RigPart: Identifiable, Codable, Sendable {
    var id: UUID
    var name: String
    var partType: PartType
    var parentID: UUID?
    var pivotPoint: CodablePoint
    var zOrder: Int
    var children: [UUID]
    var drawingSets: [AngleView: DrawingSet]

    init(id: UUID = UUID(), name: String, partType: PartType, parentID: UUID? = nil,
         pivotPoint: CodablePoint = .zero, zOrder: Int = 0, children: [UUID] = [],
         drawingSets: [AngleView: DrawingSet] = [:]) {
        self.id = id
        self.name = name
        self.partType = partType
        self.parentID = parentID
        self.pivotPoint = pivotPoint
        self.zOrder = zOrder
        self.children = children
        self.drawingSets = drawingSets
    }
}

struct CodablePoint: Codable, Sendable, Hashable {
    var x: Double
    var y: Double

    static let zero = CodablePoint(x: 0, y: 0)
}

enum PartType: String, Codable, Sendable, CaseIterable {
    case root
    case hips
    case torso
    case chest
    case neck
    case head
    case face
    case eyeLeft, eyeRight
    case eyebrowLeft, eyebrowRight
    case mouth
    case nose
    case hairFront, hairBack
    case shoulderLeft, shoulderRight
    case upperArmLeft, upperArmRight
    case lowerArmLeft, lowerArmRight
    case handLeft, handRight
    case upperLegLeft, upperLegRight
    case lowerLegLeft, lowerLegRight
    case footLeft, footRight
    case accessory
}

enum AngleView: String, Codable, Sendable, CaseIterable, Hashable {
    case front
    case threeQuarterFront
    case side
    case threeQuarterBack
    case back
}

struct DrawingSet: Identifiable, Codable, Sendable {
    var id: UUID
    var angle: AngleView
    var activeVariantID: UUID?
    var variants: [DrawingVariant]

    init(
        id: UUID = UUID(),
        angle: AngleView,
        activeVariantID: UUID? = nil,
        variants: [DrawingVariant] = []
    ) {
        self.id = id
        self.angle = angle
        self.activeVariantID = activeVariantID
        self.variants = variants
    }

    var resolvedActiveVariant: DrawingVariant? {
        if let activeVariantID,
           let activeVariant = variants.first(where: { $0.id == activeVariantID }) {
            return activeVariant
        }

        return variants.last
    }
}

struct DrawingVariant: Identifiable, Codable, Sendable {
    var id: UUID
    var name: String
    var filename: String
    var sourceURL: URL?
    var sourcePackageSchemaVersion: Int?
    var sourcePackageID: UUID?
    var sourcePackageSlug: String?
    var sourcePackageDisplayName: String?
    var sourceAssetID: UUID?
    var sourceAssetName: String?
    var sourceAssetRole: CharacterPackageAssetRole?
    var sourcePartType: PartType?
    var sourceAngle: AngleView?
    var sourcePose: CharacterPackagePose?
    var sourceTags: [String]?
    var sourceNotes: String?
    var sourceRelativePath: String?
    var placement: CharacterPackageAssetPlacement?

    init(
        id: UUID = UUID(),
        name: String,
        filename: String,
        sourceURL: URL? = nil,
        sourcePackageSchemaVersion: Int? = nil,
        sourcePackageID: UUID? = nil,
        sourcePackageSlug: String? = nil,
        sourcePackageDisplayName: String? = nil,
        sourceAssetID: UUID? = nil,
        sourceAssetName: String? = nil,
        sourceAssetRole: CharacterPackageAssetRole? = nil,
        sourcePartType: PartType? = nil,
        sourceAngle: AngleView? = nil,
        sourcePose: CharacterPackagePose? = nil,
        sourceTags: [String]? = nil,
        sourceNotes: String? = nil,
        sourceRelativePath: String? = nil,
        placement: CharacterPackageAssetPlacement? = nil
    ) {
        self.id = id
        self.name = name
        self.filename = filename
        self.sourceURL = sourceURL
        self.sourcePackageSchemaVersion = sourcePackageSchemaVersion
        self.sourcePackageID = sourcePackageID
        self.sourcePackageSlug = sourcePackageSlug
        self.sourcePackageDisplayName = sourcePackageDisplayName
        self.sourceAssetID = sourceAssetID
        self.sourceAssetName = sourceAssetName
        self.sourceAssetRole = sourceAssetRole
        self.sourcePartType = sourcePartType
        self.sourceAngle = sourceAngle
        self.sourcePose = sourcePose
        self.sourceTags = sourceTags
        self.sourceNotes = sourceNotes
        self.sourceRelativePath = sourceRelativePath
        self.placement = placement
    }

    var isPackageDerived: Bool {
        sourcePackageID != nil ||
        sourcePackageSlug != nil ||
        sourcePackageDisplayName != nil ||
        sourceAssetID != nil
    }
}

// MARK: - Backgrounds

struct WorldMapPoint: Codable, Sendable, Hashable {
    var x: Double
    var y: Double

    init(x: Double = 0.5, y: Double = 0.5) {
        self.x = x
        self.y = y
    }

    func clamped() -> WorldMapPoint {
        WorldMapPoint(
            x: min(max(x, 0), 1),
            y: min(max(y, 0), 1)
        )
    }
}

struct WorldCameraPose: Codable, Sendable, Hashable {
    var yawDegrees: Double
    var pitchDegrees: Double
    var rollDegrees: Double
    var focalLengthMM: Double
    var horizontalFOVDegrees: Double?
    var verticalFOVDegrees: Double?

    init(
        yawDegrees: Double = 0,
        pitchDegrees: Double = 0,
        rollDegrees: Double = 0,
        focalLengthMM: Double = 35,
        horizontalFOVDegrees: Double? = nil,
        verticalFOVDegrees: Double? = nil
    ) {
        self.yawDegrees = yawDegrees
        self.pitchDegrees = pitchDegrees
        self.rollDegrees = rollDegrees
        self.focalLengthMM = focalLengthMM
        self.horizontalFOVDegrees = horizontalFOVDegrees
        self.verticalFOVDegrees = verticalFOVDegrees
    }
}

enum GeneratedBackgroundMapPlacementStatus: String, Codable, Sendable, Hashable, CaseIterable {
    case unplaced
    case inferred
    case confirmed

    var displayName: String {
        switch self {
        case .unplaced: "Unplaced"
        case .inferred: "Inferred"
        case .confirmed: "Confirmed"
        }
    }
}

enum GeneratedBackgroundOrientationState: String, Codable, Sendable, Hashable, CaseIterable {
    case unknown
    case original
    case mirrored

    var displayName: String {
        switch self {
        case .unknown: "Unknown"
        case .original: "Original"
        case .mirrored: "Mirrored"
        }
    }
}

enum WorldCanonStatus: String, Codable, Sendable, Hashable, CaseIterable {
    case unreviewed
    case candidate
    case canon
    case rejected

    var displayName: String {
        switch self {
        case .unreviewed: "Unreviewed"
        case .candidate: "Candidate"
        case .canon: "Canon"
        case .rejected: "Rejected"
        }
    }
}

enum PlaceQASeverity: String, Codable, Sendable, Hashable {
    case info
    case warning
    case critical
}

struct PlaceQAFlag: Identifiable, Codable, Sendable, Hashable {
    var id: UUID
    var code: String
    var message: String
    var severity: PlaceQASeverity

    init(
        id: UUID = UUID(),
        code: String,
        message: String,
        severity: PlaceQASeverity = .warning
    ) {
        self.id = id
        self.code = code
        self.message = message
        self.severity = severity
    }
}

enum PlaceWorldNodeRole: String, Codable, Sendable, Hashable, CaseIterable {
    case traverse
    case hero
    case coverage
    case reverse
    case landmark

    var displayName: String {
        switch self {
        case .traverse: "Traverse"
        case .hero: "Hero"
        case .coverage: "Coverage"
        case .reverse: "Reverse"
        case .landmark: "Landmark"
        }
    }
}

struct PlaceWorldRoute: Identifiable, Codable, Sendable, Hashable {
    var id: UUID
    var name: String
    var placeID: UUID?
    var notes: String
    var colorHex: String
    var isClosedLoop: Bool

    init(
        id: UUID = UUID(),
        name: String,
        placeID: UUID? = nil,
        notes: String = "",
        colorHex: String = "#6EA7FF",
        isClosedLoop: Bool = false
    ) {
        self.id = id
        self.name = name
        self.placeID = placeID
        self.notes = notes
        self.colorHex = colorHex
        self.isClosedLoop = isClosedLoop
    }
}

struct PlaceWorldNode: Identifiable, Codable, Sendable, Hashable {
    var id: UUID
    var routeID: UUID?
    var placeID: UUID?
    var title: String
    var sequenceIndex: Int
    var role: PlaceWorldNodeRole
    var mapPoint: WorldMapPoint
    var cameraPose: WorldCameraPose
    var notes: String
    var linkedNodeIDs: [UUID]
    var expectedLandmarkIDs: [UUID]
    var expectedLandmarkTitles: [String]
    var forbiddenLandmarkTitles: [String]
    var approvedPhotorealImagePath: String?
    var approvedAnimatedImagePath: String?
    var lastReviewID: UUID?

    init(
        id: UUID = UUID(),
        routeID: UUID? = nil,
        placeID: UUID? = nil,
        title: String = "View Node",
        sequenceIndex: Int = 0,
        role: PlaceWorldNodeRole = .traverse,
        mapPoint: WorldMapPoint = .init(),
        cameraPose: WorldCameraPose = .init(),
        notes: String = "",
        linkedNodeIDs: [UUID] = [],
        expectedLandmarkIDs: [UUID] = [],
        expectedLandmarkTitles: [String] = [],
        forbiddenLandmarkTitles: [String] = [],
        approvedPhotorealImagePath: String? = nil,
        approvedAnimatedImagePath: String? = nil,
        lastReviewID: UUID? = nil
    ) {
        self.id = id
        self.routeID = routeID
        self.placeID = placeID
        self.title = title
        self.sequenceIndex = sequenceIndex
        self.role = role
        self.mapPoint = mapPoint
        self.cameraPose = cameraPose
        self.notes = notes
        self.linkedNodeIDs = linkedNodeIDs
        self.expectedLandmarkIDs = expectedLandmarkIDs
        self.expectedLandmarkTitles = expectedLandmarkTitles
        self.forbiddenLandmarkTitles = forbiddenLandmarkTitles
        self.approvedPhotorealImagePath = approvedPhotorealImagePath
        self.approvedAnimatedImagePath = approvedAnimatedImagePath
        self.lastReviewID = lastReviewID
    }

    func approvedImagePath(for workflow: PlaceWorkflowMode) -> String? {
        switch workflow {
        case .photorealistic:
            approvedPhotorealImagePath
        case .animated:
            approvedAnimatedImagePath
        }
    }
}

struct PlaceWorldGraph: Codable, Sendable, Hashable {
    var routes: [PlaceWorldRoute]
    var nodes: [PlaceWorldNode]

    init(
        routes: [PlaceWorldRoute] = [],
        nodes: [PlaceWorldNode] = []
    ) {
        self.routes = routes
        self.nodes = nodes
    }
}

enum PlaceContinuityReviewStatus: String, Codable, Sendable, Hashable, CaseIterable {
    case pending
    case approved
    case rejected
    case ignored
}

struct PlaceContinuityReview: Identifiable, Codable, Sendable, Hashable {
    var id: UUID
    var nodeID: UUID
    var routeID: UUID?
    var workflow: PlaceWorkflowMode
    var candidateRecordID: UUID?
    var candidateImagePath: String
    var comparedNodeIDs: [UUID]
    var comparedImagePaths: [String]
    var similarityScore: Double
    var histogramScore: Double
    var metadataScore: Double
    var overallScore: Double
    var flags: [PlaceQAFlag]
    var status: PlaceContinuityReviewStatus
    var analyzedAt: Date

    init(
        id: UUID = UUID(),
        nodeID: UUID,
        routeID: UUID? = nil,
        workflow: PlaceWorkflowMode,
        candidateRecordID: UUID? = nil,
        candidateImagePath: String,
        comparedNodeIDs: [UUID] = [],
        comparedImagePaths: [String] = [],
        similarityScore: Double = 0,
        histogramScore: Double = 0,
        metadataScore: Double = 0,
        overallScore: Double = 0,
        flags: [PlaceQAFlag] = [],
        status: PlaceContinuityReviewStatus = .pending,
        analyzedAt: Date = Date()
    ) {
        self.id = id
        self.nodeID = nodeID
        self.routeID = routeID
        self.workflow = workflow
        self.candidateRecordID = candidateRecordID
        self.candidateImagePath = candidateImagePath
        self.comparedNodeIDs = comparedNodeIDs
        self.comparedImagePaths = comparedImagePaths
        self.similarityScore = similarityScore
        self.histogramScore = histogramScore
        self.metadataScore = metadataScore
        self.overallScore = overallScore
        self.flags = flags
        self.status = status
        self.analyzedAt = analyzedAt
    }
}

struct PlaceWorldGenerationBatchFailure: Identifiable, Codable, Sendable, Hashable {
    var id: UUID
    var key: String
    var message: String
    var code: Int?

    init(
        id: UUID = UUID(),
        key: String,
        message: String,
        code: Int? = nil
    ) {
        self.id = id
        self.key = key
        self.message = message
        self.code = code
    }
}

struct PlaceWorldGenerationBatch: Identifiable, Codable, Sendable, Hashable {
    var id: UUID
    var routeID: UUID?
    var placeID: UUID?
    var workflow: PlaceWorkflowMode
    var title: String
    var state: String
    var batchName: String?
    var nodeIDs: [UUID]
    var promptCount: Int
    var imageSize: String
    var aspectRatio: String?
    var model: GeminiModel
    var submittedAt: Date
    var lastCheckedAt: Date?
    var remoteUpdatedAt: Date?
    var remoteStartedAt: Date?
    var remoteFinishedAt: Date?
    var successCount: Int
    var failureCount: Int
    var lastErrorMessage: String?
    var failures: [PlaceWorldGenerationBatchFailure]
    var metadataPath: String?
    var outputRootPath: String?
    var generatedImagePaths: [String]

    init(
        id: UUID = UUID(),
        routeID: UUID? = nil,
        placeID: UUID? = nil,
        workflow: PlaceWorkflowMode,
        title: String,
        state: String = "queued",
        batchName: String? = nil,
        nodeIDs: [UUID] = [],
        promptCount: Int = 0,
        imageSize: String = "1K",
        aspectRatio: String? = nil,
        model: GeminiModel = .flash,
        submittedAt: Date = Date(),
        lastCheckedAt: Date? = nil,
        remoteUpdatedAt: Date? = nil,
        remoteStartedAt: Date? = nil,
        remoteFinishedAt: Date? = nil,
        successCount: Int = 0,
        failureCount: Int = 0,
        lastErrorMessage: String? = nil,
        failures: [PlaceWorldGenerationBatchFailure] = [],
        metadataPath: String? = nil,
        outputRootPath: String? = nil,
        generatedImagePaths: [String] = []
    ) {
        self.id = id
        self.routeID = routeID
        self.placeID = placeID
        self.workflow = workflow
        self.title = title
        self.state = state
        self.batchName = batchName
        self.nodeIDs = nodeIDs
        self.promptCount = promptCount
        self.imageSize = imageSize
        self.aspectRatio = aspectRatio
        self.model = model
        self.submittedAt = submittedAt
        self.lastCheckedAt = lastCheckedAt
        self.remoteUpdatedAt = remoteUpdatedAt
        self.remoteStartedAt = remoteStartedAt
        self.remoteFinishedAt = remoteFinishedAt
        self.successCount = successCount
        self.failureCount = failureCount
        self.lastErrorMessage = lastErrorMessage
        self.failures = failures
        self.metadataPath = metadataPath
        self.outputRootPath = outputRootPath
        self.generatedImagePaths = generatedImagePaths
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case routeID
        case placeID
        case workflow
        case title
        case state
        case batchName
        case nodeIDs
        case promptCount
        case imageSize
        case aspectRatio
        case model
        case submittedAt
        case lastCheckedAt
        case remoteUpdatedAt
        case remoteStartedAt
        case remoteFinishedAt
        case successCount
        case failureCount
        case lastErrorMessage
        case failures
        case metadataPath
        case outputRootPath
        case generatedImagePaths
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        routeID = try c.decodeIfPresent(UUID.self, forKey: .routeID)
        placeID = try c.decodeIfPresent(UUID.self, forKey: .placeID)
        workflow = try c.decodeIfPresent(PlaceWorkflowMode.self, forKey: .workflow) ?? .photorealistic
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "Batch"
        state = try c.decodeIfPresent(String.self, forKey: .state) ?? "queued"
        batchName = try c.decodeIfPresent(String.self, forKey: .batchName)
        nodeIDs = try c.decodeIfPresent([UUID].self, forKey: .nodeIDs) ?? []
        promptCount = try c.decodeIfPresent(Int.self, forKey: .promptCount) ?? 0
        imageSize = try c.decodeIfPresent(String.self, forKey: .imageSize) ?? "1K"
        aspectRatio = try c.decodeIfPresent(String.self, forKey: .aspectRatio)
        model = try c.decodeIfPresent(GeminiModel.self, forKey: .model) ?? .flash
        submittedAt = try c.decodeIfPresent(Date.self, forKey: .submittedAt) ?? Date()
        lastCheckedAt = try c.decodeIfPresent(Date.self, forKey: .lastCheckedAt)
        remoteUpdatedAt = try c.decodeIfPresent(Date.self, forKey: .remoteUpdatedAt)
        remoteStartedAt = try c.decodeIfPresent(Date.self, forKey: .remoteStartedAt)
        remoteFinishedAt = try c.decodeIfPresent(Date.self, forKey: .remoteFinishedAt)
        successCount = try c.decodeIfPresent(Int.self, forKey: .successCount) ?? 0
        failureCount = try c.decodeIfPresent(Int.self, forKey: .failureCount) ?? 0
        lastErrorMessage = try c.decodeIfPresent(String.self, forKey: .lastErrorMessage)
        failures = try c.decodeIfPresent([PlaceWorldGenerationBatchFailure].self, forKey: .failures) ?? []
        metadataPath = try c.decodeIfPresent(String.self, forKey: .metadataPath)
        outputRootPath = try c.decodeIfPresent(String.self, forKey: .outputRootPath)
        generatedImagePaths = try c.decodeIfPresent([String].self, forKey: .generatedImagePaths) ?? []
    }
}

struct PlaceAngleImage: Codable, Identifiable, Sendable, Hashable {
    var id: UUID = UUID()
    var imagePath: String
    var cameraShot: String?     // "wide", "medium", "close", etc.
    var angle: String?          // "front", "left", "right", "overhead"
    var timeOfDay: String?      // "day", "night", "dawn", "dusk"
    var notes: String = ""
    var worldNodeID: UUID?
    var routeID: UUID?
    var sequenceIndex: Int?
    var cameraPose: WorldCameraPose?
    var mapPoint: WorldMapPoint?
    var linkedGeneratedRecordID: UUID?
    var canonStatus: WorldCanonStatus

    enum CodingKeys: String, CodingKey {
        case id, imagePath, cameraShot, angle, timeOfDay, notes
        case worldNodeID, routeID, sequenceIndex, cameraPose, mapPoint, linkedGeneratedRecordID, canonStatus
    }

    init(
        id: UUID = UUID(),
        imagePath: String,
        cameraShot: String? = nil,
        angle: String? = nil,
        timeOfDay: String? = nil,
        notes: String = "",
        worldNodeID: UUID? = nil,
        routeID: UUID? = nil,
        sequenceIndex: Int? = nil,
        cameraPose: WorldCameraPose? = nil,
        mapPoint: WorldMapPoint? = nil,
        linkedGeneratedRecordID: UUID? = nil,
        canonStatus: WorldCanonStatus = .candidate
    ) {
        self.id = id
        self.imagePath = imagePath
        self.cameraShot = cameraShot
        self.angle = angle
        self.timeOfDay = timeOfDay
        self.notes = notes
        self.worldNodeID = worldNodeID
        self.routeID = routeID
        self.sequenceIndex = sequenceIndex
        self.cameraPose = cameraPose
        self.mapPoint = mapPoint
        self.linkedGeneratedRecordID = linkedGeneratedRecordID
        self.canonStatus = canonStatus
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        imagePath = try c.decode(String.self, forKey: .imagePath)
        cameraShot = try c.decodeIfPresent(String.self, forKey: .cameraShot)
        angle = try c.decodeIfPresent(String.self, forKey: .angle)
        timeOfDay = try c.decodeIfPresent(String.self, forKey: .timeOfDay)
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        worldNodeID = try c.decodeIfPresent(UUID.self, forKey: .worldNodeID)
        routeID = try c.decodeIfPresent(UUID.self, forKey: .routeID)
        sequenceIndex = try c.decodeIfPresent(Int.self, forKey: .sequenceIndex)
        cameraPose = try c.decodeIfPresent(WorldCameraPose.self, forKey: .cameraPose)
        mapPoint = try c.decodeIfPresent(WorldMapPoint.self, forKey: .mapPoint)
        linkedGeneratedRecordID = try c.decodeIfPresent(UUID.self, forKey: .linkedGeneratedRecordID)
        canonStatus = try c.decodeIfPresent(WorldCanonStatus.self, forKey: .canonStatus) ?? .candidate
    }
}

enum PlaceWorkflowMode: String, Codable, Sendable, CaseIterable, Hashable {
    case photorealistic
    case animated

    var displayName: String {
        switch self {
        case .photorealistic: "Photorealistic"
        case .animated: "Animated"
        }
    }

    var shortLabel: String {
        switch self {
        case .photorealistic: "Photo"
        case .animated: "Animate"
        }
    }
}

struct PlaceReferenceImage: Identifiable, Codable, Sendable, Hashable {
    enum Category: String, Codable, Sendable, CaseIterable, Hashable {
        case bridge
        case map
        case landmark
        case style
        case terrain
        case architecture
        case misc

        var displayName: String {
            switch self {
            case .bridge: "Bridge"
            case .map: "Map"
            case .landmark: "Landmark"
            case .style: "Style"
            case .terrain: "Terrain"
            case .architecture: "Architecture"
            case .misc: "Misc"
            }
        }
    }

    var id: UUID
    var title: String
    var imagePath: String
    var category: Category
    var notes: String

    init(
        id: UUID = UUID(),
        title: String,
        imagePath: String,
        category: Category = .misc,
        notes: String = ""
    ) {
        self.id = id
        self.title = title
        self.imagePath = imagePath
        self.category = category
        self.notes = notes
    }
}

struct PlaceLandmarkProfile: Identifiable, Codable, Sendable, Hashable {
    enum Kind: String, Codable, Sendable, CaseIterable, Hashable {
        case bridge
        case clinic = "clinic"
        case amiraHome = "amira_home"
        case gatheringSpace = "gathering_space"
        case marketplace
        case memorial
        case ridge
        case riverside
        case custom

        var displayName: String {
            switch self {
            case .bridge: "Bridge"
            case .clinic: "Clinic"
            case .amiraHome: "Amira’s Home"
            case .gatheringSpace: "Gathering Space"
            case .marketplace: "Marketplace"
            case .memorial: "Memorial / Grave"
            case .ridge: "Ridge / Valley"
            case .riverside: "Riverside"
            case .custom: "Custom"
            }
        }
    }

    var id: UUID
    var title: String
    var kind: Kind
    var notes: String
    var tags: [String]
    var exteriorPlaceID: UUID?
    var exteriorImagePath: String?
    var interiorPlaceID: UUID?
    var interiorImagePath: String?
    var primaryImagePath: String?
    var galleryImagePaths: [String]
    var anchorNodeID: UUID?
    var mapPoint: WorldMapPoint?
    var updatedAt: Date
    /// Latest iPad-drawn storyboard sketch (project-relative path).
    /// Isolated from `galleryImagePaths` and the photoreal pipeline. Only the
    /// most recent drawing is retained — never historical versions.
    var storyboardSketchPath: String? = nil

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case kind
        case notes
        case tags
        case exteriorPlaceID
        case exteriorImagePath
        case interiorPlaceID
        case interiorImagePath
        case primaryImagePath
        case galleryImagePaths
        case anchorNodeID
        case mapPoint
        case updatedAt
        case storyboardSketchPath
    }

    init(
        id: UUID = UUID(),
        title: String,
        kind: Kind,
        notes: String = "",
        tags: [String] = [],
        exteriorPlaceID: UUID? = nil,
        exteriorImagePath: String? = nil,
        interiorPlaceID: UUID? = nil,
        interiorImagePath: String? = nil,
        primaryImagePath: String? = nil,
        galleryImagePaths: [String] = [],
        anchorNodeID: UUID? = nil,
        mapPoint: WorldMapPoint? = nil,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.kind = kind
        self.notes = notes
        self.tags = tags
        self.exteriorPlaceID = exteriorPlaceID
        self.exteriorImagePath = exteriorImagePath
        self.interiorPlaceID = interiorPlaceID
        self.interiorImagePath = interiorImagePath
        self.primaryImagePath = primaryImagePath
        self.galleryImagePaths = galleryImagePaths
        self.anchorNodeID = anchorNodeID
        self.mapPoint = mapPoint
        self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        kind = try container.decode(Kind.self, forKey: .kind)
        notes = try container.decodeIfPresent(String.self, forKey: .notes) ?? ""
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        exteriorPlaceID = try container.decodeIfPresent(UUID.self, forKey: .exteriorPlaceID)
        exteriorImagePath = try container.decodeIfPresent(String.self, forKey: .exteriorImagePath)
        interiorPlaceID = try container.decodeIfPresent(UUID.self, forKey: .interiorPlaceID)
        interiorImagePath = try container.decodeIfPresent(String.self, forKey: .interiorImagePath)
        primaryImagePath = try container.decodeIfPresent(String.self, forKey: .primaryImagePath)
        galleryImagePaths = try container.decodeIfPresent([String].self, forKey: .galleryImagePaths)
            ?? [primaryImagePath, exteriorImagePath, interiorImagePath].compactMap { $0 }
        anchorNodeID = try container.decodeIfPresent(UUID.self, forKey: .anchorNodeID)
        mapPoint = try container.decodeIfPresent(WorldMapPoint.self, forKey: .mapPoint)
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        storyboardSketchPath = try container.decodeIfPresent(String.self, forKey: .storyboardSketchPath)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(kind, forKey: .kind)
        try container.encode(notes, forKey: .notes)
        try container.encode(tags, forKey: .tags)
        try container.encodeIfPresent(exteriorPlaceID, forKey: .exteriorPlaceID)
        try container.encodeIfPresent(exteriorImagePath, forKey: .exteriorImagePath)
        try container.encodeIfPresent(interiorPlaceID, forKey: .interiorPlaceID)
        try container.encodeIfPresent(interiorImagePath, forKey: .interiorImagePath)
        try container.encodeIfPresent(primaryImagePath, forKey: .primaryImagePath)
        try container.encode(galleryImagePaths, forKey: .galleryImagePaths)
        try container.encodeIfPresent(anchorNodeID, forKey: .anchorNodeID)
        try container.encodeIfPresent(mapPoint, forKey: .mapPoint)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encodeIfPresent(storyboardSketchPath, forKey: .storyboardSketchPath)
    }
}

struct PlaceWorkflowRenderConfig: Codable, Sendable, Hashable {
    var model: GeminiModel
    var aspectRatio: String
    var imageSize: String
    var lensDescription: String
    var promptPrefix: String
    var promptSuffix: String

    init(
        model: GeminiModel = .flash,
        aspectRatio: String = "16:9",
        imageSize: String = "1K",
        lensDescription: String = "",
        promptPrefix: String = "",
        promptSuffix: String = ""
    ) {
        self.model = model
        self.aspectRatio = aspectRatio
        self.imageSize = imageSize
        self.lensDescription = lensDescription
        self.promptPrefix = promptPrefix
        self.promptSuffix = promptSuffix
    }

    static let photorealDefault = PlaceWorkflowRenderConfig(
        model: .flash,
        aspectRatio: "16:9",
        imageSize: "1K",
        lensDescription: "Shot on a full-frame camera, grounded cinematic photography, realistic depth of field, and lensing appropriate to the composition.",
        promptPrefix: "",
        promptSuffix: ""
    )

    static let animatedDefault = PlaceWorkflowRenderConfig(
        model: .flash,
        aspectRatio: "16:9",
        imageSize: "1K",
        lensDescription: "Cinematic animated layout with the optical feel of a full-frame lens choice, grounded depth cues, and believable staging.",
        promptPrefix: "",
        promptSuffix: ""
    )
}

struct GeneratedBackgroundEditHistoryEntry: Identifiable, Codable, Sendable, Hashable {
    var id: UUID
    var createdAt: Date
    var instructions: String
    var sourcePath: String
    var resultPath: String?
    var prompt: String?

    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        instructions: String,
        sourcePath: String,
        resultPath: String? = nil,
        prompt: String? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.instructions = instructions
        self.sourcePath = sourcePath
        self.resultPath = resultPath
        self.prompt = prompt
    }
}

struct GeneratedBackgroundVersionRecord: Identifiable, Codable, Sendable, Hashable {
    var id: UUID
    var path: String
    var supersededAt: Date

    init(
        id: UUID = UUID(),
        path: String,
        supersededAt: Date = Date()
    ) {
        self.id = id
        self.path = path
        self.supersededAt = supersededAt
    }
}

struct GeneratedBackgroundLibraryRecord: Identifiable, Codable, Sendable, Hashable {
    var id: UUID
    var activePath: String
    var workflow: PlaceWorkflowMode
    var duplicatePaths: [String]
    var priorVersions: [GeneratedBackgroundVersionRecord]
    var contentFingerprint: String?
    var rating: Int?
    var isRejected: Bool
    var rejectionNotes: String
    var draftEditNotes: String
    var editHistory: [GeneratedBackgroundEditHistoryEntry]
    var summary: String
    var keywords: [String]
    var sourcePrompt: String?
    var linkedPlaceID: UUID?
    var worldNodeID: UUID?
    var routeID: UUID?
    var cameraPose: WorldCameraPose?
    var mapPoint: WorldMapPoint?
    var mapPlacementStatus: GeneratedBackgroundMapPlacementStatus
    var mapPlacementConfirmedAt: Date?
    var buildingAnchorNodeID: UUID?
    var orientationState: GeneratedBackgroundOrientationState
    var qaFlags: [PlaceQAFlag]
    var continuityReviewIDs: [UUID]
    var canonStatus: WorldCanonStatus
    var createdAt: Date
    var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case activePath
        case workflow
        case duplicatePaths
        case priorVersions
        case contentFingerprint
        case rating
        case isRejected
        case rejectionNotes
        case draftEditNotes
        case editHistory
        case summary
        case keywords
        case sourcePrompt
        case linkedPlaceID
        case worldNodeID
        case routeID
        case cameraPose
        case mapPoint
        case mapPlacementStatus
        case mapPlacementConfirmedAt
        case buildingAnchorNodeID
        case orientationState
        case qaFlags
        case continuityReviewIDs
        case canonStatus
        case createdAt
        case updatedAt
    }

    init(
        id: UUID = UUID(),
        activePath: String,
        workflow: PlaceWorkflowMode = .photorealistic,
        duplicatePaths: [String] = [],
        priorVersions: [GeneratedBackgroundVersionRecord] = [],
        contentFingerprint: String? = nil,
        rating: Int? = nil,
        isRejected: Bool = false,
        rejectionNotes: String = "",
        draftEditNotes: String = "",
        editHistory: [GeneratedBackgroundEditHistoryEntry] = [],
        summary: String = "",
        keywords: [String] = [],
        sourcePrompt: String? = nil,
        linkedPlaceID: UUID? = nil,
        worldNodeID: UUID? = nil,
        routeID: UUID? = nil,
        cameraPose: WorldCameraPose? = nil,
        mapPoint: WorldMapPoint? = nil,
        mapPlacementStatus: GeneratedBackgroundMapPlacementStatus? = nil,
        mapPlacementConfirmedAt: Date? = nil,
        buildingAnchorNodeID: UUID? = nil,
        orientationState: GeneratedBackgroundOrientationState = .unknown,
        qaFlags: [PlaceQAFlag] = [],
        continuityReviewIDs: [UUID] = [],
        canonStatus: WorldCanonStatus = .unreviewed,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.activePath = activePath
        self.workflow = workflow
        self.duplicatePaths = duplicatePaths
        self.priorVersions = priorVersions
        self.contentFingerprint = contentFingerprint
        self.rating = rating
        self.isRejected = isRejected
        self.rejectionNotes = rejectionNotes
        self.draftEditNotes = draftEditNotes
        self.editHistory = editHistory
        self.summary = summary
        self.keywords = keywords
        self.sourcePrompt = sourcePrompt
        self.linkedPlaceID = linkedPlaceID
        self.worldNodeID = worldNodeID
        self.routeID = routeID
        self.cameraPose = cameraPose
        self.mapPoint = mapPoint
        self.mapPlacementStatus = mapPlacementStatus
            ?? ((mapPoint != nil || cameraPose != nil) ? .inferred : .unplaced)
        self.mapPlacementConfirmedAt = self.mapPlacementStatus == .confirmed
            ? (mapPlacementConfirmedAt ?? updatedAt)
            : mapPlacementConfirmedAt
        self.buildingAnchorNodeID = buildingAnchorNodeID
        self.orientationState = orientationState
        self.qaFlags = qaFlags
        self.continuityReviewIDs = continuityReviewIDs
        self.canonStatus = canonStatus
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        activePath = try c.decode(String.self, forKey: .activePath)
        workflow = try c.decodeIfPresent(PlaceWorkflowMode.self, forKey: .workflow) ?? .photorealistic
        duplicatePaths = try c.decodeIfPresent([String].self, forKey: .duplicatePaths) ?? []
        priorVersions = try c.decodeIfPresent([GeneratedBackgroundVersionRecord].self, forKey: .priorVersions) ?? []
        contentFingerprint = try c.decodeIfPresent(String.self, forKey: .contentFingerprint)
        rating = try c.decodeIfPresent(Int.self, forKey: .rating)
        isRejected = try c.decodeIfPresent(Bool.self, forKey: .isRejected) ?? false
        rejectionNotes = try c.decodeIfPresent(String.self, forKey: .rejectionNotes) ?? ""
        draftEditNotes = try c.decodeIfPresent(String.self, forKey: .draftEditNotes) ?? ""
        editHistory = try c.decodeIfPresent([GeneratedBackgroundEditHistoryEntry].self, forKey: .editHistory) ?? []
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        keywords = try c.decodeIfPresent([String].self, forKey: .keywords) ?? []
        sourcePrompt = try c.decodeIfPresent(String.self, forKey: .sourcePrompt)
        linkedPlaceID = try c.decodeIfPresent(UUID.self, forKey: .linkedPlaceID)
        worldNodeID = try c.decodeIfPresent(UUID.self, forKey: .worldNodeID)
        routeID = try c.decodeIfPresent(UUID.self, forKey: .routeID)
        cameraPose = try c.decodeIfPresent(WorldCameraPose.self, forKey: .cameraPose)
        mapPoint = try c.decodeIfPresent(WorldMapPoint.self, forKey: .mapPoint)
        mapPlacementStatus = try c.decodeIfPresent(GeneratedBackgroundMapPlacementStatus.self, forKey: .mapPlacementStatus)
            ?? ((mapPoint != nil || cameraPose != nil) ? .inferred : .unplaced)
        mapPlacementConfirmedAt = try c.decodeIfPresent(Date.self, forKey: .mapPlacementConfirmedAt)
        buildingAnchorNodeID = try c.decodeIfPresent(UUID.self, forKey: .buildingAnchorNodeID)
        orientationState = try c.decodeIfPresent(GeneratedBackgroundOrientationState.self, forKey: .orientationState) ?? .unknown
        qaFlags = try c.decodeIfPresent([PlaceQAFlag].self, forKey: .qaFlags) ?? []
        continuityReviewIDs = try c.decodeIfPresent([UUID].self, forKey: .continuityReviewIDs) ?? []
        canonStatus = try c.decodeIfPresent(WorldCanonStatus.self, forKey: .canonStatus) ?? .unreviewed
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        if mapPlacementStatus == .confirmed, mapPlacementConfirmedAt == nil {
            mapPlacementConfirmedAt = updatedAt
        }
    }
}

struct PlaceImageEditQueueItem: Identifiable, Codable, Sendable, Hashable {
    enum State: String, Codable, Sendable, Hashable {
        case queued
        case submitted
        case failed
        case succeeded
    }

    var id: UUID
    var imageRecordID: UUID
    var sourcePath: String
    var workflow: PlaceWorkflowMode
    var instructions: String
    var state: State
    var queuedAt: Date
    var lastSubmittedAt: Date?
    var lastBatchJobID: UUID?
    var lastErrorMessage: String?

    init(
        id: UUID = UUID(),
        imageRecordID: UUID,
        sourcePath: String,
        workflow: PlaceWorkflowMode,
        instructions: String,
        state: State = .queued,
        queuedAt: Date = Date(),
        lastSubmittedAt: Date? = nil,
        lastBatchJobID: UUID? = nil,
        lastErrorMessage: String? = nil
    ) {
        self.id = id
        self.imageRecordID = imageRecordID
        self.sourcePath = sourcePath
        self.workflow = workflow
        self.instructions = instructions
        self.state = state
        self.queuedAt = queuedAt
        self.lastSubmittedAt = lastSubmittedAt
        self.lastBatchJobID = lastBatchJobID
        self.lastErrorMessage = lastErrorMessage
    }
}

struct PlaceImageEditBatchJob: Identifiable, Codable, Sendable, Hashable {
    var id: UUID
    var title: String
    var batchName: String
    var metadataPath: String
    var outputRootPath: String
    var state: String
    var workflow: PlaceWorkflowMode
    var promptCount: Int
    var submittedAt: Date
    var lastCheckedAt: Date?
    var remoteUpdatedAt: Date?
    var remoteStartedAt: Date?
    var remoteFinishedAt: Date?
    var remoteSuccessfulCount: Int?
    var downloadedImagePaths: [String]
    var queueItemIDs: [UUID]
    var lastErrorMessage: String?

    init(
        id: UUID = UUID(),
        title: String,
        batchName: String,
        metadataPath: String,
        outputRootPath: String,
        state: String,
        workflow: PlaceWorkflowMode,
        promptCount: Int,
        submittedAt: Date = Date(),
        lastCheckedAt: Date? = nil,
        remoteUpdatedAt: Date? = nil,
        remoteStartedAt: Date? = nil,
        remoteFinishedAt: Date? = nil,
        remoteSuccessfulCount: Int? = nil,
        downloadedImagePaths: [String] = [],
        queueItemIDs: [UUID] = [],
        lastErrorMessage: String? = nil
    ) {
        self.id = id
        self.title = title
        self.batchName = batchName
        self.metadataPath = metadataPath
        self.outputRootPath = outputRootPath
        self.state = state
        self.workflow = workflow
        self.promptCount = promptCount
        self.submittedAt = submittedAt
        self.lastCheckedAt = lastCheckedAt
        self.remoteUpdatedAt = remoteUpdatedAt
        self.remoteStartedAt = remoteStartedAt
        self.remoteFinishedAt = remoteFinishedAt
        self.remoteSuccessfulCount = remoteSuccessfulCount
        self.downloadedImagePaths = downloadedImagePaths
        self.queueItemIDs = queueItemIDs
        self.lastErrorMessage = lastErrorMessage
    }

    var isTerminal: Bool {
        switch state {
        case "JOB_STATE_SUCCEEDED", "JOB_STATE_FAILED", "JOB_STATE_CANCELLED", "JOB_STATE_EXPIRED":
            return true
        default:
            return false
        }
    }
}

struct GeneratedBackgroundWorldMapCanonRecord: Identifiable, Codable, Sendable, Hashable {
    var id: UUID
    var canonicalPath: String
    var pathAliases: [String]
    var contentFingerprint: String?
    var linkedPlaceID: UUID?
    var worldNodeID: UUID?
    var routeID: UUID?
    var cameraPose: WorldCameraPose?
    var mapPoint: WorldMapPoint?
    var mapPlacementStatus: GeneratedBackgroundMapPlacementStatus?
    var mapPlacementConfirmedAt: Date?
    var buildingAnchorNodeID: UUID?
    var orientationState: GeneratedBackgroundOrientationState?
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        canonicalPath: String,
        pathAliases: [String] = [],
        contentFingerprint: String? = nil,
        linkedPlaceID: UUID? = nil,
        worldNodeID: UUID? = nil,
        routeID: UUID? = nil,
        cameraPose: WorldCameraPose? = nil,
        mapPoint: WorldMapPoint? = nil,
        mapPlacementStatus: GeneratedBackgroundMapPlacementStatus? = nil,
        mapPlacementConfirmedAt: Date? = nil,
        buildingAnchorNodeID: UUID? = nil,
        orientationState: GeneratedBackgroundOrientationState? = nil,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.canonicalPath = canonicalPath
        self.pathAliases = pathAliases
        self.contentFingerprint = contentFingerprint
        self.linkedPlaceID = linkedPlaceID
        self.worldNodeID = worldNodeID
        self.routeID = routeID
        self.cameraPose = cameraPose
        self.mapPoint = mapPoint
        self.mapPlacementStatus = mapPlacementStatus
        self.mapPlacementConfirmedAt = mapPlacementConfirmedAt
        self.buildingAnchorNodeID = buildingAnchorNodeID
        self.orientationState = orientationState
        self.updatedAt = updatedAt
    }
}

struct PlacesWorldMapCanonLibrary: Codable, Sendable, Hashable {
    var recordOverrides: [GeneratedBackgroundWorldMapCanonRecord]

    init(recordOverrides: [GeneratedBackgroundWorldMapCanonRecord] = []) {
        self.recordOverrides = recordOverrides
    }
}

struct PlacesWorkflowLibrary: Codable, Sendable, Hashable {
    var masterMapImagePath: String?
    var landmarkReferences: [PlaceReferenceImage]
    var landmarkProfiles: [PlaceLandmarkProfile]
    var photorealConfig: PlaceWorkflowRenderConfig
    var animatedConfig: PlaceWorkflowRenderConfig
    var worldGraph: PlaceWorldGraph
    var continuityReviews: [PlaceContinuityReview]
    var worldGenerationBatches: [PlaceWorldGenerationBatch]
    var generatedImageRecords: [GeneratedBackgroundLibraryRecord]
    var pendingEditQueue: [PlaceImageEditQueueItem]
    var editBatchJobs: [PlaceImageEditBatchJob]

    enum CodingKeys: String, CodingKey {
        case masterMapImagePath
        case landmarkReferences
        case landmarkProfiles
        case photorealConfig
        case animatedConfig
        case worldGraph
        case continuityReviews
        case worldGenerationBatches
        case generatedImageRecords
        case pendingEditQueue
        case editBatchJobs
    }

    init(
        masterMapImagePath: String? = nil,
        landmarkReferences: [PlaceReferenceImage] = [],
        landmarkProfiles: [PlaceLandmarkProfile] = [],
        photorealConfig: PlaceWorkflowRenderConfig = .photorealDefault,
        animatedConfig: PlaceWorkflowRenderConfig = .animatedDefault,
        worldGraph: PlaceWorldGraph = .init(),
        continuityReviews: [PlaceContinuityReview] = [],
        worldGenerationBatches: [PlaceWorldGenerationBatch] = [],
        generatedImageRecords: [GeneratedBackgroundLibraryRecord] = [],
        pendingEditQueue: [PlaceImageEditQueueItem] = [],
        editBatchJobs: [PlaceImageEditBatchJob] = []
    ) {
        self.masterMapImagePath = masterMapImagePath
        self.landmarkReferences = landmarkReferences
        self.landmarkProfiles = landmarkProfiles
        self.photorealConfig = photorealConfig
        self.animatedConfig = animatedConfig
        self.worldGraph = worldGraph
        self.continuityReviews = continuityReviews
        self.worldGenerationBatches = worldGenerationBatches
        self.generatedImageRecords = generatedImageRecords
        self.pendingEditQueue = pendingEditQueue
        self.editBatchJobs = editBatchJobs
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        masterMapImagePath = try c.decodeIfPresent(String.self, forKey: .masterMapImagePath)
        landmarkReferences = try c.decodeIfPresent([PlaceReferenceImage].self, forKey: .landmarkReferences) ?? []
        landmarkProfiles = try c.decodeIfPresent([PlaceLandmarkProfile].self, forKey: .landmarkProfiles) ?? []
        photorealConfig = try c.decodeIfPresent(PlaceWorkflowRenderConfig.self, forKey: .photorealConfig) ?? .photorealDefault
        animatedConfig = try c.decodeIfPresent(PlaceWorkflowRenderConfig.self, forKey: .animatedConfig) ?? .animatedDefault
        worldGraph = try c.decodeIfPresent(PlaceWorldGraph.self, forKey: .worldGraph) ?? .init()
        continuityReviews = try c.decodeIfPresent([PlaceContinuityReview].self, forKey: .continuityReviews) ?? []
        worldGenerationBatches = try c.decodeIfPresent([PlaceWorldGenerationBatch].self, forKey: .worldGenerationBatches) ?? []
        generatedImageRecords = try c.decodeIfPresent([GeneratedBackgroundLibraryRecord].self, forKey: .generatedImageRecords) ?? []
        pendingEditQueue = try c.decodeIfPresent([PlaceImageEditQueueItem].self, forKey: .pendingEditQueue) ?? []
        editBatchJobs = try c.decodeIfPresent([PlaceImageEditBatchJob].self, forKey: .editBatchJobs) ?? []
    }
}

public struct PlacesWorldContextBlocks: Codable, Sendable, Equatable, Hashable {
    public var environmental: String
    public var timePeriod: String
    public var aesthetic: String

    public init(
        environmental: String = Self.defaultEnvironmental,
        timePeriod: String = Self.defaultTimePeriod,
        aesthetic: String = Self.defaultAesthetic
    ) {
        self.environmental = environmental
        self.timePeriod = timePeriod
        self.aesthetic = aesthetic
    }

    public static let defaultEnvironmental = """
    Exterior environment with open sky
    Persian-Afghan highland valley landscape
    Settlement on the north bank of the main river only
    Textured stone and mud-brick facades, weathered surfaces
    Overhead power lines and irregular signage
    Dry dust haze characteristic of arid subtropical climate
    """

    public static let defaultTimePeriod = """
    Contemporary present day, mid-2020s
    No future technology in frame
    Period-appropriate vehicles, clothing, and infrastructure
    Analog signage alongside modern mobile-era details
    """

    public static let defaultAesthetic = """
    Cinematic photorealism, documentary framing
    Natural light, golden-hour or overcast diffuse preferred
    Medium telephoto compression (85–135mm equivalent)
    Subtle film grain, no CGI smoothness
    Muted satellite-style palette — no HDR punch
    """
}

struct BackgroundPlate: Identifiable, Codable, Sendable {
    var id: UUID
    var name: String
    var filename: String
    var notes: String
    var coreIdentity: String = ""
    var geographicPlacement: String = ""
    var physicalLayoutAndTopography: String = ""
    var wartimeAndHistoricalContext: String = ""
    var imagePaths: [String]
    var approvedImagePath: String?
    var sourceURL: URL?
    var angleImages: [PlaceAngleImage]
    var locationCategory: String
    var sceneUsage: [String]
    var referenceImages: [PlaceReferenceImage]
    var workflowPromptNotes: String
    /// Canonical visual-only description of this place used for prompt assembly.
    /// Pure plain-language description of what the camera sees. No character names,
    /// no place slugs, no scene titles, no meta-instructions. Empty string = no brief.
    /// When empty the assembler omits the segment rather than falling back to legacy fields.
    var visualBrief: String = ""
    var sideOfRiver: String = ""
    var timeOfDay: String = ""
    var dayLabel: String = ""
    var positionInValley: String = ""
    var geographicPosition: String = ""
    var physicalDescription: String = ""
    var sensoryWorld: String = ""
    var culturalHistoricalContext: String = ""
    var inhabitantsActivity: String = ""
    var keyPropsSetDressing: String = ""
    var dramaticFunction: String = ""
    var visualContinuityAnchors: String = ""
    var sceneStateVariations: String = ""
    var humanActivityAndSocialUse: String = ""
    var nearbyConnections: String = ""
    var visualPaletteLighting: String = ""
    var cameraFramingNotes: String = ""
    var imageGenerationGuardrails: String = ""
    var formerTimeSpecificRecordsFoldedIntoLocation: String = ""
    var additionalGuidance: String = ""
    var imageGenerationPrompts: [String] = Array(repeating: "", count: 5)
    var animatedImagePaths: [String]
    var animatedApprovedImagePath: String?
    var buildingAnchorNodeID: UUID?
    var linkedExteriorPlaceID: UUID?
    /// 1-5 star rating per image path. 0 or missing = unrated.
    var imageRatings: [String: Int] = [:]
    /// Latest iPad-drawn storyboard sketch (project-relative path).
    /// Isolated from `imagePaths`/`referenceImages`: only the most recent
    /// drawing is retained — never historical versions. `nil` = blank canvas.
    var storyboardSketchPath: String? = nil

    enum CodingKeys: String, CodingKey {
        case id, name, filename, notes, imagePaths, approvedImagePath
        case coreIdentity, geographicPlacement, physicalLayoutAndTopography, wartimeAndHistoricalContext
        case angleImages, locationCategory, sceneUsage
        case referenceImages, workflowPromptNotes, visualBrief, animatedImagePaths, animatedApprovedImagePath
        case sideOfRiver, timeOfDay, dayLabel, positionInValley
        case geographicPosition, physicalDescription, sensoryWorld, culturalHistoricalContext
        case inhabitantsActivity, keyPropsSetDressing, dramaticFunction
        case visualContinuityAnchors, sceneStateVariations, humanActivityAndSocialUse, nearbyConnections
        case visualPaletteLighting, cameraFramingNotes, imageGenerationGuardrails
        case formerTimeSpecificRecordsFoldedIntoLocation, additionalGuidance, imageGenerationPrompts
        case buildingAnchorNodeID, linkedExteriorPlaceID
        case imageRatings
        case storyboardSketchPath
    }

    init(
        id: UUID = UUID(),
        name: String,
        filename: String,
        notes: String = "",
        coreIdentity: String = "",
        geographicPlacement: String = "",
        physicalLayoutAndTopography: String = "",
        wartimeAndHistoricalContext: String = "",
        imagePaths: [String] = [],
        approvedImagePath: String? = nil,
        sourceURL: URL? = nil,
        angleImages: [PlaceAngleImage] = [],
        locationCategory: String = "",
        sceneUsage: [String] = [],
        referenceImages: [PlaceReferenceImage] = [],
        workflowPromptNotes: String = "",
        visualBrief: String = "",
        sideOfRiver: String = "",
        timeOfDay: String = "",
        dayLabel: String = "",
        positionInValley: String = "",
        geographicPosition: String = "",
        physicalDescription: String = "",
        sensoryWorld: String = "",
        culturalHistoricalContext: String = "",
        inhabitantsActivity: String = "",
        keyPropsSetDressing: String = "",
        dramaticFunction: String = "",
        visualContinuityAnchors: String = "",
        sceneStateVariations: String = "",
        humanActivityAndSocialUse: String = "",
        nearbyConnections: String = "",
        visualPaletteLighting: String = "",
        cameraFramingNotes: String = "",
        imageGenerationGuardrails: String = "",
        formerTimeSpecificRecordsFoldedIntoLocation: String = "",
        additionalGuidance: String = "",
        imageGenerationPrompts: [String] = Array(repeating: "", count: 5),
        animatedImagePaths: [String] = [],
        animatedApprovedImagePath: String? = nil,
        buildingAnchorNodeID: UUID? = nil,
        linkedExteriorPlaceID: UUID? = nil
    ) {
        self.id = id
        self.name = name
        self.filename = filename
        self.notes = notes
        self.coreIdentity = coreIdentity
        self.geographicPlacement = geographicPlacement
        self.physicalLayoutAndTopography = physicalLayoutAndTopography
        self.wartimeAndHistoricalContext = wartimeAndHistoricalContext
        self.imagePaths = imagePaths
        self.approvedImagePath = approvedImagePath
        self.sourceURL = sourceURL
        self.angleImages = angleImages
        self.locationCategory = locationCategory
        self.sceneUsage = sceneUsage
        self.referenceImages = referenceImages
        self.workflowPromptNotes = workflowPromptNotes
        self.visualBrief = visualBrief
        self.sideOfRiver = sideOfRiver
        self.timeOfDay = timeOfDay
        self.dayLabel = dayLabel
        self.positionInValley = positionInValley
        self.geographicPosition = geographicPosition
        self.physicalDescription = physicalDescription
        self.sensoryWorld = sensoryWorld
        self.culturalHistoricalContext = culturalHistoricalContext
        self.inhabitantsActivity = inhabitantsActivity
        self.keyPropsSetDressing = keyPropsSetDressing
        self.dramaticFunction = dramaticFunction
        self.visualContinuityAnchors = visualContinuityAnchors
        self.sceneStateVariations = sceneStateVariations
        self.humanActivityAndSocialUse = humanActivityAndSocialUse
        self.nearbyConnections = nearbyConnections
        self.visualPaletteLighting = visualPaletteLighting
        self.cameraFramingNotes = cameraFramingNotes
        self.imageGenerationGuardrails = imageGenerationGuardrails
        self.formerTimeSpecificRecordsFoldedIntoLocation = formerTimeSpecificRecordsFoldedIntoLocation
        self.additionalGuidance = additionalGuidance
        self.imageGenerationPrompts = Array((imageGenerationPrompts + Array(repeating: "", count: 5)).prefix(5))
        self.animatedImagePaths = animatedImagePaths
        self.animatedApprovedImagePath = animatedApprovedImagePath
        self.buildingAnchorNodeID = buildingAnchorNodeID
        self.linkedExteriorPlaceID = linkedExteriorPlaceID
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        filename = try c.decodeIfPresent(String.self, forKey: .filename) ?? ""
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        func joinLegacy(_ fragments: [String]) -> String {
            fragments
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
        }
        func normalizeImageGenerationPrompts(_ prompts: [String]) -> [String] {
            Array((prompts + Array(repeating: "", count: 5)).prefix(5))
        }
        coreIdentity = try c.decodeIfPresent(String.self, forKey: .coreIdentity) ?? notes
        geographicPlacement = try c.decodeIfPresent(String.self, forKey: .geographicPlacement)
            ?? joinLegacy([
                try c.decodeIfPresent(String.self, forKey: .geographicPosition) ?? "",
                try c.decodeIfPresent(String.self, forKey: .sideOfRiver) ?? "",
                try c.decodeIfPresent(String.self, forKey: .positionInValley) ?? ""
            ])
        physicalLayoutAndTopography = try c.decodeIfPresent(String.self, forKey: .physicalLayoutAndTopography)
            ?? (try c.decodeIfPresent(String.self, forKey: .physicalDescription) ?? "")
        wartimeAndHistoricalContext = try c.decodeIfPresent(String.self, forKey: .wartimeAndHistoricalContext)
            ?? (try c.decodeIfPresent(String.self, forKey: .culturalHistoricalContext) ?? "")
        imagePaths = try c.decodeIfPresent([String].self, forKey: .imagePaths) ?? []
        approvedImagePath = try c.decodeIfPresent(String.self, forKey: .approvedImagePath)
        sourceURL = nil
        angleImages = try c.decodeIfPresent([PlaceAngleImage].self, forKey: .angleImages) ?? []
        locationCategory = try c.decodeIfPresent(String.self, forKey: .locationCategory) ?? ""
        sceneUsage = try c.decodeIfPresent([String].self, forKey: .sceneUsage) ?? []
        referenceImages = try c.decodeIfPresent([PlaceReferenceImage].self, forKey: .referenceImages) ?? []
        workflowPromptNotes = try c.decodeIfPresent(String.self, forKey: .workflowPromptNotes) ?? ""
        visualBrief = try c.decodeIfPresent(String.self, forKey: .visualBrief) ?? ""
        sideOfRiver = try c.decodeIfPresent(String.self, forKey: .sideOfRiver) ?? ""
        timeOfDay = try c.decodeIfPresent(String.self, forKey: .timeOfDay) ?? ""
        dayLabel = try c.decodeIfPresent(String.self, forKey: .dayLabel) ?? ""
        positionInValley = try c.decodeIfPresent(String.self, forKey: .positionInValley) ?? ""
        geographicPosition = try c.decodeIfPresent(String.self, forKey: .geographicPosition) ?? ""
        physicalDescription = try c.decodeIfPresent(String.self, forKey: .physicalDescription) ?? ""
        sensoryWorld = try c.decodeIfPresent(String.self, forKey: .sensoryWorld) ?? ""
        culturalHistoricalContext = try c.decodeIfPresent(String.self, forKey: .culturalHistoricalContext) ?? ""
        inhabitantsActivity = try c.decodeIfPresent(String.self, forKey: .inhabitantsActivity) ?? ""
        keyPropsSetDressing = try c.decodeIfPresent(String.self, forKey: .keyPropsSetDressing) ?? ""
        dramaticFunction = try c.decodeIfPresent(String.self, forKey: .dramaticFunction) ?? ""
        visualContinuityAnchors = try c.decodeIfPresent(String.self, forKey: .visualContinuityAnchors) ?? ""
        sceneStateVariations = try c.decodeIfPresent(String.self, forKey: .sceneStateVariations)
            ?? joinLegacy([
                timeOfDay,
                dayLabel,
                try c.decodeIfPresent(String.self, forKey: .visualPaletteLighting) ?? ""
            ])
        humanActivityAndSocialUse = try c.decodeIfPresent(String.self, forKey: .humanActivityAndSocialUse)
            ?? inhabitantsActivity
        nearbyConnections = try c.decodeIfPresent(String.self, forKey: .nearbyConnections) ?? ""
        visualPaletteLighting = try c.decodeIfPresent(String.self, forKey: .visualPaletteLighting) ?? ""
        cameraFramingNotes = try c.decodeIfPresent(String.self, forKey: .cameraFramingNotes) ?? ""
        imageGenerationGuardrails = try c.decodeIfPresent(String.self, forKey: .imageGenerationGuardrails)
            ?? joinLegacy([
                workflowPromptNotes,
                cameraFramingNotes
            ])
        formerTimeSpecificRecordsFoldedIntoLocation = try c.decodeIfPresent(
            String.self,
            forKey: .formerTimeSpecificRecordsFoldedIntoLocation
        ) ?? ""
        additionalGuidance = try c.decodeIfPresent(String.self, forKey: .additionalGuidance)
            ?? joinLegacy([
                try c.decodeIfPresent(String.self, forKey: .sensoryWorld) ?? "",
                keyPropsSetDressing
            ])
        imageGenerationPrompts = normalizeImageGenerationPrompts(
            try c.decodeIfPresent([String].self, forKey: .imageGenerationPrompts) ?? []
        )
        animatedImagePaths = try c.decodeIfPresent([String].self, forKey: .animatedImagePaths) ?? []
        animatedApprovedImagePath = try c.decodeIfPresent(String.self, forKey: .animatedApprovedImagePath)
        buildingAnchorNodeID = try c.decodeIfPresent(UUID.self, forKey: .buildingAnchorNodeID)
        linkedExteriorPlaceID = try c.decodeIfPresent(UUID.self, forKey: .linkedExteriorPlaceID)
        imageRatings = try c.decodeIfPresent([String: Int].self, forKey: .imageRatings) ?? [:]
        storyboardSketchPath = try c.decodeIfPresent(String.self, forKey: .storyboardSketchPath)
    }

    var resolvedApprovedImagePath: String? {
        approvedImagePath ?? imagePaths.first
    }

    var resolvedAnimatedApprovedImagePath: String? {
        animatedApprovedImagePath ?? animatedImagePaths.first
    }

    func imagePaths(for workflow: PlaceWorkflowMode) -> [String] {
        switch workflow {
        case .photorealistic:
            imagePaths
        case .animated:
            animatedImagePaths
        }
    }

    func approvedImagePath(for workflow: PlaceWorkflowMode) -> String? {
        switch workflow {
        case .photorealistic:
            resolvedApprovedImagePath
        case .animated:
            resolvedAnimatedApprovedImagePath
        }
    }

    var effectiveVisualBrief: String {
        let existing = visualBrief.trimmingCharacters(in: .whitespacesAndNewlines)
        if !existing.isEmpty {
            return existing
        }

        return [
            coreIdentity,
            geographicPlacement,
            physicalLayoutAndTopography,
            wartimeAndHistoricalContext,
            visualContinuityAnchors,
            sceneStateVariations,
            humanActivityAndSocialUse,
            nearbyConnections,
            imageGenerationGuardrails,
            additionalGuidance
        ]
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .joined(separator: " ")
    }

    var promptSupportText: String {
        [
            name,
            locationCategory,
            notes,
            workflowPromptNotes,
            coreIdentity,
            geographicPlacement,
            physicalLayoutAndTopography,
            wartimeAndHistoricalContext,
            visualContinuityAnchors,
            sceneStateVariations,
            humanActivityAndSocialUse,
            nearbyConnections,
            imageGenerationGuardrails,
            additionalGuidance,
            effectiveVisualBrief
        ]
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .joined(separator: " ")
    }

    /// All unique camera shot types present in angle images.
    var coveredCameraShots: Set<String> {
        Set(angleImages.compactMap(\.cameraShot))
    }

    var isExteriorLike: Bool {
        locationCategory.caseInsensitiveCompare("Interior") != .orderedSame
    }
}

// MARK: - Gemini

enum GeminiModel: String, Codable, Sendable, CaseIterable {
    case flash = "gemini-3.1-flash-image-preview"
    case pro = "gemini-3-pro-image-preview"

    var displayName: String {
        switch self {
        case .flash: "Nano Banana 2"
        case .pro: "Nano Banana Pro"
        }
    }

    var estimatedCostPerImage: Double {
        estimatedCost(for: "1K")
    }

    func estimatedCost(for imageSize: String) -> Double {
        switch self {
        case .flash:
            switch imageSize {
            case "4K": 0.150
            case "2K": 0.101
            default: 0.067
            }
        case .pro:
            switch imageSize {
            case "4K": 0.240
            default: 0.134
            }
        }
    }

    func estimatedBatchCost(for imageSize: String) -> Double {
        switch self {
        case .flash:
            switch imageSize {
            case "4K": 0.076
            case "2K": 0.050
            default: 0.034
            }
        case .pro:
            switch imageSize {
            case "4K": 0.120
            default: 0.067
            }
        }
    }
}

// MARK: - OWP Stubs (for sidebar display)

struct OWPSongStub: Identifiable, Codable, Sendable {
    var id: UUID
    var title: String
    var owsPath: String
    var durationTicks: Int?
}

// MARK: - Easing / Interpolation

enum EasingCurve: Codable, Sendable {
    case linear
    case stepped
    case easeIn
    case easeOut
    case easeInOut
    case custom(cx1: Float, cy1: Float, cx2: Float, cy2: Float)
}

// MARK: - Visemes (Lip Sync)

enum PrestonBlairViseme: Int, Codable, Sendable, CaseIterable {
    case rest = 0
    case ai = 1      // A, I — apple, dive
    case e = 2       // E — free, egg
    case o = 3       // O — hot, goat
    case u = 4       // U — fund, you
    case consonant = 5  // C,D,G,K,N,R,S,Y,Z
    case fv = 6      // F, V — lower lip under upper teeth
    case l = 7       // L — tongue tip visible
    case mbp = 8     // M, B, P — lips pressed
    case wq = 9      // W, Q — pursed lips

    var label: String {
        switch self {
        case .rest: "Rest"
        case .ai: "A/I"
        case .e: "E"
        case .o: "O"
        case .u: "U"
        case .consonant: "C/D/G/K"
        case .fv: "F/V"
        case .l: "L"
        case .mbp: "M/B/P"
        case .wq: "W/Q"
        }
    }

    var token: String {
        switch self {
        case .rest: "rest"
        case .ai: "ai"
        case .e: "e"
        case .o: "o"
        case .u: "u"
        case .consonant: "consonant"
        case .fv: "fv"
        case .l: "l"
        case .mbp: "mbp"
        case .wq: "wq"
        }
    }
}

// MARK: - Timeline Tracks

enum TimelineTrackRole: String, Codable, Sendable, CaseIterable {
    case transform
    case visibility
    case facing
    case view
    case pose
    case expression
    case action
    case mouth
    case shadowStyle
    case shadowOpacity
    case drawing
    case camera
    case cameraShot
    case cameraDefaultShot
    case cameraFocus
    case cameraIntent
    case cameraBeat
    case cameraNotes
    case custom

    init(trackSuffix: String) {
        switch trackSuffix.lowercased() {
        case "transform": self = .transform
        case "visibility": self = .visibility
        case "facing": self = .facing
        case "view": self = .view
        case "pose": self = .pose
        case "expression": self = .expression
        case "action": self = .action
        case "mouth": self = .mouth
        case "shadow-style": self = .shadowStyle
        case "shadow-opacity": self = .shadowOpacity
        case "drawing": self = .drawing
        case "camera": self = .camera
        case "shot": self = .cameraShot
        case "default-shot": self = .cameraDefaultShot
        case "focus": self = .cameraFocus
        case "intent": self = .cameraIntent
        case "beat": self = .cameraBeat
        case "notes": self = .cameraNotes
        default: self = .custom
        }
    }

    var trackSuffix: String {
        switch self {
        case .transform: "transform"
        case .visibility: "visibility"
        case .facing: "facing"
        case .view: "view"
        case .pose: "pose"
        case .expression: "expression"
        case .action: "action"
        case .mouth: "mouth"
        case .shadowStyle: "shadow-style"
        case .shadowOpacity: "shadow-opacity"
        case .drawing: "drawing"
        case .camera: "camera"
        case .cameraShot: "shot"
        case .cameraDefaultShot: "default-shot"
        case .cameraFocus: "focus"
        case .cameraIntent: "intent"
        case .cameraBeat: "beat"
        case .cameraNotes: "notes"
        case .custom: "custom"
        }
    }

    var displayLabel: String {
        switch self {
        case .transform: "Transform"
        case .visibility: "Visibility"
        case .facing: "Facing"
        case .view: "View"
        case .pose: "Pose"
        case .expression: "Expression"
        case .action: "Action"
        case .mouth: "Mouth"
        case .shadowStyle: "Shadow Style"
        case .shadowOpacity: "Shadow Opacity"
        case .drawing: "Drawing"
        case .camera: "Camera"
        case .cameraShot: "Shot"
        case .cameraDefaultShot: "Default Shot"
        case .cameraFocus: "Focus"
        case .cameraIntent: "Intent"
        case .cameraBeat: "Beat"
        case .cameraNotes: "Notes"
        case .custom: "Track"
        }
    }
}

/// A single timeline track containing sparse keyframes.
struct TimelineTrack: Codable, Sendable {
    var name: String
    var keyframes: [TimelineKeyframe]
    var targetCharacterID: UUID?
    var role: TimelineTrackRole?

    init(
        name: String,
        keyframes: [TimelineKeyframe],
        targetCharacterID: UUID? = nil,
        role: TimelineTrackRole? = nil
    ) {
        self.name = name
        self.keyframes = keyframes
        self.targetCharacterID = targetCharacterID
        self.role = role
    }

    /// Find the two keyframes surrounding a given frame for interpolation.
    /// Keyframes are kept sorted by frame at all mutation sites, so no sort needed here.
    func surroundingKeyframes(at frame: Int) -> (before: TimelineKeyframe?, after: TimelineKeyframe?) {
        var before: TimelineKeyframe?
        var after: TimelineKeyframe?

        for kf in keyframes {
            if kf.frame <= frame {
                before = kf
            } else {
                after = kf
                break
            }
        }

        return (before, after)
    }
}

/// A single keyframe on the timeline.
struct TimelineKeyframe: Identifiable, Codable, Sendable {
    var id: UUID
    var frame: Int
    var kind: KeyframeKind
    var easing: EasingCurve
    var value: KeyframeValue

    init(id: UUID = UUID(), frame: Int, kind: KeyframeKind, easing: EasingCurve = .linear, value: KeyframeValue = .transform(.identity)) {
        self.id = id
        self.frame = frame
        self.kind = kind
        self.easing = easing
        self.value = value
    }
}

enum KeyframeKind: String, Codable, Sendable, CaseIterable {
    case transform    // position, rotation, scale
    case visibility   // show/hide, opacity
    case drawing      // swap which sprite/part is active
    case expression   // change facial expression
}

enum KeyframeValue: Codable, Sendable {
    case transform(CharacterTransform)
    case visibility(opacity: Double, visible: Bool)
    case drawing(variantID: UUID)
    case expression(name: String)
}
