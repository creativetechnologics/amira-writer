import Foundation

public struct GeneratedAssetIngest: Hashable, Codable, Sendable {
    public var assetDefinition: AssetDefinition
    public var manifest: AssetPackageManifest
    public var warnings: [ValidationMessage]

    public init(
        assetDefinition: AssetDefinition,
        manifest: AssetPackageManifest,
        warnings: [ValidationMessage]
    ) {
        self.assetDefinition = assetDefinition
        self.manifest = manifest
        self.warnings = warnings
    }
}

public struct GeneratedAssetIngestService: Sendable {
    public init() {}

    public func ingest(
        request: ImageTo3DGenerationRequest,
        result: ImageTo3DGenerationResult,
        category: String = "generated.asset"
    ) -> GeneratedAssetIngest {
        let geometry = result.geometry.map {
            GeneratedGeometryArtifact(
                format: $0.format,
                relativePath: $0.relativePath,
                vertexCount: $0.vertexCount,
                materialSlots: $0.materialSlots
            )
        }
        let textures = result.textures.map {
            GeneratedTextureArtifact(
                channel: $0.channel,
                format: $0.format,
                relativePath: $0.relativePath,
                resolution: $0.resolution
            )
        }

        let preferredGeometry = geometry.first?.format
        var warnings: [ValidationMessage] = result.geometry.isEmpty
            ? [.init(severity: .error, detail: "Generated asset is missing geometry output.")]
            : []

        if result.textures.isEmpty, request.textureMode != .geometryOnly {
            warnings.append(.init(severity: .warning, detail: "Generated asset has no texture outputs despite a texture-enabled request."))
        }

        let referenceImages = request.referenceImages.map {
            AssetReferenceImageRecord(role: $0.role, relativePath: $0.relativePath)
        }
        let createdAt = ISO8601DateFormatter().string(from: Date())

        let manifest = AssetPackageManifest(
            assetID: request.assetID,
            title: request.title,
            styleProfileID: request.styleProfileID,
            materialWorkflow: result.materialWorkflow,
            preferredGeometryFormat: preferredGeometry,
            geometry: geometry,
            textures: textures,
            provenance: AssetGenerationProvenance(
                provider: result.provider,
                createdAt: createdAt,
                requestMode: request.mode,
                textureMode: request.textureMode,
                preserveInputAppearance: request.preserveInputAppearance,
                referenceImages: referenceImages,
                warnings: result.warnings,
                metadata: result.metadata
            )
        )

        let assetDefinition = AssetDefinition(
            assetID: request.assetID,
            category: category,
            sourceType: sourceType(for: result.provider),
            preferredFormat: preferredGeometry?.rawValue ?? "unknown",
            alternateFormats: geometry.dropFirst().map(\.format.rawValue),
            styleStatus: styleStatus(for: request, result: result),
            originNotes: originNotes(request: request, result: result)
        )

        return GeneratedAssetIngest(
            assetDefinition: assetDefinition,
            manifest: manifest,
            warnings: warnings
        )
    }

    private func sourceType(for provider: ImageTo3DProviderKind) -> String {
        switch provider {
        case .stableFast3D:
            return "local_generated"
        case .hunyuan3D, .trellis2, .instantMesh:
            return "nvidia_generated"
        case .hyper3DRodin, .tripo, .meshy:
            return "cloud_generated"
        case .custom:
            return "custom_generated"
        }
    }

    private func styleStatus(
        for request: ImageTo3DGenerationRequest,
        result: ImageTo3DGenerationResult
    ) -> String {
        if request.styleProfileID != nil, result.textures.isEmpty == false {
            return "style_profile_assigned"
        }
        if result.textures.isEmpty == false {
            return "textured_unreviewed"
        }
        return "geometry_only_unreviewed"
    }

    private func originNotes(
        request: ImageTo3DGenerationRequest,
        result: ImageTo3DGenerationResult
    ) -> String {
        let imageCount = request.referenceImages.count
        let providerName = KnownImageTo3DProviders.profile(for: result.provider)?.displayName ?? result.provider.rawValue
        return "Generated via \(providerName) using \(imageCount) reference image(s); texture mode=\(request.textureMode.rawValue)."
    }
}
