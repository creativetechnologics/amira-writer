import Foundation

struct LLMAnimationPlan: Codable, Sendable {
    static let currentSchemaVersion = 8

    var schemaVersion: Int = LLMAnimationPlan.currentSchemaVersion
    var sceneName: String
    var backgroundName: String? = nil
    var lighting: String? = nil
    var sceneAudioPath: String? = nil
    var characterPlacements: [LLMCharacterPlacement] = []
    var objectPlacements: [LLMObjectPlacement] = []
    var motions: [LLMCharacterMotion] = []
    var objectMotions: [LLMObjectMotion] = []
    var expressions: [LLMCharacterExpressionCue] = []
    var dialogueBeats: [LLMDialogueBeat] = []
    var shadowCues: [LLMCharacterShadowCue] = []
    var objectStateCues: [LLMObjectStateCue] = []
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
        case objectPlacements
        case motions
        case objectMotions
        case expressions
        case dialogueBeats
        case shadowCues
        case objectStateCues
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
        objectPlacements: [LLMObjectPlacement] = [],
        motions: [LLMCharacterMotion] = [],
        objectMotions: [LLMObjectMotion] = [],
        expressions: [LLMCharacterExpressionCue] = [],
        dialogueBeats: [LLMDialogueBeat] = [],
        shadowCues: [LLMCharacterShadowCue] = [],
        objectStateCues: [LLMObjectStateCue] = [],
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
        self.objectPlacements = objectPlacements
        self.motions = motions
        self.objectMotions = objectMotions
        self.expressions = expressions
        self.dialogueBeats = dialogueBeats
        self.shadowCues = shadowCues
        self.objectStateCues = objectStateCues
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
        objectPlacements = try container.decodeIfPresent([LLMObjectPlacement].self, forKey: .objectPlacements) ?? []
        motions = try container.decodeIfPresent([LLMCharacterMotion].self, forKey: .motions) ?? []
        objectMotions = try container.decodeIfPresent([LLMObjectMotion].self, forKey: .objectMotions) ?? []
        expressions = try container.decodeIfPresent([LLMCharacterExpressionCue].self, forKey: .expressions) ?? []
        dialogueBeats = try container.decodeIfPresent([LLMDialogueBeat].self, forKey: .dialogueBeats) ?? []
        shadowCues = try container.decodeIfPresent([LLMCharacterShadowCue].self, forKey: .shadowCues) ?? []
        objectStateCues = try container.decodeIfPresent([LLMObjectStateCue].self, forKey: .objectStateCues) ?? []
        cameraMoves = try container.decodeIfPresent([LLMCameraMove].self, forKey: .cameraMoves) ?? []
        shotPresetApplications = try container.decodeIfPresent([LLMShotPresetApplication].self, forKey: .shotPresetApplications) ?? []
        notes = try container.decodeIfPresent([String].self, forKey: .notes) ?? []
    }
}

struct LLMShotPresetApplication: Codable, Sendable, Hashable {
    var presetName: String
    var frame: Int
    var shotID: String? = nil
    var shotName: String? = nil
    var frameOffset: Int? = nil
    var cameraShot: CameraShot? = nil
    var focusCharacterName: String? = nil
    var shotIntent: ShotIntent? = nil
    var beatLabel: String? = nil
    var beatNotes: String? = nil
    var characterOverrides: [LLMShotPresetCharacterOverride] = []

