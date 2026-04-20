import AppKit
import Foundation
import ProjectKit

@available(macOS 26.0, *)
@MainActor
struct ImagineGenerationService {

    // MARK: - Draw Things Request/Response

    private struct DrawThingsRequest: Encodable {
        var prompt: String
        var negative_prompt: String
        var width: Int
        var height: Int
        var steps: Int
        var guidance_scale: Double
        var shift: Double
        var resolution_dependent_shift: Bool
        var sampler: String
        var seed: Int?
        var batch_size: Int = 1
        var n_iter: Int = 1
        var loras: [DrawThingsLoRAReference]
    }

    private struct DrawThingsImg2ImgRequest: Encodable {
        var prompt: String
        var negative_prompt: String
        var init_images: [String]
        var strength: Double
        var width: Int
        var height: Int
        var steps: Int
        var guidance_scale: Double
        var shift: Double
        var resolution_dependent_shift: Bool
        var sampler: String
        var seed: Int?
        var batch_size: Int = 1
        var n_iter: Int = 1
        var loras: [DrawThingsLoRAReference]
    }

    private struct DrawThingsResponse: Decodable {
        var images: [String]
    }

    // MARK: - Draw Things Generation (single call, returns all images)

    /// Generate images via Draw Things. Returns the saved file URLs.
    /// `batchSize` controls how many images DT generates per call (1-4).
    func generateWithDrawThings(
        prompt: String,
        model: ImagineDrawThingsModel,
        config: DrawThingsPlaceConfig,
        owpURL: URL,
        sceneSlug: String,
        shotIndex: Int,
        moment: ImagineShotMoment,
        characters: [AnimationCharacter] = [],
        batchSize: Int = 1,
        sourceImageURL: URL? = nil,
        denoisingStrength: Double = 0.35,
        useCharacterLoRAs: Bool = true
    ) async throws -> [URL] {
        guard var components = URLComponents(string: config.apiHost) else {
            throw GenerationError.invalidURL
        }
        if components.scheme == nil { components.scheme = "http" }
        components.port = config.apiPort
        components.path = sourceImageURL == nil ? "/sdapi/v1/txt2img" : "/sdapi/v1/img2img"
        guard let url = components.url else {
            throw GenerationError.invalidURL
        }

        let clampedBatch = max(1, min(batchSize, 4))
        let promptWithHouseStyle = assembledPrompt(
            basePrompt: prompt,
            config: config
        )
        let preparedPrompt = try await prepareDrawThingsPrompt(
            promptWithHouseStyle: promptWithHouseStyle,
            characters: characters,
            owpURL: owpURL,
            config: config,
            useCharacterLoRAs: useCharacterLoRAs
        )
        let requestLoRAs = preparedPrompt.loras

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 600
        if let sourceImageURL {
            let sourceData = try Data(contentsOf: sourceImageURL)
            let sourcePixelSize = try sourceImagePixelSize(
                from: sourceData,
                sourceImageURL: sourceImageURL
            )
            let body = DrawThingsImg2ImgRequest(
                prompt: preparedPrompt.prompt,
                negative_prompt: config.negativePrompt,
                init_images: [sourceData.base64EncodedString()],
                strength: denoisingStrength,
                width: sourcePixelSize.width,
                height: sourcePixelSize.height,
                steps: model.defaultSteps,
                guidance_scale: model.defaultCFGScale,
                shift: model.defaultShift,
                resolution_dependent_shift: model.resolutionDependentShift,
                sampler: model.defaultSampler,
                seed: config.seed,
                batch_size: clampedBatch,
                loras: requestLoRAs
            )
            request.httpBody = try JSONEncoder().encode(body)
        } else {
            let body = DrawThingsRequest(
                prompt: preparedPrompt.prompt,
                negative_prompt: config.negativePrompt,
                width: 1920,
                height: 1088,
                steps: model.defaultSteps,
                guidance_scale: model.defaultCFGScale,
                shift: model.defaultShift,
                resolution_dependent_shift: model.resolutionDependentShift,
                sampler: model.defaultSampler,
                seed: config.seed,
                batch_size: clampedBatch,
                loras: requestLoRAs
            )
            request.httpBody = try JSONEncoder().encode(body)
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            let responseText = String(data: data, encoding: .utf8) ?? ""
            throw GenerationError.httpError(statusCode, responseText)
        }

        let decoded = try JSONDecoder().decode(DrawThingsResponse.self, from: data)
        guard !decoded.images.isEmpty else {
            throw GenerationError.noImage
        }

        // Save ALL images from the batch
        let dir = ImagineProjectStorage.momentDirectory(owpURL: owpURL, sceneSlug: sceneSlug, shotIndex: shotIndex, moment: moment)
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        var savedURLs: [URL] = []
        let baseTimestamp = Int(Date().timeIntervalSince1970 * 1000)
        for (i, base64String) in decoded.images.enumerated() {
            guard let imageData = Data(base64Encoded: base64String) else { continue }
            let outputURL = dir.appendingPathComponent("dt_\(baseTimestamp)_\(i).png")
            try imageData.write(to: outputURL, options: .atomic)
            savedURLs.append(outputURL)

            // Save prompt alongside image for later review
            let promptURL = dir.appendingPathComponent("dt_\(baseTimestamp)_\(i).prompt.txt")
            try? preparedPrompt.prompt.write(to: promptURL, atomically: true, encoding: .utf8)
        }

        return savedURLs
    }

