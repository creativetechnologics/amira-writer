import Foundation

public struct WorldCatalog: Hashable, Codable, Sendable {
    public var schemaVersion: String
    public var project: String
    public var worlds: [WorldDefinition]
    public var timeOfDayPresets: [AtmospherePresetID]
    public var styleProfiles: [StyleProfileID]
}

public struct WorldDefinition: Hashable, Codable, Sendable {
    public var worldID: WorldID
    public var title: String
    public var description: String
    public var coreAssetIDs: [AssetID]
    public var defaultCameraPresetIDs: [CameraPresetID]
    public var defaultStyleProfileID: StyleProfileID
    public var defaultTimeOfDayPresetID: AtmospherePresetID

    enum CodingKeys: String, CodingKey {
        case worldID = "worldId"
        case title
        case description
        case coreAssetIDs = "coreAssetIds"
        case defaultCameraPresetIDs = "defaultCameraPresetIds"
        case defaultStyleProfileID = "defaultStyleProfileId"
        case defaultTimeOfDayPresetID = "defaultTimeOfDayPresetId"
    }
}

public struct AssetRegistry: Hashable, Codable, Sendable {
    public var schemaVersion: String
    public var project: String
    public var assets: [AssetDefinition]
}

public struct AssetDefinition: Hashable, Codable, Sendable {
    public var assetID: AssetID
    public var category: String
    public var sourceType: String
    public var preferredFormat: String
    public var alternateFormats: [String]
    public var styleStatus: String
    public var originNotes: String

    enum CodingKeys: String, CodingKey {
        case assetID = "assetId"
        case category
        case sourceType
        case preferredFormat
        case alternateFormats
        case styleStatus
        case originNotes
    }
}

public struct CameraPresetCatalog: Hashable, Codable, Sendable {
    public var schemaVersion: String
    public var presets: [CameraPreset]
}

public struct CameraPreset: Hashable, Codable, Sendable {
    public var presetID: CameraPresetID
    public var shotClass: String
    public var lensMM: Double
    public var heightMeters: Double
    public var distanceMeters: Double
    public var pitchDegrees: Double
    public var moveDefaults: [String]

    enum CodingKeys: String, CodingKey {
        case presetID = "presetId"
        case shotClass
        case lensMM = "lensMm"
        case heightMeters
        case distanceMeters
        case pitchDegrees
        case moveDefaults
    }
}

public struct StyleProfile: Hashable, Codable, Sendable {
    public var schemaVersion: String
    public var styleProfileID: StyleProfileID
    public var title: String
    public var toon: ToonSettings
    public var outline: OutlineSettings
    public var grade: GradeSettings
    public var atmosphereDefaults: AtmosphereDefaults

    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case styleProfileID = "styleProfileId"
        case title
        case toon
        case outline
        case grade
        case atmosphereDefaults
    }
}

public struct ToonSettings: Hashable, Codable, Sendable {
    public var bandCount: Int
    public var shadowThreshold: Double
    public var highlightThreshold: Double
    public var rimIntensity: Double
}

public struct OutlineSettings: Hashable, Codable, Sendable {
    public var mode: String
    public var width: Double
    public var color: String
    public var depthBias: Double
}

public struct GradeSettings: Hashable, Codable, Sendable {
    public var saturationBias: Double
    public var contrastBias: Double
    public var warmthBias: Double
}

public struct AtmosphereDefaults: Hashable, Codable, Sendable {
    public var fogDensity: Double
    public var hazeTint: String
}

public struct CharacterRegistry: Hashable, Codable, Sendable {
    public var schemaVersion: String
    public var characters: [CharacterDefinition]
}

public struct CharacterDefinition: Hashable, Codable, Sendable {
    public var characterID: CharacterID
    public var displayName: String
    public var bodyAssetID: AssetID
    public var faceRigID: FaceRigID
    public var expressionProfileID: ExpressionProfileID?
    public var mouthProfileID: MouthProfileID
    public var defaultStyleProfileID: StyleProfileID
    public var supportedMotionSets: [MotionID]

    enum CodingKeys: String, CodingKey {
        case characterID = "characterId"
        case displayName
        case bodyAssetID = "bodyAssetId"
        case faceRigID = "faceRigId"
        case expressionProfileID = "expressionProfileId"
        case mouthProfileID = "mouthProfileId"
        case defaultStyleProfileID = "defaultStyleProfileId"
        case supportedMotionSets
    }
}

public struct FaceRigCatalog: Hashable, Codable, Sendable {
    public var schemaVersion: String
    public var project: String
    public var faceRigs: [FaceRigDefinition]
}

public struct FaceRigDefinition: Hashable, Codable, Sendable {
    public var faceRigID: FaceRigID
    public var title: String
    public var description: String
    public var skeletonProfileID: SkeletonProfileID?
    public var faceNodeName: String?
    public var jawNodeName: String?
    public var mouthNodeName: String?
    public var leftEyeNodeName: String?
    public var rightEyeNodeName: String?
    public var browNodeNames: [String]
    public var defaultExpressionProfileID: ExpressionProfileID?
    public var defaultMouthProfileID: MouthProfileID?
    public var supportedExpressionProfileIDs: [ExpressionProfileID]
    public var supportedMouthProfileIDs: [MouthProfileID]
    public var notes: String

