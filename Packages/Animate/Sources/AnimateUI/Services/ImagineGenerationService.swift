import AppKit
import Foundation
import ProjectKit

@available(macOS 26.0, *)
@MainActor
struct ImagineGenerationService {
    /// Keep Gemini requests small and predictable. Edit mode needs the source
    /// image first, then storyboard/automatic context, then any remaining manual
    /// references. The service preserves that order and caps the final request.
    private static let maxGeminiReferenceImagesPerRequest = 8

    // MARK: - Gemini Generation

    func generateWithGemini(
        prompt: String,
        referenceImages: [GeminiImageService.ReferenceImage],
        model: GeminiModel,
        apiKey: String,
        owpURL: URL,
        sceneSlug: String,
        shotIndex: Int,
        moment: ImagineShotMoment,
        aspectRatio: String = "16:9",
        imageSize: String = "2K"
    ) async throws -> URL {
        let service = GeminiImageService()
        let request = GeminiImageService.GenerationRequest(
            prompt: prompt,
            referenceImages: referenceImages,
            model: model,
            aspectRatio: aspectRatio,
            imageSize: imageSize
        )

        let result = try await service.generate(request: request, apiKey: apiKey)

        let savedURL = try await ImagineProjectStorage.saveGeneratedImageAsync(
            result.imageData,
            owpURL: owpURL,
            sceneSlug: sceneSlug,
            shotIndex: shotIndex,
            moment: moment,
            filePrefix: "gemini"
        )
        await writeGeminiSidecarsBestEffort(
            imageURL: savedURL,
            prompt: prompt,
            textResponse: result.textResponse,
            plan: nil
        )
        return savedURL
    }

    func generateWithGemini(
        plan: ShotFrameGenerationPlan,
        manualReferenceImages: [GeminiImageService.ReferenceImage],
        model: GeminiModel,
        apiKey: String,
        owpURL: URL,
        sceneSlug: String,
        shotIndex: Int,
        moment: ImagineShotMoment
    ) async throws -> URL {
        let service = GeminiImageService()
        let automaticReferences = try planAutomaticReferences(
            for: plan,
            maxCount: Self.maxGeminiReferenceImagesPerRequest
        )
        let remainingManualReferenceSlots = max(0, Self.maxGeminiReferenceImagesPerRequest - automaticReferences.count)
        let cappedManualReferences = Array(manualReferenceImages.prefix(remainingManualReferenceSlots))
        let request = GeminiImageService.GenerationRequest(
            prompt: plan.executionPrompt,
            referenceImages: automaticReferences + cappedManualReferences,
            model: model,
            aspectRatio: plan.openMattePlan?.generatedAspectRatio ?? "16:9",
            imageSize: plan.openMattePlan?.generatedImageSize ?? "2K",
            referenceImagesFirst: plan.usesEditPrompt
        )

        let result = try await service.generate(request: request, apiKey: apiKey)

        let savedURL = try await ImagineProjectStorage.saveGeneratedImageAsync(
            result.imageData,
            owpURL: owpURL,
            sceneSlug: sceneSlug,
            shotIndex: shotIndex,
            moment: moment,
            filePrefix: plan.usesEditPrompt ? "gemini_edit" : "gemini"
        )
        await writeGeminiSidecarsBestEffort(
            imageURL: savedURL,
            prompt: plan.executionPrompt,
            textResponse: result.textResponse,
            plan: plan
        )
        return savedURL
    }
}

@available(macOS 26.0, *)
private extension ImagineGenerationService {
    func planAutomaticReferences(
        for plan: ShotFrameGenerationPlan,
        maxCount: Int
    ) throws -> [GeminiImageService.ReferenceImage] {
        var references: [GeminiImageService.ReferenceImage] = []
        var seen = Set<String>()

        func appendReference(path: String, required: Bool) throws {
            guard references.count < maxCount else { return }
            let url = URL(fileURLWithPath: path).standardizedFileURL
            guard seen.insert(url.path).inserted else { return }
            if required {
                references.append(try GeminiImageService.requiredReferenceImage(from: url))
            } else if let reference = GeminiImageService.referenceImage(from: url) {
                references.append(reference)
            }
        }

        if let sourcePath = plan.sourceImage?.path {
            try appendReference(path: sourcePath, required: plan.usesEditPrompt)
        } else if plan.usesEditPrompt {
            throw GeminiImageService.ServiceError.referenceImageUnavailable(
                "Shot \(plan.shotIndex + 1) \(plan.moment.rawValue.lowercased()) is an edit plan, but no source image was resolved. Run or select the prior continuity frame first."
            )
        }

        for path in plan.referenceImagePaths {
            try appendReference(path: path, required: false)
        }

        return references
    }