    private func prepareDrawThingsPrompt(
        promptWithHouseStyle: String,
        characters: [AnimationCharacter],
        owpURL: URL,
        config: DrawThingsPlaceConfig,
        useCharacterLoRAs: Bool
    ) async throws -> DrawThingsPreparedPrompt {
        guard useCharacterLoRAs else {
            return DrawThingsPreparedPrompt(
                prompt: promptWithHouseStyle,
                loras: []
            )
        }

        let animateURL = ProjectPaths(root: owpURL).animate
        return try await DrawThingsLoRAService().preparePrompt(
            prompt: promptWithHouseStyle,
            characters: characters,
            animateURL: animateURL,
            config: config
        )
    }

    private func sourceImagePixelSize(
        from imageData: Data,
        sourceImageURL: URL
    ) throws -> (width: Int, height: Int) {
        guard let bitmap = NSBitmapImageRep(data: imageData),
              bitmap.pixelsWide > 0,
              bitmap.pixelsHigh > 0 else {
            throw GenerationError.httpError(
                0,
                "Could not read source image dimensions for \(sourceImageURL.lastPathComponent)."
            )
        }
        return (bitmap.pixelsWide, bitmap.pixelsHigh)
    }

    // MARK: - Gemini Generation

    func generateWithGemini(
        prompt: String,
        referenceImages: [GeminiImageService.ReferenceImage],
        model: GeminiModel,
        apiKey: String,
        owpURL: URL,
        sceneSlug: String,
        shotIndex: Int,
        moment: ImagineShotMoment
    ) async throws {
        let service = GeminiImageService()
        let request = GeminiImageService.GenerationRequest(
            prompt: prompt,
            referenceImages: referenceImages,
            model: model,
            aspectRatio: "16:9",
            imageSize: "2K"
        )

        let result = try await service.generate(request: request, apiKey: apiKey)

        _ = try ImagineProjectStorage.saveGeneratedImage(
            result.imageData,
            owpURL: owpURL,
            sceneSlug: sceneSlug,
            shotIndex: shotIndex,
            moment: moment,
            filePrefix: "gemini"
        )
    }

    // MARK: - Bulk Generation (DrawThings only)

