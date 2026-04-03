import Testing
@testable import Amira3DEngine

struct GeneratedAssetIngestServiceTests {
    @Test
    func ingestBuildsManifestAndRegistryEntry() {
        let request = ImageTo3DGenerationRequest(
            assetID: "bridge_main",
            title: "Main Bridge",
            styleProfileID: "amira_toon_v001",
            mode: .multiView,
            textureMode: .referenceTexture,
            preserveInputAppearance: true,
            referenceImages: [
                .init(role: .front, relativePath: "refs/bridge-front.png"),
                .init(role: .back, relativePath: "refs/bridge-back.png"),
                .init(role: .textureReference, relativePath: "refs/bridge-texture.png")
            ]
        )

        let result = ImageTo3DGenerationResult(
            provider: .meshy,
            materialWorkflow: .pbrMetallicRoughness,
            geometry: [
                .init(format: .glb, relativePath: "generated/bridge_main.glb", vertexCount: 120_000, materialSlots: 1)
            ],
            textures: [
                .init(channel: .albedo, format: .png, relativePath: "generated/bridge_main_albedo.png", resolution: 2048),
                .init(channel: .normal, format: .png, relativePath: "generated/bridge_main_normal.png", resolution: 2048)
            ]
        )

        let ingest = GeneratedAssetIngestService().ingest(request: request, result: result, category: "environment.structure")

        #expect(ingest.assetDefinition.assetID == "bridge_main")
        #expect(ingest.assetDefinition.preferredFormat == "glb")
        #expect(ingest.assetDefinition.styleStatus == "style_profile_assigned")
        #expect(ingest.manifest.materialWorkflow == .pbrMetallicRoughness)
        #expect(ingest.manifest.geometry.count == 1)
        #expect(ingest.manifest.textures.count == 2)
        #expect(ingest.manifest.provenance.provider == .meshy)
        #expect(ingest.warnings.isEmpty)
    }

    @Test
    func providerValidationFlagsUnsupportedReferenceTexture() {
        let provider = StaticImageTo3DProvider(
            profile: .init(
                kind: .stableFast3D,
                displayName: "Stable Fast 3D",
                textureFidelity: .pbrTextured,
                supportsMultiView: true,
                supportsReferenceTexture: false,
                localExecution: [.appleSiliconExperimental, .cpuFallback],
                notes: "Local-first."
            )
        )

        let request = ImageTo3DGenerationRequest(
            assetID: "prop.lantern",
            title: "Lantern",
            mode: .singleImage,
            textureMode: .referenceTexture,
            referenceImages: [
                .init(role: .primary, relativePath: "refs/lantern-front.png"),
                .init(role: .textureReference, relativePath: "refs/lantern-texture.png")
            ]
        )

        let warnings = provider.validate(request)

        #expect(warnings.contains(where: { $0.detail.contains("reference-texture") }))
    }
}
