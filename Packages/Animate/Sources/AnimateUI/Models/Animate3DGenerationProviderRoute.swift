import Foundation

/// Defines how a 3D generation queue item should be fulfilled
@available(macOS 26.0, *)
enum Animate3DGenerationProviderRoute: String, Codable, Sendable, CaseIterable {
    /// Submit reference images to Meshy.ai for 3D model generation
    case meshy = "meshy"
    /// Generate via Gemini only (image/JSON output, no 3D conversion)
    case geminiOnly = "gemini-only"
    /// User imports externally created asset (e.g., world meshes from Blender)
    case externalImport = "external-import"
    /// In-app configuration (style profiles, camera presets, etc.)
    case inAppConfig = "in-app-config"
    /// Manual authoring required
    case manual = "manual"

    var displayName: String {
        switch self {
        case .meshy: "Meshy.ai (3D Model)"
        case .geminiOnly: "Gemini (Reference Only)"
        case .externalImport: "External Import"
        case .inAppConfig: "In-App Configuration"
        case .manual: "Manual"
        }
    }

    var systemImage: String {
        switch self {
        case .meshy: "cube.fill"
        case .geminiOnly: "sparkles"
        case .externalImport: "square.and.arrow.down"
        case .inAppConfig: "gearshape"
        case .manual: "hand.raised"
        }
    }

    /// Whether this route can be automatically executed (vs requiring human action)
    var isAutomatable: Bool {
        switch self {
        case .meshy, .geminiOnly: true
        case .externalImport, .inAppConfig, .manual: false
        }
    }

    /// Default route for each queue item kind
    static func defaultRoute(for kind: String) -> Animate3DGenerationProviderRoute {
        switch kind {
        case "bodyModel":
            return .meshy
        case "faceRig", "mouthProfile", "expressionLibrary", "motionSet", "materialProfile":
            return .geminiOnly
        case "worldChunk", "worldMesh":
            return .externalImport
        case "worldPreviewImage":
            return .geminiOnly
        case "styleProfile", "cameraPresetLibrary", "lightRig", "atmospherePreset":
            return .inAppConfig
        default:
            return .manual
        }
    }

    /// Whether the route requires a Meshy API key
    var requiresMeshyKey: Bool {
        self == .meshy
    }

    /// Estimated credit cost for Meshy routes
    var estimatedMeshyCredits: Int? {
        switch self {
        case .meshy: 30  // Multi-image with texture on meshy-6/latest
        default: nil
        }
    }
}
