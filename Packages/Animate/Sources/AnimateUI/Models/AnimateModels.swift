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
    var id: UUID
    var title: String
    var batchName: String
    var metadataPath: String
    var outputRootPath: String
    var state: String
    var promptCount: Int
    var submittedAt: Date
    var lastCheckedAt: Date?
    var downloadedImagePaths: [String]
    var autoImportedImagePaths: [String]
    var lastErrorMessage: String?

    init(
        id: UUID = UUID(),
        title: String,
        batchName: String,
        metadataPath: String,
        outputRootPath: String,
        state: String,
        promptCount: Int,
        submittedAt: Date = Date(),
        lastCheckedAt: Date? = nil,
        downloadedImagePaths: [String] = [],
        autoImportedImagePaths: [String] = [],
        lastErrorMessage: String? = nil
    ) {
        self.id = id
        self.title = title
        self.batchName = batchName
        self.metadataPath = metadataPath
        self.outputRootPath = outputRootPath
        self.state = state
        self.promptCount = promptCount
        self.submittedAt = submittedAt
        self.lastCheckedAt = lastCheckedAt
        self.downloadedImagePaths = downloadedImagePaths
        self.autoImportedImagePaths = autoImportedImagePaths
        self.lastErrorMessage = lastErrorMessage
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "Inspiration Batch"
        batchName = try c.decodeIfPresent(String.self, forKey: .batchName) ?? ""
        metadataPath = try c.decodeIfPresent(String.self, forKey: .metadataPath) ?? ""
        outputRootPath = try c.decodeIfPresent(String.self, forKey: .outputRootPath) ?? ""
        state = try c.decodeIfPresent(String.self, forKey: .state) ?? "JOB_STATE_PENDING"
        promptCount = try c.decodeIfPresent(Int.self, forKey: .promptCount) ?? 0
        submittedAt = try c.decodeIfPresent(Date.self, forKey: .submittedAt) ?? Date(timeIntervalSinceReferenceDate: 0)
        lastCheckedAt = try c.decodeIfPresent(Date.self, forKey: .lastCheckedAt)
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

struct AnimationCharacter: Identifiable, Codable, Sendable {
    static let currentSchemaVersion = 2

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
    var inspirationReferenceImagePath: String?
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
    var costumeReferenceSets: [CharacterCostumeReferenceSet]
    var models3D: [Character3DModel]

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
        inspirationReferenceImagePath: String? = nil,
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
        costumeReferenceSets: [CharacterCostumeReferenceSet] = [],
        models3D: [Character3DModel] = []
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
        self.inspirationReferenceImagePath = inspirationReferenceImagePath
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
        self.costumeReferenceSets = costumeReferenceSets
        self.models3D = models3D
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
        inspirationReferenceImagePath = try c.decodeIfPresent(String.self, forKey: .inspirationReferenceImagePath)
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
        costumeReferenceSets = try c.decodeIfPresent([CharacterCostumeReferenceSet].self, forKey: .costumeReferenceSets) ?? []
        models3D = try c.decodeIfPresent([Character3DModel].self, forKey: .models3D) ?? []
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

struct PlaceAngleImage: Codable, Identifiable, Sendable {
    var id: UUID = UUID()
    var imagePath: String
    var cameraShot: String?     // "wide", "medium", "close", etc.
    var angle: String?          // "front", "left", "right", "overhead"
    var timeOfDay: String?      // "day", "night", "dawn", "dusk"
    var notes: String = ""

    enum CodingKeys: String, CodingKey {
        case id, imagePath, cameraShot, angle, timeOfDay, notes
    }

    init(
        id: UUID = UUID(),
        imagePath: String,
        cameraShot: String? = nil,
        angle: String? = nil,
        timeOfDay: String? = nil,
        notes: String = ""
    ) {
        self.id = id
        self.imagePath = imagePath
        self.cameraShot = cameraShot
        self.angle = angle
        self.timeOfDay = timeOfDay
        self.notes = notes
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        imagePath = try c.decode(String.self, forKey: .imagePath)
        cameraShot = try c.decodeIfPresent(String.self, forKey: .cameraShot)
        angle = try c.decodeIfPresent(String.self, forKey: .angle)
        timeOfDay = try c.decodeIfPresent(String.self, forKey: .timeOfDay)
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
    }
}

struct BackgroundPlate: Identifiable, Codable, Sendable {
    var id: UUID
    var name: String
    var filename: String
    var notes: String
    var imagePaths: [String]
    var approvedImagePath: String?
    var sourceURL: URL?
    var angleImages: [PlaceAngleImage]
    var locationCategory: String
    var sceneUsage: [String]

    enum CodingKeys: String, CodingKey {
        case id, name, filename, notes, imagePaths, approvedImagePath
        case angleImages, locationCategory, sceneUsage
    }

    init(
        id: UUID = UUID(),
        name: String,
        filename: String,
        notes: String = "",
        imagePaths: [String] = [],
        approvedImagePath: String? = nil,
        sourceURL: URL? = nil,
        angleImages: [PlaceAngleImage] = [],
        locationCategory: String = "",
        sceneUsage: [String] = []
    ) {
        self.id = id
        self.name = name
        self.filename = filename
        self.notes = notes
        self.imagePaths = imagePaths
        self.approvedImagePath = approvedImagePath
        self.sourceURL = sourceURL
        self.angleImages = angleImages
        self.locationCategory = locationCategory
        self.sceneUsage = sceneUsage
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        filename = try c.decodeIfPresent(String.self, forKey: .filename) ?? ""
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        imagePaths = try c.decodeIfPresent([String].self, forKey: .imagePaths) ?? []
        approvedImagePath = try c.decodeIfPresent(String.self, forKey: .approvedImagePath)
        sourceURL = nil
        angleImages = try c.decodeIfPresent([PlaceAngleImage].self, forKey: .angleImages) ?? []
        locationCategory = try c.decodeIfPresent(String.self, forKey: .locationCategory) ?? ""
        sceneUsage = try c.decodeIfPresent([String].self, forKey: .sceneUsage) ?? []
    }

    var resolvedApprovedImagePath: String? {
        approvedImagePath ?? imagePaths.first
    }

    /// All unique camera shot types present in angle images.
    var coveredCameraShots: Set<String> {
        Set(angleImages.compactMap(\.cameraShot))
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
            case "4K": 0.151
            case "2K": 0.101
            default: 0.067
            }
        case .pro:
            0.134
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