    /// Run bulk generation across scenes/shots/moments.
    ///
    /// For each scene → shot → moment:
    /// 1. Auto-generate prompt via GPT 5.4 (if enabled)
    /// 2. Send to DrawThings `repeatsPerPrompt` times, each with `batchSize` images
    /// 3. Total images per moment = batchSize × repeatsPerPrompt
    func runBulk(
        config: ImagineBulkRunConfig,
        scenes: [AnimationScene],
        store: AnimateStore,
        onProgress: @MainActor (ImagineBulkRunProgress) -> Void
    ) async throws {
        guard let owpURL = store.fileOWPURL else { return }

        let targetScenes: [AnimationScene]
        if let filter = config.sceneFilter {
            targetScenes = scenes.filter { filter.contains($0.id) }
        } else {
            targetScenes = scenes
        }

        let moments = ImagineShotMoment.allCases.filter { moment in
            switch moment {
            case .beginning: config.includeBeginning
            case .middle: config.includeMiddle
            case .end: config.includeEnd
            }
        }

        // Load or create a bulk run manifest for resume support
        let manifest = BulkRunManifest.loadOrCreate(owpURL: owpURL, config: config)
        let totalCalls = targetScenes.reduce(0) { $0 + $1.shots.count } * moments.count * config.repeatsPerPrompt
        let totalImages = totalCalls * config.batchSize

        var progress = ImagineBulkRunProgress()
        progress.isRunning = true
        progress.totalImages = totalImages
        progress.completedImages = manifest.completedKeys.count * config.batchSize
        await onProgress(progress)

        let promptService = ImagineScenePromptService(store: store)

        for scene in targetScenes {
            if store.imagineBulkRunProgress.isCancelled { break }
            let sceneSlug = scene.name.lowercased()
                .replacingOccurrences(of: " ", with: "-")
                .replacingOccurrences(of: "/", with: "-")

            try? ImagineProjectStorage.ensureDirectories(owpURL: owpURL, sceneSlug: sceneSlug, shotCount: scene.shots.count)

            for (shotIndex, _) in scene.shots.enumerated() {
                // Check cancellation
                if store.imagineBulkRunProgress.isCancelled { break }

                for moment in moments {
                    if store.imagineBulkRunProgress.isCancelled { break }

                    progress.currentSceneName = scene.name
                    progress.currentShotIndex = shotIndex
                    progress.currentMoment = moment
                    await onProgress(progress)

                    // Auto-generate prompt (with retry)
                    var prompt = ""
                    if config.autoGeneratePrompts {
                        for promptAttempt in 0..<3 {
                            do {
                                prompt = try await promptService.generatePrompt(
                                    scene: scene,
                                    shotIndex: shotIndex,
                                    moment: moment
                                )
                                break
                            } catch {
                                if promptAttempt < 2 {
                                    progress.errorMessage = "Prompt retry \(promptAttempt + 1) — \(error.localizedDescription)"
                                    await onProgress(progress)
                                    try? await Task.sleep(for: .seconds(2))
                                }
                            }
                        }
                    }

                    guard !prompt.isEmpty else {
                        progress.completedImages += config.imagesPerMoment
                        await onProgress(progress)
                        continue
                    }

                    for repeatIndex in 0..<config.repeatsPerPrompt {
                        // Check manifest — skip if this exact combination was already done
                        let key = BulkRunManifest.key(sceneSlug: sceneSlug, shotIndex: shotIndex, moment: moment, repeatIndex: repeatIndex)
                        if manifest.completedKeys.contains(key) {
                            progress.completedImages += config.batchSize
                            await onProgress(progress)
                            continue
                        }

                        let saved = await generateWithRetry(
                            prompt: prompt,
                            model: config.model,
                            config: store.drawThingsPlaceConfig,
                            owpURL: owpURL,
                            sceneSlug: sceneSlug,
                            shotIndex: shotIndex,
                            moment: moment,
                            characters: store.characters,
                            batchSize: config.batchSize,
                            maxRetries: 5,
                            progress: &progress
                        )
                        progress.completedImages += saved
                        if saved > 0 {
                            manifest.markCompleted(key: key)
                            manifest.save(owpURL: owpURL)
                        }
                        await onProgress(progress)
                    }

                    // Refresh gallery after EACH moment so UI updates in real time
                    store.refreshImagineGalleryFromDisk(sceneID: scene.id)
                }
            }
        }

        progress.isRunning = false
        await onProgress(progress)

        // If fully complete, delete the manifest so next run starts fresh
        if progress.completedImages >= progress.totalImages {
            manifest.delete(owpURL: owpURL)
        }
    }

    // MARK: - Retry Logic

    /// Generate with automatic retry on connection failures. Returns number of images saved.
    private func generateWithRetry(
        prompt: String,
        model: ImagineDrawThingsModel,
        config: DrawThingsPlaceConfig,
        owpURL: URL,
        sceneSlug: String,
        shotIndex: Int,
        moment: ImagineShotMoment,
        characters: [AnimationCharacter],
        batchSize: Int,
        maxRetries: Int,
        progress: inout ImagineBulkRunProgress
    ) async -> Int {
        for attempt in 0...maxRetries {
            do {
                let saved = try await generateWithDrawThings(
                    prompt: prompt,
                    model: model,
                    config: config,
                    owpURL: owpURL,
                    sceneSlug: sceneSlug,
                    shotIndex: shotIndex,
                    moment: moment,
                    characters: characters,
                    batchSize: batchSize
                )
                progress.errorMessage = nil
                return saved.count
            } catch {
                let isConnectionError = (error as NSError).domain == NSURLErrorDomain
                let isTransient = isConnectionError ||
                    (error as? GenerationError).map { if case .httpError(let code, _) = $0 { return code >= 500 } else { return false } } ?? false

                if isTransient && attempt < maxRetries {
                    let delay = min(Double(attempt + 1) * 2.0, 15.0) // 2s, 4s, 6s, 8s, 10s... max 15s
                    progress.errorMessage = "Retry \(attempt + 1)/\(maxRetries) in \(Int(delay))s — \(error.localizedDescription)"
                    try? await Task.sleep(for: .seconds(delay))
                    continue
                }

                // Non-transient or exhausted retries
                progress.errorMessage = "Failed after \(attempt + 1) attempts: \(error.localizedDescription)"
                return 0
            }
        }
        return 0
    }

