import Foundation

struct LLMAnimationPlan: Codable, Sendable {
    static let currentSchemaVersion = 6

    var schemaVersion: Int = LLMAnimationPlan.currentSchemaVersion
    var sceneName: String
    var backgroundName: String? = nil
    var lighting: String? = nil
    var sceneAudioPath: String? = nil
    var characterPlacements: [LLMCharacterPlacement] = []
    var motions: [LLMCharacterMotion] = []
    var expressions: [LLMCharacterExpressionCue] = []
    var dialogueBeats: [LLMDialogueBeat] = []
    var shadowCues: [LLMCharacterShadowCue] = []
    var cameraMoves: [LLMCameraMove] = []
    var shotPresetApplications: [LLMShotPresetApplication] = []
    var notes: [String] = []

    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case sceneName
        case backgroundName
        case lighting
        case sceneAudioPath
        case characterPlacements
        case motions
        case expressions
        case dialogueBeats
        case shadowCues
        case cameraMoves
        case shotPresetApplications
        case notes
    }

    init(
        schemaVersion: Int = LLMAnimationPlan.currentSchemaVersion,
        sceneName: String,
        backgroundName: String? = nil,
        lighting: String? = nil,
        sceneAudioPath: String? = nil,
        characterPlacements: [LLMCharacterPlacement] = [],
        motions: [LLMCharacterMotion] = [],
        expressions: [LLMCharacterExpressionCue] = [],
        dialogueBeats: [LLMDialogueBeat] = [],
        shadowCues: [LLMCharacterShadowCue] = [],
        cameraMoves: [LLMCameraMove] = [],
        shotPresetApplications: [LLMShotPresetApplication] = [],
        notes: [String] = []
    ) {
        self.schemaVersion = schemaVersion
        self.sceneName = sceneName
        self.backgroundName = backgroundName
        self.lighting = lighting
        self.sceneAudioPath = sceneAudioPath
        self.characterPlacements = characterPlacements
        self.motions = motions
        self.expressions = expressions
        self.dialogueBeats = dialogueBeats
        self.shadowCues = shadowCues
        self.cameraMoves = cameraMoves
        self.shotPresetApplications = shotPresetApplications
        self.notes = notes
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? Self.currentSchemaVersion
        sceneName = try container.decode(String.self, forKey: .sceneName)
        backgroundName = try container.decodeIfPresent(String.self, forKey: .backgroundName)
        lighting = try container.decodeIfPresent(String.self, forKey: .lighting)
        sceneAudioPath = try container.decodeIfPresent(String.self, forKey: .sceneAudioPath)
        characterPlacements = try container.decodeIfPresent([LLMCharacterPlacement].self, forKey: .characterPlacements) ?? []
        motions = try container.decodeIfPresent([LLMCharacterMotion].self, forKey: .motions) ?? []
        expressions = try container.decodeIfPresent([LLMCharacterExpressionCue].self, forKey: .expressions) ?? []
        dialogueBeats = try container.decodeIfPresent([LLMDialogueBeat].self, forKey: .dialogueBeats) ?? []
        shadowCues = try container.decodeIfPresent([LLMCharacterShadowCue].self, forKey: .shadowCues) ?? []
        cameraMoves = try container.decodeIfPresent([LLMCameraMove].self, forKey: .cameraMoves) ?? []
        shotPresetApplications = try container.decodeIfPresent([LLMShotPresetApplication].self, forKey: .shotPresetApplications) ?? []
        notes = try container.decodeIfPresent([String].self, forKey: .notes) ?? []
    }
}

struct LLMShotPresetApplication: Codable, Sendable, Hashable {
    var presetName: String
    var frame: Int
    var cameraShot: CameraShot? = nil
    var focusCharacterName: String? = nil
    var shotIntent: ShotIntent? = nil
    var beatLabel: String? = nil
    var beatNotes: String? = nil
    var characterOverrides: [LLMShotPresetCharacterOverride] = []

