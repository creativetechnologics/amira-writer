import AppKit
import Foundation
import ProjectKit

@available(macOS 26.0, *)
@MainActor
final class ExpressionBatchService {

    struct ExpressionBatchItem: Identifiable, Sendable {
        var id: UUID = UUID()
        var presetID: String
        var emotionName: String
        var prompt: String
        var isQueued: Bool = true
    }

    struct ExpressionBatchResult: Sendable {
        var emotionName: String
        var imagePath: String?
        var error: String?
    }

    /// Build a batch of expression generation items from the emotion library.
    /// Each item gets a carefully crafted prompt for Nano Banana 2.
    static func buildBatch(
        for character: AnimationCharacter,
        emotions: [String]
    ) -> [ExpressionBatchItem] {
        emotions.map { emotionName in
            let prompt = buildExpressionPrompt(
                emotionName: emotionName,
                character: character
            )
            return ExpressionBatchItem(
                presetID: CharacterReferenceWorkflowCatalog.slug(from: emotionName),
                emotionName: emotionName,
                prompt: prompt
            )
        }
    }

    static func buildBatch(
        for character: AnimationCharacter,
        presets: [EmotionLibrary.ExpressionPreset]
    ) -> [ExpressionBatchItem] {
        presets.map { preset in
            let prompt = buildExpressionPrompt(
                emotionName: preset.displayName,
                character: character
            )
            return ExpressionBatchItem(
                presetID: preset.id,
                emotionName: preset.displayName,
                prompt: prompt
            )
        }
    }

    /// Generate a single expression prompt optimized for Nano Banana 2.
    ///
    /// Key prompt engineering decisions:
    /// - Uses "the reference character" to anchor identity to the reference image
    /// - Describes the expression in detail (muscle movements, not just emotion labels)
    /// - Specifies close-up framing to focus on the face
    /// - Avoids character names entirely
    /// - Includes style consistency markers
    static func buildExpressionPrompt(
        emotionName: String,
        character: AnimationCharacter
    ) -> String {
        let subject = character.age.map { "this \($0)-year-old \(character.genderType.promptNoun)" }
            ?? "this \(character.genderType.promptNoun)"

        let expressionDetail = expressionDescription(for: emotionName)

        return """
        Create one highly photorealistic close-up portrait of the exact same \(subject) from the reference image, \
        preserving their exact face shape, eyes, nose, mouth, hairline, skin tone, and apparent age.

        Expression: \(expressionDetail)

        Framing: tight close-up of the face and upper shoulders, shallow depth of field, \
        natural filmic color, realistic skin pores, sharp face detail. \
        The background should be simple and out of focus. \
        No text, no watermark, no artifacts.
        """
    }

    /// Maps emotion names to detailed facial descriptions that work well with image generators.
    /// Image generators respond better to physical descriptions than emotion labels.
    private static func expressionDescription(for emotionName: String) -> String {
        let normalized = emotionName.lowercased().trimmingCharacters(in: .whitespaces)
        switch normalized {
        case "neutral":
            return "completely neutral expression, relaxed facial muscles, mouth gently closed, eyes looking directly at camera with calm steady gaze"
        case "happy", "joy":
            return "genuine warm smile, corners of mouth raised, slight crow's feet around eyes, relaxed open expression, bright eyes"
        case "sad", "sadness":
            return "downturned mouth corners, slightly furrowed brow, glistening eyes as if holding back tears, drooping eyelids"
        case "angry", "anger":
            return "tightly furrowed brow, narrowed eyes, clenched jaw, flared nostrils, lips pressed firmly together, intense glaring eyes"
        case "surprised", "surprise":
            return "wide open eyes, raised eyebrows high on forehead, open mouth forming an O shape, slightly pulled-back head"
        case "fearful", "fear":
            return "wide eyes with visible whites, raised and drawn-together eyebrows, slightly open mouth, tense facial muscles, pale complexion"
        case "disgusted", "disgust":
            return "wrinkled nose, raised upper lip showing teeth slightly, narrowed eyes, head tilted slightly away"
        case "contempt":
            return "one corner of mouth slightly raised in a half-smirk, one eyebrow slightly higher than the other, chin slightly raised"
        case "determined", "determination":
            return "set jaw, focused narrowed eyes looking straight ahead, slight forward lean of the head, compressed lips"
        case "worried", "anxious":
            return "furrowed brow with inner eyebrows raised, biting lower lip slightly, wide searching eyes, tense forehead"
        case "smirk", "smirking":
            return "asymmetric smile with one corner raised higher, knowing look in the eyes, relaxed brow, slightly tilted head"
        case "crying":
            return "tears streaming down cheeks, red-rimmed eyes, quivering chin, scrunched eyebrows, open mouth showing emotional distress"
        case "laughing":
            return "mouth wide open in genuine laughter, eyes crinkled shut or nearly shut, visible teeth, head tilted back slightly"
        case "pensive", "thoughtful":
            return "slightly furrowed brow, eyes gazing slightly off to the side, lips pressed gently together, chin resting slightly forward"
        case "confused":
            return "one eyebrow raised higher than the other, slightly squinting eyes, head tilted to one side, mouth slightly open"
        case "proud":
            return "chin raised, confident half-smile, chest forward, warm eyes looking slightly downward, relaxed broad shoulders"
        case "shy", "embarrassed":
            return "eyes looking down and to the side, slight blush on cheeks, small tight-lipped smile, head turned slightly away"
        case "exhausted", "tired":
            return "heavy drooping eyelids, dark circles under eyes, slack jaw, unfocused gaze, slightly slumped posture"
        case "hopeful":
            return "eyes looking upward with gentle brightness, soft slight smile, relaxed open expression, eyebrows slightly raised"
        case "pleading":
            return "wide earnest eyes, raised inner eyebrows, slightly open mouth, head tilted forward, vulnerable open expression"
        default:
            return "\(emotionName) expression, showing this emotion clearly through facial muscles and eyes"
        }
    }