    // MARK: - Errors

    enum GenerationError: LocalizedError {
        case invalidURL
        case httpError(Int, String)
        case noImage
        case drawThingsLoRA(String)

        var errorDescription: String? {
            switch self {
            case .invalidURL: "Invalid Draw Things URL."
            case .httpError(let code, let msg): "Draw Things error \(code): \(msg)"
            case .noImage: "Draw Things returned no image."
            case .drawThingsLoRA(let detail): detail
            }
        }
    }
}

// MARK: - Bulk Run Manifest (resumable progress tracking)

@available(macOS 26.0, *)
private extension ImagineGenerationService {
    func assembledPrompt(
        basePrompt: String,
        config: DrawThingsPlaceConfig
    ) -> String {
        [
            config.promptPrefix.trimmingCharacters(in: .whitespacesAndNewlines),
            basePrompt.trimmingCharacters(in: .whitespacesAndNewlines),
            config.promptSuffix.trimmingCharacters(in: .whitespacesAndNewlines)
        ]
        .filter { !$0.isEmpty }
        .joined(separator: ", ")
    }
}

/// Tracks which scene/shot/moment/repeat combinations have been completed in a bulk run.
/// Saved to disk so interrupted runs can be resumed by hitting the button again.
@available(macOS 26.0, *)
final class BulkRunManifest {
    private(set) var completedKeys: Set<String>
    let config: ImagineBulkRunConfig

    private init(completedKeys: Set<String>, config: ImagineBulkRunConfig) {
        self.completedKeys = completedKeys
        self.config = config
    }

    static func key(sceneSlug: String, shotIndex: Int, moment: ImagineShotMoment, repeatIndex: Int) -> String {
        "\(sceneSlug)/shot-\(shotIndex)/\(moment.directoryName)/r\(repeatIndex)"
    }

    func markCompleted(key: String) {
        completedKeys.insert(key)
    }

    // MARK: - Persistence

    private static func manifestURL(owpURL: URL) -> URL {
        ImagineProjectStorage.imagineRoot(owpURL: owpURL)
            .appendingPathComponent("bulk-run-manifest.json")
    }

    static func loadOrCreate(owpURL: URL, config: ImagineBulkRunConfig) -> BulkRunManifest {
        let url = manifestURL(owpURL: owpURL)
        guard let data = try? Data(contentsOf: url),
              let stored = try? JSONDecoder().decode(StoredManifest.self, from: data) else {
            return BulkRunManifest(completedKeys: [], config: config)
        }
        // Only reuse if the config matches (same model, batch size, repeats)
        if stored.model == config.model.rawValue &&
           stored.batchSize == config.batchSize &&
           stored.repeatsPerPrompt == config.repeatsPerPrompt {
            return BulkRunManifest(completedKeys: Set(stored.completedKeys), config: config)
        }
        // Config changed — start fresh
        return BulkRunManifest(completedKeys: [], config: config)
    }

    func save(owpURL: URL) {
        let url = Self.manifestURL(owpURL: owpURL)
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stored = StoredManifest(
            completedKeys: Array(completedKeys),
            model: config.model.rawValue,
            batchSize: config.batchSize,
            repeatsPerPrompt: config.repeatsPerPrompt
        )
        let data = try? JSONEncoder().encode(stored)
        try? data?.write(to: url, options: .atomic)
    }

    func delete(owpURL: URL) {
        try? FileManager.default.removeItem(at: Self.manifestURL(owpURL: owpURL))
    }

    private struct StoredManifest: Codable {
        var completedKeys: [String]
        var model: String
        var batchSize: Int
        var repeatsPerPrompt: Int
    }
}
