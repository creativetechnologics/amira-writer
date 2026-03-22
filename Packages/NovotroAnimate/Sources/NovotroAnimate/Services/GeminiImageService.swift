import AppKit
import Foundation

/// Direct Gemini API client for AI-assisted character image generation.
///
/// Supports both text-only and image+text prompts. Images are sent as base64-encoded
/// inline data and received the same way. Uses URLSession with no external dependencies.
@available(macOS 26.0, *)
@MainActor
final class GeminiImageService {
    // MARK: - Types

    enum ServiceError: LocalizedError {
        case noAPIKey
        case invalidResponse
        case httpError(Int, String)
        case noImageInResponse
        case imageDecodingFailed
        case cancelled

        var errorDescription: String? {
            switch self {
            case .noAPIKey: "Gemini API key is not set."
            case .invalidResponse: "Invalid response from Gemini API."
            case .httpError(let code, let msg): "HTTP \(code): \(msg)"
            case .noImageInResponse: "No image was returned in the response."
            case .imageDecodingFailed: "Failed to decode the generated image."
            case .cancelled: "Generation was cancelled."
            }
        }
    }

    struct GenerationRequest {
        var prompt: String
        var referenceImages: [ReferenceImage] = []
        var model: GeminiModel = .flash
        var aspectRatio: String = "3:4"
    }

    struct ReferenceImage {
        var data: String  // Base64-encoded
        var mimeType: String  // "image/png", "image/jpeg", "image/webp"
    }

    struct GenerationResult {
        var image: NSImage
        var imageData: Data
        var textResponse: String?
    }

    /// Summary of what a generation batch will cost.
    struct CostEstimate {
        var model: GeminiModel
        var imageCount: Int
        var estimatedCost: Double

        var description: String {
            let modelName = model.displayName
            return "\(imageCount) images via \(modelName) — est. ~$\(String(format: "%.2f", estimatedCost))"
        }
    }

    // MARK: - Properties

    private let session: URLSession
    private let baseURL = "https://generativelanguage.googleapis.com/v1beta/models"

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 300
        self.session = URLSession(configuration: config)
    }

    // MARK: - Cost Estimation

    static func estimateCost(model: GeminiModel, imageCount: Int) -> CostEstimate {
        CostEstimate(
            model: model,
            imageCount: imageCount,
            estimatedCost: model.estimatedCostPerImage * Double(imageCount)
        )
    }

    // MARK: - Image Generation

    /// Generate a single image from a text prompt with optional reference images.
    func generate(request: GenerationRequest, apiKey: String) async throws -> GenerationResult {
        guard !apiKey.isEmpty else { throw ServiceError.noAPIKey }

        guard let url = URL(string: "\(baseURL)/\(request.model.rawValue):generateContent") else {
            throw ServiceError.invalidResponse
        }

        var parts: [[String: Any]] = []

        // Add text prompt
        parts.append(["text": request.prompt])

        // Add reference images
        for ref in request.referenceImages {
            parts.append([
                "inlineData": [
                    "mimeType": ref.mimeType,
                    "data": ref.data,
                ]
            ])
        }

        let requestBody: [String: Any] = [
            "contents": [
                ["parts": parts]
            ],
            "generationConfig": [
                "responseModalities": ["TEXT", "IMAGE"],
                "imageConfig": [
                    "aspectRatio": request.aspectRatio,
                ],
            ],
        ]

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        let (data, response) = try await session.data(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ServiceError.invalidResponse
        }

        if httpResponse.statusCode != 200 {
            let body = String(data: data, encoding: .utf8) ?? "No body"
            throw ServiceError.httpError(httpResponse.statusCode, body)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let firstCandidate = candidates.first,
              let content = firstCandidate["content"] as? [String: Any],
              let responseParts = content["parts"] as? [[String: Any]]
        else {
            throw ServiceError.invalidResponse
        }

        var resultImage: NSImage?
        var resultData: Data?
        var textResponse: String?

        for part in responseParts {
            if let text = part["text"] as? String {
                textResponse = text
            } else if let inlineData = part["inlineData"] as? [String: Any],
                      let base64String = inlineData["data"] as? String {
                guard let imageData = Data(base64Encoded: base64String) else {
                    throw ServiceError.imageDecodingFailed
                }
                guard let image = NSImage(data: imageData) else {
                    throw ServiceError.imageDecodingFailed
                }
                resultImage = image
                resultData = imageData
            }
        }

        guard let image = resultImage, let imageData = resultData else {
            throw ServiceError.noImageInResponse
        }

        return GenerationResult(image: image, imageData: imageData, textResponse: textResponse)
    }

    // MARK: - Reference Image Helpers

    /// Create a ReferenceImage from an NSImage (converts to JPEG).
    static func referenceImage(from nsImage: NSImage, quality: CGFloat = 0.85) -> ReferenceImage? {
        guard let tiffData = nsImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let jpegData = bitmap.representation(using: .jpeg, properties: [.compressionFactor: quality])
        else { return nil }

        return ReferenceImage(
            data: jpegData.base64EncodedString(),
            mimeType: "image/jpeg"
        )
    }

    /// Create a ReferenceImage from a file URL.
    static func referenceImage(from url: URL) -> ReferenceImage? {
        guard let data = try? Data(contentsOf: url) else { return nil }

        let ext = url.pathExtension.lowercased()
        let mimeType: String
        switch ext {
        case "png": mimeType = "image/png"
        case "jpg", "jpeg": mimeType = "image/jpeg"
        case "webp": mimeType = "image/webp"
        default: mimeType = "image/png"
        }

        return ReferenceImage(
            data: data.base64EncodedString(),
            mimeType: mimeType
        )
    }

    /// Save a generated image to disk as PNG.
    static func saveImage(_ data: Data, to directory: URL, filename: String) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent(filename)
        try data.write(to: fileURL)
        return fileURL
    }
}

