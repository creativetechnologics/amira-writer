import Foundation

public enum ImageTo3DProviderKind: String, Codable, Hashable, Sendable {
    case hyper3DRodin
    case tripo
    case meshy
    case stableFast3D
    case hunyuan3D
    case trellis2
    case instantMesh
    case custom
}

public enum TextureFidelityTier: String, Codable, Hashable, Sendable {
    case geometryOnly
    case textured
    case texturedWithReferencePass
    case pbrTextured
}

public enum LocalExecutionClass: String, Codable, Hashable, Sendable {
    case appleSiliconExperimental
    case nvidiaLinux
    case cpuFallback
    case cloudPreferred
}

public enum GenerationMode: String, Codable, Hashable, Sendable {
    case singleImage
    case multiView
    case textureExistingMesh
}

public enum TextureTransferMode: String, Codable, Hashable, Sendable {
    case geometryOnly
    case autoTexture
    case referenceTexture
    case pbrReferenceTexture
}

public enum AssetReferenceImageRole: String, Codable, Hashable, Sendable {
    case primary
    case textureReference
    case front
    case back
    case left
    case right
    case detail
}

public struct ImageTo3DProviderProfile: Hashable, Codable, Sendable {
    public var kind: ImageTo3DProviderKind
    public var displayName: String
    public var textureFidelity: TextureFidelityTier
    public var supportsMultiView: Bool
    public var supportsReferenceTexture: Bool
    public var localExecution: [LocalExecutionClass]
    public var notes: String

    public init(
        kind: ImageTo3DProviderKind,
        displayName: String,
        textureFidelity: TextureFidelityTier,
        supportsMultiView: Bool,
        supportsReferenceTexture: Bool,
        localExecution: [LocalExecutionClass],
        notes: String
    ) {
        self.kind = kind
        self.displayName = displayName
        self.textureFidelity = textureFidelity
        self.supportsMultiView = supportsMultiView
        self.supportsReferenceTexture = supportsReferenceTexture
        self.localExecution = localExecution
        self.notes = notes
    }
}

public struct AssetReferenceImage: Hashable, Codable, Sendable {
    public var role: AssetReferenceImageRole
    public var relativePath: String

    public init(role: AssetReferenceImageRole, relativePath: String) {
        self.role = role
        self.relativePath = relativePath
    }
}

public struct ImageTo3DGenerationRequest: Hashable, Codable, Sendable {
    public var assetID: AssetID
    public var title: String
    public var styleProfileID: StyleProfileID?
    public var mode: GenerationMode
    public var textureMode: TextureTransferMode
    public var preserveInputAppearance: Bool
    public var referenceImages: [AssetReferenceImage]
    public var providerHints: [String: JSONValue]

    public init(
        assetID: AssetID,
        title: String,
        styleProfileID: StyleProfileID? = nil,
        mode: GenerationMode,
        textureMode: TextureTransferMode,
        preserveInputAppearance: Bool = true,
        referenceImages: [AssetReferenceImage],
        providerHints: [String: JSONValue] = [:]
    ) {
        self.assetID = assetID
        self.title = title
        self.styleProfileID = styleProfileID
        self.mode = mode
        self.textureMode = textureMode
        self.preserveInputAppearance = preserveInputAppearance
        self.referenceImages = referenceImages
        self.providerHints = providerHints
    }
}

public struct GeneratedGeometryFile: Hashable, Codable, Sendable {
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

public struct GeneratedTextureFile: Hashable, Codable, Sendable {
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

public struct ImageTo3DGenerationResult: Hashable, Codable, Sendable {
    public var provider: ImageTo3DProviderKind
    public var materialWorkflow: MaterialWorkflowKind
    public var geometry: [GeneratedGeometryFile]
    public var textures: [GeneratedTextureFile]
    public var warnings: [String]
    public var metadata: [String: JSONValue]