    enum CodingKeys: String, CodingKey {
        case presetName
        case frame
        case shotID
        case shotName
        case frameOffset
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
        shotID: String? = nil,
        shotName: String? = nil,
        frameOffset: Int? = nil,
        cameraShot: CameraShot? = nil,
        focusCharacterName: String? = nil,
        shotIntent: ShotIntent? = nil,
        beatLabel: String? = nil,
        beatNotes: String? = nil,
        characterOverrides: [LLMShotPresetCharacterOverride] = []
    ) {
        self.presetName = presetName
        self.frame = frame
        self.shotID = shotID
        self.shotName = shotName
        self.frameOffset = frameOffset
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
        shotID = try container.decodeIfPresent(String.self, forKey: .shotID)
        shotName = try container.decodeIfPresent(String.self, forKey: .shotName)
        frameOffset = try container.decodeIfPresent(Int.self, forKey: .frameOffset)
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
    var shotID: String? = nil
    var shotName: String? = nil
    var frameOffset: Int? = nil
    var audioPath: String
    var transcript: String?
    var expression: String?
    var action: String?

    init(
        characterName: String,
        startFrame: Int,
        shotID: String? = nil,
        shotName: String? = nil,
        frameOffset: Int? = nil,
        audioPath: String,
        transcript: String? = nil,
        expression: String? = nil,
        action: String? = nil
    ) {
        self.characterName = characterName
        self.startFrame = startFrame
        self.shotID = shotID
        self.shotName = shotName
        self.frameOffset = frameOffset
        self.audioPath = audioPath
        self.transcript = transcript
        self.expression = expression
        self.action = action
    }
}

struct LLMCharacterShadowCue: Codable, Sendable, Hashable {
    var characterName: String
    var frame: Int
    var shotID: String? = nil
    var shotName: String? = nil
    var frameOffset: Int? = nil
    var style: ShadowStyle
    var opacity: Double?

