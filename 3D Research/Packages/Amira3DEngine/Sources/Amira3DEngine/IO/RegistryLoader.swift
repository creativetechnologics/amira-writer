import Foundation

public struct RegistryLoader: Sendable {
    public var decoder: JSONDecoder

    public init(decoder: JSONDecoder = JSONDecoder()) {
        self.decoder = decoder
    }

    public func loadBundle(from rootURL: URL) throws -> RegistryBundle {
        RegistryBundle(
            worldCatalog: try decodeIfPresent(WorldCatalog.self, from: rootURL.appending(path: "world-catalog/world-catalog.example.json")),
            assetRegistry: try decodeIfPresent(AssetRegistry.self, from: rootURL.appending(path: "asset-registry/asset-registry.example.json")),
            cameraPresets: try decodeIfPresent(CameraPresetCatalog.self, from: rootURL.appending(path: "camera-presets/camera-presets.example.json")),
            styleProfile: try decodeIfPresent(StyleProfile.self, from: rootURL.appending(path: "style-profiles/style-profile.example.json")),
            characterRegistry: try decodeIfPresent(CharacterRegistry.self, from: rootURL.appending(path: "character-registry/character-registry.example.json")),
            faceRigCatalog: try decodeIfPresent(FaceRigCatalog.self, from: rootURL.appending(path: "face-rigs/face-rigs.example.json")),
            expressionProfileCatalog: try decodeIfPresent(ExpressionProfileCatalog.self, from: rootURL.appending(path: "expression-profiles/expression-profiles.example.json")),
            mouthProfileCatalog: try decodeIfPresent(MouthProfileCatalog.self, from: rootURL.appending(path: "mouth-profiles/mouth-profiles.example.json")),
            motionRegistry: try decodeIfPresent(MotionRegistry.self, from: rootURL.appending(path: "motion-registry/motion-registry.example.json")),
            lightRig: try decodeIfPresent(LightRig.self, from: rootURL.appending(path: "light-rigs/light-rig.example.json")),
            atmospherePreset: try decodeIfPresent(AtmospherePreset.self, from: rootURL.appending(path: "atmosphere-presets/atmosphere-preset.example.json")),
            visemeMapping: try decodeIfPresent(VisemeMapping.self, from: rootURL.appending(path: "viseme-mapping/viseme-mapping.example.json"))
        )
    }

    private func decodeIfPresent<T: Decodable>(_ type: T.Type, from url: URL) throws -> T? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try decoder.decode(T.self, from: data)
    }
}