    enum CodingKeys: String, CodingKey {
        case presetName
        case frame
        case cameraShot
        case focusCharacterName
        case shotIntent
        case beatLabel
        case beatNotes
        case characterOverrides
    }

    init(
        presetName: String,
        frame: Int,
        cameraShot: CameraShot? = nil,
        focusCharacterName: String? = nil,
        shotIntent: ShotIntent? = nil,
        beatLabel: String? = nil,
        beatNotes: String? = nil,
        characterOverrides: [LLMShotPresetCharacterOverride] = []
    ) {
        self.presetName = presetName
        self.frame = frame
        self.cameraShot = cameraShot
        self.focusCharacterName = focusCharacterName
        self.shotIntent = shotIntent
        self.beatLabel = beatLabel
        self.beatNotes = beatNotes
        self.characterOverrides = characterOverrides
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        presetName = try container.decode(String.self, forKey: .presetName)
        frame = try container.decode(Int.self, forKey: .frame)
        cameraShot = try container.decodeIfPresent(CameraShot.self, forKey: .cameraShot)
        focusCharacterName = try container.decodeIfPresent(String.self, forKey: .focusCharacterName)
        shotIntent = try container.decodeIfPresent(ShotIntent.self, forKey: .shotIntent)
        beatLabel = try container.decodeIfPresent(String.self, forKey: .beatLabel)
        beatNotes = try container.decodeIfPresent(String.self, forKey: .beatNotes)
        characterOverrides = try container.decodeIfPresent([LLMShotPresetCharacterOverride].self, forKey: .characterOverrides) ?? []
    }
}

struct LLMShotPresetCharacterOverride: Codable, Sendable, Hashable {
    var characterName: String
    var facing: FacingDirection?
    var viewAngle: AngleView?
    var pose: CharacterPackagePose?
    var expression: String?
    var action: String?

    init(
        characterName: String,
        facing: FacingDirection? = nil,
        viewAngle: AngleView? = nil,
        pose: CharacterPackagePose? = nil,
        expression: String? = nil,
        action: String? = nil
    ) {
        self.characterName = characterName
        self.facing = facing
        self.viewAngle = viewAngle
        self.pose = pose
        self.expression = expression
        self.action = action
    }
}

struct LLMDialogueBeat: Codable, Sendable, Hashable {
    var characterName: String
    var startFrame: Int
    var audioPath: String
    var transcript: String?
    var expression: String?
    var action: String?

    init(
        characterName: String,
        startFrame: Int,
        audioPath: String,
        transcript: String? = nil,
        expression: String? = nil,
        action: String? = nil
    ) {
        self.characterName = characterName
        self.startFrame = startFrame
        self.audioPath = audioPath
        self.transcript = transcript
        self.expression = expression
        self.action = action
    }
}

struct LLMCharacterShadowCue: Codable, Sendable, Hashable {
    var characterName: String
    var frame: Int
    var style: ShadowStyle
    var opacity: Double?

    init(
        characterName: String,
        frame: Int,
        style: ShadowStyle,
        opacity: Double? = nil
    ) {
        self.characterName = characterName
        self.frame = frame
        self.style = style
        self.opacity = opacity
    }
}

struct LLMAnimationPoint: Codable, Sendable, Hashable {
    var x: Double
    var y: Double

    init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

enum LLMAnimationEasing: String, Codable, Sendable, CaseIterable, Hashable {
    case linear
    case stepped
    case easeIn = "ease_in"
    case easeOut = "ease_out"
    case easeInOut = "ease_in_out"

    var runtimeCurve: EasingCurve {
        switch self {
        case .linear: return .linear
        case .stepped: return .stepped
        case .easeIn: return .easeIn
        case .easeOut: return .easeOut
        case .easeInOut: return .easeInOut
        }
    }
}

struct LLMCharacterPlacement: Codable, Sendable, Hashable {
    var characterName: String
    var frame: Int
    var position: LLMAnimationPoint
    var facing: FacingDirection?
    var viewAngle: AngleView?
    var pose: CharacterPackagePose?
    var emotion: String?
    var zOrder: Int?