    init(
        characterName: String,
        frame: Int,
        shotID: String? = nil,
        shotName: String? = nil,
        frameOffset: Int? = nil,
        style: ShadowStyle,
        opacity: Double? = nil
    ) {
        self.characterName = characterName
        self.frame = frame
        self.shotID = shotID
        self.shotName = shotName
        self.frameOffset = frameOffset
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
    var shotID: String? = nil
    var shotName: String? = nil
    var frameOffset: Int? = nil
    var position: LLMAnimationPoint
    var facing: FacingDirection?
    var viewAngle: AngleView?
    var pose: CharacterPackagePose?
    var emotion: String?
    var zOrder: Int?

    init(
        characterName: String,
        frame: Int = 0,
        shotID: String? = nil,
        shotName: String? = nil,
        frameOffset: Int? = nil,
        position: LLMAnimationPoint,
        facing: FacingDirection? = nil,
        viewAngle: AngleView? = nil,
        pose: CharacterPackagePose? = nil,
        emotion: String? = nil,
        zOrder: Int? = nil
    ) {
        self.characterName = characterName
        self.frame = frame
        self.shotID = shotID
        self.shotName = shotName
        self.frameOffset = frameOffset
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
    var shotID: String? = nil
    var shotName: String? = nil
    var startFrameOffset: Int? = nil
    var endFrameOffset: Int? = nil
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
        shotID: String? = nil,
        shotName: String? = nil,
        startFrameOffset: Int? = nil,
        endFrameOffset: Int? = nil,
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
        self.shotID = shotID
        self.shotName = shotName
        self.startFrameOffset = startFrameOffset
        self.endFrameOffset = endFrameOffset
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

struct LLMObjectPlacement: Codable, Sendable, Hashable {
    var objectName: String
    var frame: Int
    var shotID: String? = nil
    var shotName: String? = nil
    var frameOffset: Int? = nil
    var position: LLMAnimationPoint
    var state: String?
    var zOrder: Int?
    var opacity: Double?
    var visible: Bool?
    var attachmentTarget: String?

    init(
        objectName: String,
        frame: Int = 0,
        shotID: String? = nil,
        shotName: String? = nil,
        frameOffset: Int? = nil,
        position: LLMAnimationPoint,
        state: String? = nil,
        zOrder: Int? = nil,
        opacity: Double? = nil,
        visible: Bool? = nil,
        attachmentTarget: String? = nil
    ) {
        self.objectName = objectName
        self.frame = frame
        self.shotID = shotID
        self.shotName = shotName
        self.frameOffset = frameOffset
        self.position = position
        self.state = state
        self.zOrder = zOrder
        self.opacity = opacity
        self.visible = visible
        self.attachmentTarget = attachmentTarget
    }
}

struct LLMObjectMotion: Codable, Sendable, Hashable {
    var objectName: String
    var startFrame: Int
    var endFrame: Int?
    var shotID: String? = nil
    var shotName: String? = nil
    var startFrameOffset: Int? = nil
    var endFrameOffset: Int? = nil
    var from: LLMAnimationPoint?
    var to: LLMAnimationPoint
    var easing: LLMAnimationEasing
    var paceUnitsPerSecond: Double?
    var state: String?
    var zOrder: Int?
    var attachmentTarget: String?

    init(
        objectName: String,
        startFrame: Int,
        endFrame: Int? = nil,
        shotID: String? = nil,
        shotName: String? = nil,
        startFrameOffset: Int? = nil,
        endFrameOffset: Int? = nil,
        from: LLMAnimationPoint? = nil,
        to: LLMAnimationPoint,
        easing: LLMAnimationEasing = .easeInOut,
        paceUnitsPerSecond: Double? = nil,
        state: String? = nil,
        zOrder: Int? = nil,
        attachmentTarget: String? = nil
    ) {
        self.objectName = objectName
        self.startFrame = startFrame
        self.endFrame = endFrame
        self.shotID = shotID
        self.shotName = shotName
        self.startFrameOffset = startFrameOffset
        self.endFrameOffset = endFrameOffset
        self.from = from
        self.to = to
        self.easing = easing
        self.paceUnitsPerSecond = paceUnitsPerSecond
        self.state = state
        self.zOrder = zOrder
        self.attachmentTarget = attachmentTarget
    }
}

struct LLMObjectStateCue: Codable, Sendable, Hashable {
    var objectName: String
    var frame: Int
    var shotID: String? = nil
    var shotName: String? = nil
    var frameOffset: Int? = nil
    var state: String?
    var opacity: Double?
    var visible: Bool?
    var attachmentTarget: String?

    init(
        objectName: String,
        frame: Int,
        shotID: String? = nil,
        shotName: String? = nil,
        frameOffset: Int? = nil,
        state: String? = nil,
        opacity: Double? = nil,
        visible: Bool? = nil,
        attachmentTarget: String? = nil
    ) {
        self.objectName = objectName
        self.frame = frame
        self.shotID = shotID
        self.shotName = shotName
        self.frameOffset = frameOffset
        self.state = state
        self.opacity = opacity
        self.visible = visible
        self.attachmentTarget = attachmentTarget
    }
}

struct LLMCharacterExpressionCue: Codable, Sendable, Hashable {
    var characterName: String
    var frame: Int
    var shotID: String? = nil
    var shotName: String? = nil
    var frameOffset: Int? = nil
    var expression: String

    init(
        characterName: String,
        frame: Int,
        shotID: String? = nil,
        shotName: String? = nil,
        frameOffset: Int? = nil,
        expression: String
    ) {
        self.characterName = characterName
        self.frame = frame
        self.shotID = shotID
        self.shotName = shotName
        self.frameOffset = frameOffset
        self.expression = expression
    }
}

struct LLMCameraMove: Codable, Sendable, Hashable {
    var movement: CameraMovement
    var startFrame: Int
    var endFrame: Int
    var shotID: String? = nil
    var shotName: String? = nil
    var startFrameOffset: Int? = nil
    var endFrameOffset: Int? = nil
    var fromShot: CameraShot?
    var toShot: CameraShot?
    var easing: LLMAnimationEasing

    init(
        movement: CameraMovement,
        startFrame: Int,
        endFrame: Int,
        shotID: String? = nil,
        shotName: String? = nil,
        startFrameOffset: Int? = nil,
        endFrameOffset: Int? = nil,
        fromShot: CameraShot? = nil,
        toShot: CameraShot? = nil,
        easing: LLMAnimationEasing = .easeInOut
    ) {
        self.movement = movement
        self.startFrame = startFrame
        self.endFrame = endFrame
        self.shotID = shotID
        self.shotName = shotName
        self.startFrameOffset = startFrameOffset
        self.endFrameOffset = endFrameOffset
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
        case emptyObjectName
        case emptyShotPresetName
        case unknownCharacter
        case unknownShotPreset
        case ambiguousShotPreset
        case unknownShotAnchor
        case ambiguousShotAnchor
        case invalidFrameRange
        case invalidPosition
        case invalidPace
        case invalidOpacity
        case invalidAttachmentTarget
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
