import Foundation

@available(macOS 26.0, *)
struct Animate3DRegistryIndex: Codable, Sendable, Hashable {
    var assetRegistryPath: String = "Animate/3d/asset-registry/asset-registry.json"
    var characterRegistryPath: String = "Animate/3d/character-registry/character-registry.json"
    var motionRegistryPath: String = "Animate/3d/motion-registry/motion-registry.json"
    var worldCatalogPath: String = "Animate/3d/world-catalog/world-catalog.json"
    var styleProfilesPath: String = "Animate/3d/style-profiles/style-profiles.json"
    var cameraPresetsPath: String = "Animate/3d/camera-presets/camera-presets.json"
    var lightRigsPath: String = "Animate/3d/light-rigs/light-rigs.json"
    var atmospherePresetsPath: String = "Animate/3d/atmosphere-presets/atmosphere-presets.json"
}

@available(macOS 26.0, *)
struct Animate3DAssetRegistry: Codable, Sendable, Hashable {
    var bundles: [Animate3DCharacterBundleDescriptor] = []
}

@available(macOS 26.0, *)
struct Animate3DCharacterRegistry: Codable, Sendable, Hashable {
    var bundles: [Animate3DCharacterBundleDescriptor] = []
}

@available(macOS 26.0, *)
struct Animate3DMotionRegistry: Codable, Sendable, Hashable {
    var motions: [Animate3DMotionSetDescriptor] = []
}

@available(macOS 26.0, *)
struct Animate3DWorldCatalog: Codable, Sendable, Hashable {
    var chunks: [Animate3DWorldChunkDescriptor] = []
}

@available(macOS 26.0, *)
struct Animate3DStyleProfileManifest: Codable, Sendable, Hashable {
    var profiles: [Animate3DStyleProfileDescriptor] = []
}

@available(macOS 26.0, *)
struct Animate3DCameraPresetManifest: Codable, Sendable, Hashable {
    var presets: [Animate3DCameraPresetDescriptor] = []
}

@available(macOS 26.0, *)
struct Animate3DLightRigManifest: Codable, Sendable, Hashable {
    var rigs: [Animate3DLightRigDescriptor] = []
}

@available(macOS 26.0, *)
struct Animate3DAtmospherePresetManifest: Codable, Sendable, Hashable {
    var presets: [Animate3DAtmospherePresetDescriptor] = []
}

@available(macOS 26.0, *)
struct Animate3DCharacterBundleDescriptor: Codable, Sendable, Hashable, Identifiable {
    var id: UUID = UUID()
    var characterSlug: String
    var costumeName: String
    var bodyModelPath: String
    var faceRigPath: String?
    var mouthProfilePath: String?
    var expressionLibraryPath: String?
    var motionSetPaths: [String] = []
    var materialProfilePath: String?
}

@available(macOS 26.0, *)
struct Animate3DMotionSetDescriptor: Codable, Sendable, Hashable, Identifiable {
    var id: UUID = UUID()
    var motionID: String
    var title: String
    var relativePath: String
    var tags: [String] = []
    var notes: String = ""
}

@available(macOS 26.0, *)
struct Animate3DWorldChunkDescriptor: Codable, Sendable, Hashable, Identifiable {
    var id: UUID = UUID()
    var worldID: String
    var zoneID: String
    var title: String = ""
    var placeNames: [String] = []
    var meshPath: String?
    var depthMapPath: String?
    var previewImagePath: String?
    var styleProfileID: String?
    var atmospherePresetID: String?
    var lightRigID: String?
}

@available(macOS 26.0, *)
struct Animate3DStyleProfileDescriptor: Codable, Sendable, Hashable, Identifiable {
    var id: UUID = UUID()
    var profileID: String
    var title: String
    var notes: String = ""
    var celBands: Int = 3
    var outlineWidth: Double = 1.0
}

@available(macOS 26.0, *)
struct Animate3DCameraPresetDescriptor: Codable, Sendable, Hashable, Identifiable {
    var id: UUID = UUID()
    var presetID: String
    var title: String
    var shotName: String
    var focalLength: Double
    var notes: String = ""
}

@available(macOS 26.0, *)
struct Animate3DLightRigDescriptor: Codable, Sendable, Hashable, Identifiable {
    var id: UUID = UUID()
    var rigID: String
    var title: String
    var keyIntensity: Double
    var fillIntensity: Double
    var rimIntensity: Double
    var notes: String = ""
}

@available(macOS 26.0, *)
struct Animate3DAtmospherePresetDescriptor: Codable, Sendable, Hashable, Identifiable {
    var id: UUID = UUID()
    var presetID: String
    var title: String
    var fogDensity: Double
    var haze: Double
    var colorHex: String
    var notes: String = ""
}
