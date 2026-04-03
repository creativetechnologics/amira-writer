import Foundation

public enum MeshFileFormat: String, Codable, Hashable, Sendable {
    case usd
    case usda
    case usdc
    case usdz
    case glb
    case gltf
    case obj
    case fbx
}

public enum TextureChannelKind: String, Codable, Hashable, Sendable {
    case albedo
    case normal
    case roughness
    case metallic
    case opacity
    case emissive
    case ambientOcclusion
}

public enum TextureFileFormat: String, Codable, Hashable, Sendable {
    case png
    case jpg
    case jpeg
    case webp
    case exr
}

public enum MaterialWorkflowKind: String, Codable, Hashable, Sendable {
    case unlit
    case pbrMetallicRoughness
    case toonPBRHybrid
}

public struct AssetReferenceImageRecord: Hashable, Codable, Sendable {
    public var role: AssetReferenceImageRole
    public var relativePath: String

    public init(role: AssetReferenceImageRole, relativePath: String) {
        self.role = role
        self.relativePath = relativePath
    }
}

public struct GeneratedGeometryArtifact: Hashable, Codable, Sendable {
    public var format: MeshFileFormat
    public var relativePath: String
    public var vertexCount: Int?
    public var materialSlots: Int?

    public init(
        format: MeshFileFormat,
        relativePath: String,
        vertexCount: Int? = nil,
        materialSlots: Int? = nil
    ) {
        self.format = format
        self.relativePath = relativePath
        self.vertexCount = vertexCount
        self.materialSlots = materialSlots
    }
}

public struct GeneratedTextureArtifact: Hashable, Codable, Sendable {
    public var channel: TextureChannelKind
    public var format: TextureFileFormat
    public var relativePath: String
    public var resolution: Int?

    public init(
        channel: TextureChannelKind,
        format: TextureFileFormat,
        relativePath: String,
        resolution: Int? = nil
    ) {
        self.channel = channel
        self.format = format
        self.relativePath = relativePath
        self.resolution = resolution
    }
}

public struct AssetGenerationProvenance: Hashable, Codable, Sendable {
    public var provider: ImageTo3DProviderKind
    public var createdAt: String
    public var requestMode: GenerationMode
    public var textureMode: TextureTransferMode
    public var preserveInputAppearance: Bool
    public var referenceImages: [AssetReferenceImageRecord]
    public var warnings: [String]
    public var metadata: [String: JSONValue]

    public init(
        provider: ImageTo3DProviderKind,
        createdAt: String,
        requestMode: GenerationMode,
        textureMode: TextureTransferMode,
        preserveInputAppearance: Bool,
        referenceImages: [AssetReferenceImageRecord],
        warnings: [String] = [],
        metadata: [String: JSONValue] = [:]
    ) {
        self.provider = provider
        self.createdAt = createdAt
        self.requestMode = requestMode
        self.textureMode = textureMode
        self.preserveInputAppearance = preserveInputAppearance
        self.referenceImages = referenceImages
        self.warnings = warnings
        self.metadata = metadata
    }
}

public struct AssetPackageManifest: Hashable, Codable, Sendable {
    public var schemaVersion: String
    public var assetID: AssetID
    public var title: String
    public var styleProfileID: StyleProfileID?
    public var materialWorkflow: MaterialWorkflowKind
    public var preferredGeometryFormat: MeshFileFormat?
    public var geometry: [GeneratedGeometryArtifact]
    public var textures: [GeneratedTextureArtifact]
    public var provenance: AssetGenerationProvenance

    public init(
        schemaVersion: String = "0.1",
        assetID: AssetID,
        title: String,
        styleProfileID: StyleProfileID? = nil,
        materialWorkflow: MaterialWorkflowKind,
        preferredGeometryFormat: MeshFileFormat? = nil,
        geometry: [GeneratedGeometryArtifact],
        textures: [GeneratedTextureArtifact],
        provenance: AssetGenerationProvenance
    ) {
        self.schemaVersion = schemaVersion
        self.assetID = assetID
        self.title = title
        self.styleProfileID = styleProfileID
        self.materialWorkflow = materialWorkflow
        self.preferredGeometryFormat = preferredGeometryFormat
        self.geometry = geometry
        self.textures = textures
        self.provenance = provenance
    }
}