    init(
        characterName: String,
        frame: Int = 0,
        position: LLMAnimationPoint,
        facing: FacingDirection? = nil,
        viewAngle: AngleView? = nil,
        pose: CharacterPackagePose? = nil,
        emotion: String? = nil,
        zOrder: Int? = nil
    ) {
        self.characterName = characterName
        self.frame = frame
        self.position = position
        self.facing = facing
        self.viewAngle = viewAngle
        self.pose = pose
        self.emotion = emotion
        self.zOrder = zOrder
    }
}

struct LLMCharacterMotion: Codable, Sendable, Hashable {
    var characterName: String
    var startFrame: Int
    var endFrame: Int?
    var from: LLMAnimationPoint?
    var to: LLMAnimationPoint
    var easing: LLMAnimationEasing
    var paceUnitsPerSecond: Double?
    var facing: FacingDirection?
    var viewAngle: AngleView?
    var pose: CharacterPackagePose?
    var movementStyle: String?
    var zOrder: Int?

    init(
        characterName: String,
        startFrame: Int,
        endFrame: Int? = nil,
        from: LLMAnimationPoint? = nil,
        to: LLMAnimationPoint,
        easing: LLMAnimationEasing = .easeInOut,
        paceUnitsPerSecond: Double? = nil,
        facing: FacingDirection? = nil,
        viewAngle: AngleView? = nil,
        pose: CharacterPackagePose? = nil,
        movementStyle: String? = nil,
        zOrder: Int? = nil
    ) {
        self.characterName = characterName
        self.startFrame = startFrame
        self.endFrame = endFrame
        self.from = from
        self.to = to
        self.easing = easing
        self.paceUnitsPerSecond = paceUnitsPerSecond
        self.facing = facing
        self.viewAngle = viewAngle
        self.pose = pose
        self.movementStyle = movementStyle
        self.zOrder = zOrder
    }
}

struct LLMCharacterExpressionCue: Codable, Sendable, Hashable {
    var characterName: String
    var frame: Int
    var expression: String

    init(characterName: String, frame: Int, expression: String) {
        self.characterName = characterName
        self.frame = frame
        self.expression = expression
    }
}

struct LLMCameraMove: Codable, Sendable, Hashable {
    var movement: CameraMovement
    var startFrame: Int
    var endFrame: Int
    var fromShot: CameraShot?
    var toShot: CameraShot?
    var easing: LLMAnimationEasing

    init(
        movement: CameraMovement,
        startFrame: Int,
        endFrame: Int,
        fromShot: CameraShot? = nil,
        toShot: CameraShot? = nil,
        easing: LLMAnimationEasing = .easeInOut
    ) {
        self.movement = movement
        self.startFrame = startFrame
        self.endFrame = endFrame
        self.fromShot = fromShot
        self.toShot = toShot
        self.easing = easing
    }
}

struct LLMAnimationValidationIssue: Identifiable, Sendable, Hashable {
    enum Severity: String, Codable, Sendable, Hashable {
        case warning
        case error
    }

    enum Code: String, Codable, Sendable, Hashable {
        case invalidJSON
        case unsupportedSchemaVersion
        case noSceneAvailable
        case emptySceneName
        case emptyCharacterName
        case emptyShotPresetName
        case unknownCharacter
        case unknownShotPreset
        case ambiguousShotPreset
        case invalidFrameRange
        case invalidPosition
        case invalidPace
        case invalidOpacity
        case motionMissingDestination
        case emptyAudioPath
        case missingAudioFile
    }

    var id: UUID
    var severity: Severity
    var code: Code
    var message: String

    init(
        id: UUID = UUID(),
        severity: Severity,
        code: Code,
        message: String
    ) {
        self.id = id
        self.severity = severity
        self.code = code
        self.message = message
    }
}

struct LLMAnimationValidationReport: Sendable {
    var issues: [LLMAnimationValidationIssue]

    var isValid: Bool {
        !issues.contains { $0.severity == .error }
    }
}
