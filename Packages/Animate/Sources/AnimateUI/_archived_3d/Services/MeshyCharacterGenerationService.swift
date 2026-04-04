import Foundation

/// Generates a 3D character model from a character's reference images using the
/// Meshy image-to-3D API, then writes the result back to the character's `models3D` list.
///
/// Workflow:
///   1. Collect approved reference sheet images from the character's asset folder.
///   2. Build a `MeshyBridgeService.BridgeJob` with those images.
///   3. Execute the bridge job (encodes images, submits to Meshy, polls, downloads).
///   4. Call `addModel3D(_:to:)` on the store to persist the downloaded models.
///
/// If the Meshy API key is not set, throws `GenerationError.noAPIKey`.
/// If no reference images are found, throws `GenerationError.noReferenceImages`.
@available(macOS 26.0, *)
@MainActor
final class MeshyCharacterGenerationService {

    // MARK: - Types

    enum GenerationError: LocalizedError {
        case noAPIKey
        case noReferenceImages
        case noProjectURL
        case bridgeFailed(String)

        var errorDescription: String? {
            switch self {
            case .noAPIKey:
                return "Meshy API key is not configured. Add it in Settings."
            case .noReferenceImages:
                return "No approved reference images found for this character. Generate or approve reference sheets first."
            case .noProjectURL:
                return "No project is open."
            case .bridgeFailed(let msg):
                return "Meshy bridge failed: \(msg)"
            }
        }
    }

    // MARK: - Properties

    private weak var store: AnimateStore?

    init(store: AnimateStore) {
        self.store = store
    }

    // MARK: - Public API

    /// Generate a 3D model for the given character.
    ///
    /// - Parameters:
    ///   - character: The character to generate a model for.
    ///   - owpURL: The project root URL used to locate image files.
    ///   - onStatus: Optional progress callback with a human-readable status string.
    /// - Returns: The `BridgeResult` containing downloaded file paths and formats.
    func generateModel(
        for character: AnimationCharacter,
        owpURL: URL,
        onStatus: @escaping @MainActor (String) -> Void = { _ in }
    ) async throws -> MeshyBridgeService.BridgeResult {
        guard let store else { throw GenerationError.noProjectURL }
        guard !store.meshyAPIKey.isEmpty else { throw GenerationError.noAPIKey }

        let animateURL = owpURL.appendingPathComponent("Animate", isDirectory: true)

        // Collect reference image paths: prefer master reference sheet variants, fall back to
        // approved reference images, then to any listed reference images.
        let imagePaths: [String] = resolveReferenceImagePaths(
            for: character,
            owpURL: owpURL
        )

        guard !imagePaths.isEmpty else { throw GenerationError.noReferenceImages }

        onStatus("Found \(imagePaths.count) reference image(s). Submitting to Meshy…")

        var config = MeshyMultiImageRequest(imageURLs: [])
        config.targetPolycount = 100_000
        config.topology = "triangle"
        config.shouldRemesh = true
        config.shouldTexture = true
        config.enablePBR = true
        config.removeLighting = true
        config.targetFormats = ["glb", "usdz"]

        let job = MeshyBridgeService.BridgeJob(
            characterID: character.id,
            characterSlug: character.owpSlug,
            costumeName: "default",
            sourceImagePaths: imagePaths,
            meshyConfig: config
        )

        let result = try await MeshyBridgeService.execute(
            job: job,
            apiKey: store.meshyAPIKey,
            animateURL: animateURL
        ) { [weak self] status, progress in
            Task { @MainActor [weak self] in
                guard self != nil else { return }
                onStatus("Meshy: \(status.rawValue) \(progress)%")
            }
        }

        // Write models back to the character in the store
        for model in result.models {
            if let idx = store.characters.firstIndex(where: { $0.id == character.id }) {
                store.characters[idx].models3D.append(model)
            }
        }

        onStatus("Generated \(result.downloadedFormats.joined(separator: ", ")) — saved to character folder.")
        return result
    }

    // MARK: - Image Resolution

    private func resolveReferenceImagePaths(
        for character: AnimationCharacter,
        owpURL: URL
    ) -> [String] {
        var absolutePaths: [String] = []

        // 1. Approved master reference sheet variant image
        if let approvedVariantID = character.approvedMasterReferenceSheetVariantID,
           let variant = character.masterReferenceSheetVariants.first(where: { $0.id == approvedVariantID }),
           !variant.imagePath.isEmpty {
            let url = owpURL.appendingPathComponent(variant.imagePath)
            if FileManager.default.fileExists(atPath: url.path) {
                absolutePaths.append(url.path)
            }
        }

        // 2. All master reference sheet variant images (if no approved one)
        if absolutePaths.isEmpty {
            for variant in character.masterReferenceSheetVariants.prefix(4) {
                guard !variant.imagePath.isEmpty else { continue }
                let url = owpURL.appendingPathComponent(variant.imagePath)
                if FileManager.default.fileExists(atPath: url.path) {
                    absolutePaths.append(url.path)
                }
            }
        }

        // 3. Approved reference image from source paths
        if absolutePaths.isEmpty, let refPath = character.inspirationReferenceImagePath {
            let url = owpURL.appendingPathComponent(refPath)
            if FileManager.default.fileExists(atPath: url.path) {
                absolutePaths.append(url.path)
            }
        }

        // 4. First few reference image paths
        if absolutePaths.isEmpty {
            for refPath in character.referenceImagePaths.prefix(4) {
                let url = owpURL.appendingPathComponent(refPath)
                if FileManager.default.fileExists(atPath: url.path) {
                    absolutePaths.append(url.path)
                }
            }
        }

        return absolutePaths
    }
}
