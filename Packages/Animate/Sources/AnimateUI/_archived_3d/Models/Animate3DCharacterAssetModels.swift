import Foundation
import UniformTypeIdentifiers

@available(macOS 26.0, *)
enum Animate3DCharacterAssetCategory: String, CaseIterable, Codable, Sendable, Hashable, Identifiable {
    case models
    case faceRigs = "face-rigs"
    case mouthProfiles = "mouth-profiles"
    case expressions
    case motions
    case materials

    var id: String { rawValue }

    var folderName: String { rawValue }

    var displayName: String {
        switch self {
        case .models: return "Models"
        case .faceRigs: return "Face Rigs"
        case .mouthProfiles: return "Mouth Profiles"
        case .expressions: return "Expressions"
        case .motions: return "Motions"
        case .materials: return "Materials"
        }
    }

    var iconName: String {
        switch self {
        case .models: return "cube"
        case .faceRigs: return "face.smiling"
        case .mouthProfiles: return "mouth"
        case .expressions: return "sparkles"
        case .motions: return "arrow.triangle.2.circlepath"
        case .materials: return "paintpalette"
        }
    }

    var importHint: String {
        switch self {
        case .models:
            return "GLB, USDZ, OBJ, or other 3D mesh files."
        case .faceRigs:
            return "Face control JSON, plist, or other rig metadata."
        case .mouthProfiles:
            return "Viseme and mouth profile data for lipsync."
        case .expressions:
            return "Expression libraries, pose maps, and facial cue metadata."
        case .motions:
            return "Motion clips, motion maps, or keyframe libraries."
        case .materials:
            return "Material profiles, shader presets, or lookdev metadata."
        }
    }

    var allowedContentTypes: [UTType] {
        switch self {
        case .models:
            return [UTType(filenameExtension: "glb"), UTType(filenameExtension: "usdz"), UTType(filenameExtension: "obj"), UTType(filenameExtension: "fbx")]
                .compactMap { $0 }
        case .faceRigs, .mouthProfiles, .expressions, .motions, .materials:
            return [.item]
        }
    }
}

@available(macOS 26.0, *)
struct Animate3DCharacterAssetFile: Identifiable, Codable, Sendable, Hashable {
    var category: Animate3DCharacterAssetCategory
    var relativePath: String
    var fileName: String
    var fileSize: Int64
    var modificationDate: Date?

    var id: String {
        "\(category.rawValue):\(relativePath)"
    }
}

@available(macOS 26.0, *)
struct Animate3DCharacterAssetInventory: Codable, Sendable, Hashable {
    var characterSlug: String
    var assetsByCategory: [Animate3DCharacterAssetCategory: [Animate3DCharacterAssetFile]]

    init(
        characterSlug: String,
        assetsByCategory: [Animate3DCharacterAssetCategory: [Animate3DCharacterAssetFile]] = [:]
    ) {
        self.characterSlug = characterSlug
        self.assetsByCategory = assetsByCategory
    }

    func files(for category: Animate3DCharacterAssetCategory) -> [Animate3DCharacterAssetFile] {
        assetsByCategory[category] ?? []
    }

    var totalFileCount: Int {
        assetsByCategory.values.reduce(0) { $0 + $1.count }
    }

    var categoryCount: Int {
        assetsByCategory.values.filter { !$0.isEmpty }.count
    }
}
