import Foundation

@available(macOS 26.0, *)
struct Animate3DGenerationQueue: Hashable, Sendable {
    var items: [Animate3DGenerationQueueItem] = []

    var openCount: Int { items.count }
}

@available(macOS 26.0, *)
struct Animate3DGenerationQueueItem: Identifiable, Hashable, Sendable {
    enum Kind: String, Hashable, Sendable {
        case bodyModel = "body_model"
        case faceRig = "face_rig"
        case mouthProfile = "mouth_profile"
        case expressionLibrary = "expression_library"
        case motionSet = "motion_set"
        case materialProfile = "material_profile"
        case worldChunk = "world_chunk"
        case worldPreviewImage = "world_preview_image"
        case worldMesh = "world_mesh"
        case lightRig = "light_rig"
        case atmospherePreset = "atmosphere_preset"
        case styleProfile = "style_profile"
        case cameraPresetLibrary = "camera_preset_library"

        var title: String {
            switch self {
            case .bodyModel: "Body Model"
            case .faceRig: "Face Rig"
            case .mouthProfile: "Mouth Profile"
            case .expressionLibrary: "Expression Library"
            case .motionSet: "Motion Set"
            case .materialProfile: "Material Profile"
            case .worldChunk: "World Chunk"
            case .worldPreviewImage: "World Preview"
            case .worldMesh: "World Mesh"
            case .lightRig: "Light Rig"
            case .atmospherePreset: "Atmosphere"
            case .styleProfile: "Style Profile"
            case .cameraPresetLibrary: "Camera Presets"
            }
        }
    }

    var id = UUID()
    var kind: Kind
    var title: String
    var detail: String
    var destinationPath: String
    var providerHint: String
    var prompt: String
    var characterSlug: String?
    var characterName: String?
    var sceneName: String?
    var placeName: String?
    var manifestKind: Animate3DRegistryManifestKind?

    var summary: String {
        detail + " · " + providerHint
    }

    var targetRelativePath: String {
        destinationPath
    }

    var isBatchDraftable: Bool {
        switch kind {
        case .bodyModel, .faceRig, .mouthProfile, .expressionLibrary, .motionSet,
             .materialProfile, .worldChunk, .worldPreviewImage:
            return true
        case .worldMesh, .lightRig, .atmospherePreset, .styleProfile, .cameraPresetLibrary:
            return false
        }
    }

    var draftAspectRatio: String {
        switch kind {
        case .worldPreviewImage:
            return "21:9"
        case .motionSet, .materialProfile, .worldChunk:
            return "16:9"
        case .bodyModel, .faceRig, .mouthProfile, .expressionLibrary:
            return "4:3"
        case .worldMesh, .lightRig, .atmospherePreset, .styleProfile, .cameraPresetLibrary:
            return "16:9"
        }
    }

    var destinationDescription: String {
        switch kind {
        case .bodyModel:
            return "3D character model source sheet"
        case .faceRig:
            return "3D face-rig guide sheet"
        case .mouthProfile:
            return "viseme / mouth profile sheet"
        case .expressionLibrary:
            return "expression sheet"
        case .motionSet:
            return "key-pose motion sheet"
        case .materialProfile:
            return "material / lookdev board"
        case .worldChunk:
            return "3D world chunk concept board"
        case .worldPreviewImage:
            return "21:9 world preview plate"
        case .worldMesh:
            return "3D world mesh deliverable"
        case .lightRig:
            return "lighting registry entry"
        case .atmospherePreset:
            return "atmosphere registry entry"
        case .styleProfile:
            return "style profile registry entry"
        case .cameraPresetLibrary:
            return "camera preset registry entry"
        }
    }
}