    nonisolated func writeGeminiSidecarsBestEffort(
        imageURL: URL,
        prompt: String,
        textResponse: String?,
        plan: ShotFrameGenerationPlan?
    ) async {
        do {
            try await writeGeminiSidecars(
                imageURL: imageURL,
                prompt: prompt,
                textResponse: textResponse,
                plan: plan
            )
        } catch {
            NSLog(
                "[ImagineGenerationService] Saved Gemini image but failed to write sidecars for %@: %@",
                imageURL.path,
                error.localizedDescription
            )
        }
    }

    nonisolated func writeGeminiSidecars(
        imageURL: URL,
        prompt: String,
        textResponse: String?,
        plan: ShotFrameGenerationPlan?
    ) async throws {
        try await Task.detached(priority: .utility) {
            let promptURL = imageURL.deletingPathExtension().appendingPathExtension("prompt.txt")
            try prompt.write(to: promptURL, atomically: true, encoding: .utf8)

            if let textResponse,
               !textResponse.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let responseURL = imageURL.deletingPathExtension().appendingPathExtension("response.txt")
                try textResponse.write(to: responseURL, atomically: true, encoding: .utf8)
            }

            if let plan {
                let planURL = imageURL.deletingPathExtension().appendingPathExtension("plan.json")
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                let data = try encoder.encode(
                    CompactShotFrameGenerationPlanSidecar(
                        plan: plan,
                        executionPromptCharacterCount: prompt.count
                    )
                )
                try data.write(to: planURL, options: .atomic)
            }
        }.value
    }

    private struct CompactShotFrameGenerationPlanSidecar: Codable, Sendable {
        var schemaVersion: Int = 1
        var planID: UUID
        var sceneID: UUID
        var shotID: UUID
        var shotIndex: Int
        var moment: ImagineShotMoment
        var mode: ShotFrameGenerationMode
        var sourceImage: ShotFrameSourceImage?
        var reasons: [ShotFrameStrategyReason]
        var confidence: Double
        var storyboardImagePath: String?
        var storyboardAnalysisPath: String?
        var referenceImagePaths: [String]
        var overridePolicy: ShotFrameOverridePolicy
        var openMattePlan: ShotFrameOpenMattePlan?
        var createdAt: Date
        var basePromptCharacterCount: Int
        var effectivePromptCharacterCount: Int
        var editInstructionCharacterCount: Int?
        var executionPromptCharacterCount: Int
        var promptTextSidecar: String = "prompt.txt"

        init(
            plan: ShotFrameGenerationPlan,
            executionPromptCharacterCount: Int
        ) {
            self.planID = plan.id
            self.sceneID = plan.sceneID
            self.shotID = plan.shotID
            self.shotIndex = plan.shotIndex
            self.moment = plan.moment
            self.mode = plan.mode
            self.sourceImage = plan.sourceImage
            self.reasons = plan.decision.reasons
            self.confidence = plan.decision.confidence
            self.storyboardImagePath = plan.storyboardImagePath
            self.storyboardAnalysisPath = plan.storyboardAnalysisPath
            self.referenceImagePaths = plan.referenceImagePaths
            self.overridePolicy = plan.overridePolicy
            self.openMattePlan = plan.openMattePlan
            self.createdAt = plan.createdAt
            self.basePromptCharacterCount = plan.basePrompt.count
            self.effectivePromptCharacterCount = plan.effectivePrompt.count
            self.editInstructionCharacterCount = plan.editInstruction?.count
            self.executionPromptCharacterCount = executionPromptCharacterCount
        }
    }
}
