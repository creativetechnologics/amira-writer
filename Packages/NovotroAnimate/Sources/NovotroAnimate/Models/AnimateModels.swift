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
    var keyframes: [SceneKeyframe]
    var owpSongPath: String
    var defaultAudioPath: String? = nil
    var tracks: [String: TimelineTrack] = [:]
    var directionTemplate: SceneDirectionTemplate? = nil
}

/// Persistence format for scenes.json inside Animate/ directory.
struct AnimateSceneData: Codable, Sendable {
    var owsSongPath: String
    var backgroundID: UUID?
    var characterIDs: [UUID]
    var characterSlugs: [String] = []
    var keyframes: [SceneKeyframe]
    var defaultAudioPath: String? = nil
    var tracks: [String: TimelineTrack]
    var directionTemplate: SceneDirectionTemplate? = nil
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

struct AnimationCharacter: Identifiable, Codable, Sendable {
    var id: UUID
    var sortOrder: Int?
    var name: String
    var description: String
    var owpSlug: String
    var renderMode: CharacterCanvasRenderMode?
    var preferredViewAngle: AngleView?
    var parts: [RigPart]

    var profileImagePath: String?
    var backstory: String
    var personality: String
    var notes: String
    var inspirationImagePaths: [String]
    var inspirationReferenceImagePath: String?
    var referenceImagePaths: [String]
    var animatedImagePaths: [String]

    init(
        id: UUID,
        sortOrder: Int? = nil,
        name: String,
        description: String,
        owpSlug: String,
        renderMode: CharacterCanvasRenderMode? = nil,
        preferredViewAngle: AngleView? = nil,
        parts: [RigPart],
        profileImagePath: String? = nil,
        backstory: String = "",
        personality: String = "",
        notes: String = "",
        inspirationImagePaths: [String] = [],
        inspirationReferenceImagePath: String? = nil,
        referenceImagePaths: [String] = [],
        animatedImagePaths: [String] = []
    ) {
        self.id = id
        self.sortOrder = sortOrder
        self.name = name
        self.description = description
        self.owpSlug = owpSlug
        self.renderMode = renderMode
        self.preferredViewAngle = preferredViewAngle
        self.parts = parts
        self.profileImagePath = profileImagePath
        self.backstory = backstory
        self.personality = personality
        self.notes = notes
        self.inspirationImagePaths = inspirationImagePaths
        self.inspirationReferenceImagePath = inspirationReferenceImagePath
        self.referenceImagePaths = referenceImagePaths
        self.animatedImagePaths = animatedImagePaths
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        sortOrder = try c.decodeIfPresent(Int.self, forKey: .sortOrder)
        name = try c.decode(String.self, forKey: .name)
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        owpSlug = try c.decodeIfPresent(String.self, forKey: .owpSlug) ?? ""
        renderMode = try c.decodeIfPresent(CharacterCanvasRenderMode.self, forKey: .renderMode)
        preferredViewAngle = try c.decodeIfPresent(AngleView.self, forKey: .preferredViewAngle)
        parts = try c.decodeIfPresent([RigPart].self, forKey: .parts) ?? []
        profileImagePath = try c.decodeIfPresent(String.self, forKey: .profileImagePath)
        backstory = try c.decodeIfPresent(String.self, forKey: .backstory) ?? ""
        personality = try c.decodeIfPresent(String.self, forKey: .personality) ?? ""
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        inspirationImagePaths = try c.decodeIfPresent([String].self, forKey: .inspirationImagePaths) ?? []
        inspirationReferenceImagePath = try c.decodeIfPresent(String.self, forKey: .inspirationReferenceImagePath)
        referenceImagePaths = try c.decodeIfPresent([String].self, forKey: .referenceImagePaths) ?? []
        animatedImagePaths = try c.decodeIfPresent([String].self, forKey: .animatedImagePaths) ?? []
    }

    var resolvedRenderMode: CharacterCanvasRenderMode {
        renderMode ?? .packagePreview
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

struct BackgroundPlate: Identifiable, Codable, Sendable {
    var id: UUID
    var name: String
    var filename: String
    var sourceURL: URL?

    enum CodingKeys: String, CodingKey {
        case id, name, filename
    }
}

// MARK: - Gemini

enum GeminiModel: String, Codable, Sendable, CaseIterable {
    case flash = "gemini-2.5-flash-image"
    case pro = "gemini-3-pro-image-preview"

    var displayName: String {
        switch self {
        case .flash: "Nano Banana (Flash)"
        case .pro: "Nano Banana Pro"
        }
    }

    var estimatedCostPerImage: Double {
        switch self {
        case .flash: 0.039
        case .pro: 0.10
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