// MARK: - Turnaround Generation

@available(macOS 26.0, *)
extension GeminiImageService {

    /// Prompt templates for generating character turnaround views.
    struct TurnaroundPrompts {
        static func prompt(for angle: AngleView, characterName: String, style: String = "") -> String {
            let styleNote = style.isEmpty ? "" : " Style: \(style)."
            let angleDesc: String
            switch angle {
            case .front:
                angleDesc = "front view, facing directly toward the camera"
            case .threeQuarterFront:
                angleDesc = "three-quarter front view, turned slightly to the right (about 45 degrees)"
            case .side:
                angleDesc = "side profile view, facing right"
            case .threeQuarterBack:
                angleDesc = "three-quarter back view, turned away at about 45 degrees"
            case .back:
                angleDesc = "back view, facing directly away from the camera"
            }

            return """
            Generate a full-body character turnaround illustration of "\(characterName)" in \(angleDesc). \
            The character should be standing in a neutral A-pose with arms slightly away from the body. \
            Use a clean white or transparent background. \
            Match the exact same art style, proportions, colors, and costume details as the reference image. \
            Keep the character centered and at the same scale as the reference.\(styleNote)
            """
        }

        /// All angles in generation order.
        static let generationOrder: [AngleView] = [
            .front, .threeQuarterFront, .side, .threeQuarterBack, .back,
        ]
    }

    /// Prompt templates for generating body part breakdowns.
    struct PartBreakdownPrompts {
        static func prompt(for partType: PartType, characterName: String, angle: AngleView) -> String {
            let partName = partType.rawValue
                .replacingOccurrences(of: "Left", with: " (left)")
                .replacingOccurrences(of: "Right", with: " (right)")

            return """
            Extract and isolate the \(partName) from this character illustration of "\(characterName)". \
            Output ONLY the isolated body part on a completely transparent background. \
            Maintain the exact art style, colors, and details. \
            The part should be cleanly separated with smooth edges, suitable for puppet-style animation. \
            Do not include any other body parts or background elements.
            """
        }
    }

    /// Prompt templates for generating expression variants.
    struct ExpressionPrompts {
        static let expressions = [
            "neutral", "happy", "sad", "angry", "surprised",
            "worried", "disgusted", "fearful", "smirking", "laughing",
        ]

        static func prompt(for expression: String, characterName: String) -> String {
            """
            Generate the face of character "\(characterName)" showing a \(expression) expression. \
            Match the exact same art style, proportions, and details as the reference image. \
            Show only the head and face area on a transparent background. \
            The expression should be clear and exaggerated enough for animation readability.
            """
        }
    }

    /// Prompt templates for generating viseme (mouth shape) variants.
    struct VisemePrompts {
        static func prompt(for viseme: PrestonBlairViseme, characterName: String) -> String {
            let shapeDesc: String
            switch viseme {
            case .rest: shapeDesc = "mouth closed in a neutral resting position"
            case .ai: shapeDesc = "mouth open wide as if saying 'AH' or 'EYE'"
            case .e: shapeDesc = "mouth stretched wide as if saying 'EE' or 'EH'"
            case .o: shapeDesc = "mouth rounded open as if saying 'OH'"
            case .u: shapeDesc = "mouth slightly pursed as if saying 'OO'"
            case .consonant: shapeDesc = "mouth slightly open with teeth visible, as if saying 'D' or 'K'"
            case .fv: shapeDesc = "lower lip tucked under upper teeth, as if saying 'F' or 'V'"
            case .l: shapeDesc = "mouth open with tongue tip visible behind upper teeth, as if saying 'L'"
            case .mbp: shapeDesc = "lips pressed firmly together, as if saying 'M', 'B', or 'P'"
            case .wq: shapeDesc = "lips pursed forward in a small circle, as if saying 'W' or 'OO'"
            }

            return """
            Generate just the mouth area of character "\(characterName)" showing the \(viseme.label) viseme shape: \(shapeDesc). \
            Match the exact same art style as the reference image. \
            Show only the mouth and immediately surrounding area on a transparent background. \
            The mouth shape should be clear and distinct for lip-sync animation.
            """
        }
    }
}
