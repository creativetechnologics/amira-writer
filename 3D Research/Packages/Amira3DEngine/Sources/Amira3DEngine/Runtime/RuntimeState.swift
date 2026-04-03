import Foundation

public struct WorldGraphState: Hashable, Codable, Sendable {
    public var activeWorldID: WorldID?
    public var assetPlacements: [AssetID: Transform3D]

    public init(activeWorldID: WorldID? = nil, assetPlacements: [AssetID: Transform3D] = [:]) {
        self.activeWorldID = activeWorldID
        self.assetPlacements = assetPlacements
    }
}

public struct CameraGraphState: Hashable, Codable, Sendable {
    public var activePresetID: CameraPresetID?
    public var shotID: ShotID?
    public var move: String?

    public init(activePresetID: CameraPresetID? = nil, shotID: ShotID? = nil, move: String? = nil) {
        self.activePresetID = activePresetID
        self.shotID = shotID
        self.move = move
    }
}

public struct CharacterGraphState: Hashable, Codable, Sendable {
    public var characterID: CharacterID
    public var transform: Transform3D
    public var motionID: MotionID?
    public var face: FaceGraphState

    public init(
        characterID: CharacterID,
        transform: Transform3D = .init(),
        motionID: MotionID? = nil,
        face: FaceGraphState = .init()
    ) {
        self.characterID = characterID
        self.transform = transform
        self.motionID = motionID
        self.face = face
    }
}

public struct FaceGraphState: Hashable, Codable, Sendable {
    public var faceRigID: FaceRigID?
    public var expressionProfileID: ExpressionProfileID?
    public var expressionID: String?
    public var expressionCue: String?
    public var mouthProfileID: MouthProfileID?
    public var visemeToken: String?
    public var blinkState: String?
    public var gazeTarget: Vector3?
    public var intensity: Double

    public init(
        faceRigID: FaceRigID? = nil,
        expressionProfileID: ExpressionProfileID? = nil,
        expressionID: String? = nil,
        expressionCue: String? = nil,
        mouthProfileID: MouthProfileID? = nil,
        visemeToken: String? = nil,
        blinkState: String? = nil,
        gazeTarget: Vector3? = nil,
        intensity: Double = 1.0
    ) {
        self.faceRigID = faceRigID
        self.expressionProfileID = expressionProfileID
        self.expressionID = expressionID
        self.expressionCue = expressionCue
        self.mouthProfileID = mouthProfileID
        self.visemeToken = visemeToken
        self.blinkState = blinkState
        self.gazeTarget = gazeTarget
        self.intensity = intensity
    }
}

public struct StyleGraphState: Hashable, Codable, Sendable {
    public var activeStyleProfileID: StyleProfileID?
    public var activeLightRigID: LightRigID?
    public var activeAtmospherePresetID: AtmospherePresetID?

    public init(
        activeStyleProfileID: StyleProfileID? = nil,
        activeLightRigID: LightRigID? = nil,
        activeAtmospherePresetID: AtmospherePresetID? = nil
    ) {
        self.activeStyleProfileID = activeStyleProfileID
        self.activeLightRigID = activeLightRigID
        self.activeAtmospherePresetID = activeAtmospherePresetID
    }
}

public struct ReviewGraphState: Hashable, Codable, Sendable {
    public var pendingCommands: [SceneCommand]
    public var lastPreview: ApplyPreview?

    public init(pendingCommands: [SceneCommand] = [], lastPreview: ApplyPreview? = nil) {
        self.pendingCommands = pendingCommands
        self.lastPreview = lastPreview
    }
}

public struct EngineRuntimeState: Hashable, Codable, Sendable {
    public var sceneID: SceneID?
    public var world: WorldGraphState
    public var camera: CameraGraphState
    public var characters: [CharacterID: CharacterGraphState]
    public var style: StyleGraphState
    public var review: ReviewGraphState

    public init(
        sceneID: SceneID? = nil,
        world: WorldGraphState = .init(),
        camera: CameraGraphState = .init(),
        characters: [CharacterID: CharacterGraphState] = [:],
        style: StyleGraphState = .init(),
        review: ReviewGraphState = .init()
    ) {
        self.sceneID = sceneID
        self.world = world
        self.camera = camera
        self.characters = characters
        self.style = style
        self.review = review
    }
}