    public init(
        provider: ImageTo3DProviderKind,
        materialWorkflow: MaterialWorkflowKind,
        geometry: [GeneratedGeometryFile],
        textures: [GeneratedTextureFile] = [],
        warnings: [String] = [],
        metadata: [String: JSONValue] = [:]
    ) {
        self.provider = provider
        self.materialWorkflow = materialWorkflow
        self.geometry = geometry
        self.textures = textures
        self.warnings = warnings
        self.metadata = metadata
    }
}

public protocol ImageTo3DProvider: Sendable {
    var profile: ImageTo3DProviderProfile { get }
    func validate(_ request: ImageTo3DGenerationRequest) -> [ValidationMessage]
}

public enum KnownImageTo3DProviders {
    public static let profiles: [ImageTo3DProviderProfile] = [
        .init(
            kind: .hyper3DRodin,
            displayName: "Hyper3D Rodin",
            textureFidelity: .texturedWithReferencePass,
            supportsMultiView: true,
            supportsReferenceTexture: true,
            localExecution: [.cloudPreferred],
            notes: "Best current cloud-first candidate when texture reference fidelity matters most."
        ),
        .init(
            kind: .tripo,
            displayName: "Tripo",
            textureFidelity: .texturedWithReferencePass,
            supportsMultiView: true,
            supportsReferenceTexture: true,
            localExecution: [.cloudPreferred],
            notes: "Strong commercial runner-up with multi-view and texture-focused workflows."
        ),
        .init(
            kind: .meshy,
            displayName: "Meshy",
            textureFidelity: .texturedWithReferencePass,
            supportsMultiView: true,
            supportsReferenceTexture: true,
            localExecution: [.cloudPreferred],
            notes: "Good convenience option, but should be driven with explicit texture settings for fidelity."
        ),
        .init(
            kind: .stableFast3D,
            displayName: "Stable Fast 3D",
            textureFidelity: .pbrTextured,
            supportsMultiView: true,
            supportsReferenceTexture: false,
            localExecution: [.appleSiliconExperimental, .cpuFallback],
            notes: "Best practical Apple Silicon local starting point for textured output."
        ),
        .init(
            kind: .hunyuan3D,
            displayName: "Hunyuan3D-2.1",
            textureFidelity: .pbrTextured,
            supportsMultiView: false,
            supportsReferenceTexture: true,
            localExecution: [.nvidiaLinux, .cloudPreferred],
            notes: "Strongest open texture-first route, but realistically a high-VRAM NVIDIA/cloud path."
        ),
        .init(
            kind: .trellis2,
            displayName: "TRELLIS.2",
            textureFidelity: .pbrTextured,
            supportsMultiView: false,
            supportsReferenceTexture: true,
            localExecution: [.nvidiaLinux, .cloudPreferred],
            notes: "High-quality PBR generator with a Linux/NVIDIA-heavy local footprint."
        ),
        .init(
            kind: .instantMesh,
            displayName: "InstantMesh",
            textureFidelity: .textured,
            supportsMultiView: true,
            supportsReferenceTexture: false,
            localExecution: [.nvidiaLinux],
            notes: "Useful open benchmark, but more geometry-first than texture-first."
        )
    ]

    public static func profile(for kind: ImageTo3DProviderKind) -> ImageTo3DProviderProfile? {
        profiles.first(where: { $0.kind == kind })
    }
}

public struct StaticImageTo3DProvider: ImageTo3DProvider {
    public let profile: ImageTo3DProviderProfile

    public init(profile: ImageTo3DProviderProfile) {
        self.profile = profile
    }

    public func validate(_ request: ImageTo3DGenerationRequest) -> [ValidationMessage] {
        var messages: [ValidationMessage] = []

        if request.referenceImages.isEmpty {
            messages.append(.init(severity: .error, detail: "At least one reference image is required."))
        }

        if request.mode == .multiView, profile.supportsMultiView == false {
            messages.append(.init(severity: .warning, detail: "\(profile.displayName) does not advertise multi-view input support."))
        }

        if request.textureMode == .referenceTexture || request.textureMode == .pbrReferenceTexture,
           profile.supportsReferenceTexture == false {
            messages.append(.init(severity: .warning, detail: "\(profile.displayName) does not advertise a dedicated reference-texture path."))
        }

        if request.textureMode == .geometryOnly, request.referenceImages.contains(where: { $0.role == .textureReference }) {
            messages.append(.init(severity: .info, detail: "Texture reference images were supplied, but the request is geometry-only."))
        }

        return messages
    }
}