    /// Run the batch, generating images one at a time to stay within rate limits.
    static func runBatch(
        items: [ExpressionBatchItem],
        character: AnimationCharacter,
        referenceImagePaths: [String] = [],
        store: AnimateStore,
        onProgress: @MainActor (Int, Int, String?) -> Void
    ) async throws -> [ExpressionBatchResult] {
        if let error = store.geminiImageGenerationAvailabilityError {
            throw error
        }
        let apiKey = store.geminiAPIKey
        guard store.animateURL != nil else { throw ExpressionBatchError.noProject }
        guard let frontNeutral = character.headTurnaroundSlots.first(where: { $0.pose == .frontNeutral })?.approvedVariant else {
            throw ExpressionBatchError.noFrontNeutralReference
        }
        let referenceURL = store.resolvedCharacterAssetURL(for: frontNeutral.imagePath)
            ?? URL(fileURLWithPath: frontNeutral.imagePath)
        guard let referenceImage = GeminiImageService.referenceImage(from: referenceURL) else {
            throw ExpressionBatchError.noFrontNeutralReference
        }

        let service = GeminiImageService()
        let queuedItems = items.filter(\.isQueued)
        var results: [ExpressionBatchResult] = []

        for (index, item) in queuedItems.enumerated() {
            await onProgress(index, queuedItems.count, "Generating \(item.emotionName)…")

            let request = GeminiImageService.GenerationRequest(
                prompt: item.prompt,
                referenceImages: [referenceImage],
                model: store.selectedGeminiModel,
                aspectRatio: "1:1",
                imageSize: "2K"
            )

            do {
                store.logGeminiAPICall(endpoint: "image-generation", source: "ExpressionBatchService")
                let result = try await service.generate(request: request, apiKey: apiKey)

                let variant = try store.storeExpressionVariant(
                    result.imageData,
                    presetID: item.presetID,
                    displayName: item.emotionName,
                    prompt: item.prompt,
                    model: store.selectedGeminiModel,
                    for: character.id,
                    referencePath: frontNeutral.imagePath
                )

                results.append(ExpressionBatchResult(emotionName: item.emotionName, imagePath: variant?.imagePath))
            } catch {
                results.append(ExpressionBatchResult(emotionName: item.emotionName, error: error.localizedDescription))
            }
        }

        await onProgress(queuedItems.count, queuedItems.count, "Done")
        return results
    }

    enum ExpressionBatchError: LocalizedError {
        case noAPIKey
        case geminiBlocked
        case noProject
        case noFrontNeutralReference

        var errorDescription: String? {
            switch self {
            case .noAPIKey: "Gemini API key is not set."
            case .geminiBlocked: "Gemini API calls are blocked. Enable Gemini API Calls in Inspector > Tools."
            case .noProject: "No project is open."
            case .noFrontNeutralReference: "Choose a Head Turnaround Grid → Front Neutral image before generating expressions."
            }
        }
    }
}