    enum CodingKeys: String, CodingKey {
        case faceRigID = "faceRigId"
        case title
        case description
        case skeletonProfileID = "skeletonProfileId"
        case faceNodeName
        case jawNodeName
        case mouthNodeName
        case leftEyeNodeName
        case rightEyeNodeName
        case browNodeNames
        case defaultExpressionProfileID = "defaultExpressionProfileId"
        case defaultMouthProfileID = "defaultMouthProfileId"
        case supportedExpressionProfileIDs = "supportedExpressionProfileIds"
        case supportedMouthProfileIDs = "supportedMouthProfileIds"
        case notes
    }
}

public struct ExpressionProfileCatalog: Hashable, Codable, Sendable {
    public var schemaVersion: String
    public var project: String
    public var expressionProfiles: [ExpressionProfile]
}

public struct ExpressionProfile: Hashable, Codable, Sendable {
    public var schemaVersion: String
    public var expressionProfileID: ExpressionProfileID
    public var faceRigID: FaceRigID
    public var title: String
    public var defaultExpressionID: String?
    public var expressions: [FaceExpressionDefinition]
    public var notes: String

    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case expressionProfileID = "expressionProfileId"
        case faceRigID = "faceRigId"
        case title
        case defaultExpressionID = "defaultExpressionId"
        case expressions
        case notes
    }
}

public struct FaceExpressionDefinition: Hashable, Codable, Sendable {
    public var expressionID: String
    public var label: String
    public var category: String
    public var blendshapeWeights: [String: Double]
    public var jawOpen: Double?
    public var eyeOpen: Double?
    public var browRaise: Double?
    public var mouthCue: String?
    public var visemeCue: String?
    public var notes: String

    enum CodingKeys: String, CodingKey {
        case expressionID = "expressionId"
        case label
        case category
        case blendshapeWeights
        case jawOpen
        case eyeOpen
        case browRaise
        case mouthCue
        case visemeCue
        case notes
    }
}

public struct MouthProfileCatalog: Hashable, Codable, Sendable {
    public var schemaVersion: String
    public var project: String
    public var mouthProfiles: [MouthProfile]
}

public struct MouthProfile: Hashable, Codable, Sendable {
    public var schemaVersion: String
    public var mouthProfileID: MouthProfileID
    public var faceRigID: FaceRigID?
    public var title: String
    public var driverType: String
    public var neutralVisemeToken: String
    public var fallbackVisemeToken: String
    public var visemes: [VisemeDefinition]
    public var notes: String

    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case mouthProfileID = "mouthProfileId"
        case faceRigID = "faceRigId"
        case title
        case driverType
        case neutralVisemeToken = "neutralVisemeToken"
        case fallbackVisemeToken = "fallbackVisemeToken"
        case visemes
        case notes
    }
}

public struct MotionRegistry: Hashable, Codable, Sendable {
    public var schemaVersion: String
    public var motions: [MotionDefinition]
}

public struct MotionDefinition: Hashable, Codable, Sendable {
    public var motionID: MotionID
    public var title: String
    public var sourceType: String
    public var skeletonProfileID: SkeletonProfileID
    public var loopable: Bool
    public var rootMotion: Bool
    public var tags: [String]

    enum CodingKeys: String, CodingKey {
        case motionID = "motionId"
        case title
        case sourceType
        case skeletonProfileID = "skeletonProfileId"
        case loopable
        case rootMotion
        case tags
    }
}

public struct LightRig: Hashable, Codable, Sendable {
    public var schemaVersion: String
    public var lightRigID: LightRigID
    public var title: String
    public var lights: [LightDefinition]
    public var defaults: LightRigDefaults

    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case lightRigID = "lightRigId"
        case title
        case lights
        case defaults
    }
}

public struct LightDefinition: Hashable, Codable, Sendable {
    public var type: String
    public var name: String
    public var color: String
    public var intensity: Double
    public var direction: [Double]?
    public var castsShadow: Bool?
}

public struct LightRigDefaults: Hashable, Codable, Sendable {
    public var shadowSoftness: Double
    public var exposureBias: Double
}

public struct AtmospherePreset: Hashable, Codable, Sendable {
    public var schemaVersion: String
    public var atmosphereProfileID: AtmospherePresetID
    public var title: String
    public var fog: FogSettings
    public var aerialPerspective: AerialPerspectiveSettings
    public var gradeHints: GradeHints

    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case atmosphereProfileID = "atmosphereProfileId"
        case title
        case fog
        case aerialPerspective
        case gradeHints
    }
}

public struct FogSettings: Hashable, Codable, Sendable {
    public var enabled: Bool
    public var density: Double
    public var nearStart: Double
    public var farFull: Double
    public var color: String
}

public struct AerialPerspectiveSettings: Hashable, Codable, Sendable {
    public var enabled: Bool
    public var strength: Double
}

public struct GradeHints: Hashable, Codable, Sendable {
    public var contrastBias: Double
    public var saturationBias: Double
}

public struct VisemeMapping: Hashable, Codable, Sendable {
    public var schemaVersion: String
    public var mouthProfileID: MouthProfileID
    public var driverType: String
    public var visemes: [VisemeDefinition]

    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case mouthProfileID = "mouthProfileId"
        case driverType
        case visemes
    }
}

public struct VisemeDefinition: Hashable, Codable, Sendable {
    public var token: String
    public var blendshape: String
    public var jawOpen: Double
}
