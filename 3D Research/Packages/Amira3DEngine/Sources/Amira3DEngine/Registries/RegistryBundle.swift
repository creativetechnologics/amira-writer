import Foundation

public struct RegistryBundle: Hashable, Sendable {
    public var worldCatalog: WorldCatalog?
    public var assetRegistry: AssetRegistry?
    public var cameraPresets: CameraPresetCatalog?
    public var styleProfile: StyleProfile?
    public var characterRegistry: CharacterRegistry?
    public var faceRigCatalog: FaceRigCatalog?
    public var expressionProfileCatalog: ExpressionProfileCatalog?
    public var mouthProfileCatalog: MouthProfileCatalog?
    public var motionRegistry: MotionRegistry?
    public var lightRig: LightRig?
    public var atmospherePreset: AtmospherePreset?
    public var visemeMapping: VisemeMapping?

    public init(
        worldCatalog: WorldCatalog? = nil,
        assetRegistry: AssetRegistry? = nil,
        cameraPresets: CameraPresetCatalog? = nil,
        styleProfile: StyleProfile? = nil,
        characterRegistry: CharacterRegistry? = nil,
        faceRigCatalog: FaceRigCatalog? = nil,
        expressionProfileCatalog: ExpressionProfileCatalog? = nil,
        mouthProfileCatalog: MouthProfileCatalog? = nil,
        motionRegistry: MotionRegistry? = nil,
        lightRig: LightRig? = nil,
        atmospherePreset: AtmospherePreset? = nil,
        visemeMapping: VisemeMapping? = nil
    ) {
        self.worldCatalog = worldCatalog
        self.assetRegistry = assetRegistry
        self.cameraPresets = cameraPresets
        self.styleProfile = styleProfile
        self.characterRegistry = characterRegistry
        self.faceRigCatalog = faceRigCatalog
        self.expressionProfileCatalog = expressionProfileCatalog
        self.mouthProfileCatalog = mouthProfileCatalog
        self.motionRegistry = motionRegistry
        self.lightRig = lightRig
        self.atmospherePreset = atmospherePreset
        self.visemeMapping = visemeMapping
    }

    public static let empty = RegistryBundle()

    public func containsWorld(_ id: WorldID) -> Bool {
        worldCatalog?.worlds.contains(where: { $0.worldID == id }) == true
    }

    public func containsAsset(_ id: AssetID) -> Bool {
        assetRegistry?.assets.contains(where: { $0.assetID == id }) == true
    }

    public func containsCharacter(_ id: CharacterID) -> Bool {
        characterRegistry?.characters.contains(where: { $0.characterID == id }) == true
    }

    public func containsFaceRig(_ id: FaceRigID) -> Bool {
        faceRigCatalog?.faceRigs.contains(where: { $0.faceRigID == id }) == true
    }

    public func containsExpressionProfile(_ id: ExpressionProfileID) -> Bool {
        expressionProfileCatalog?.expressionProfiles.contains(where: { $0.expressionProfileID == id }) == true
    }

    public func containsMouthProfile(_ id: MouthProfileID) -> Bool {
        mouthProfileCatalog?.mouthProfiles.contains(where: { $0.mouthProfileID == id }) == true
    }
}
