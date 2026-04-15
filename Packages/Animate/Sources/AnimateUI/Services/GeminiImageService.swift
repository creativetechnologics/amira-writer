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
        case rateLimitExceeded
        case masterSwitchOff
        case vertexNotConfigured(String)

        var errorDescription: String? {
            switch self {
            case .noAPIKey: "Gemini API key is not set."
            case .invalidResponse: "Invalid response from Gemini API."
            case .httpError(let code, let msg): "HTTP \(code): \(msg)"
            case .noImageInResponse: "No image was returned in the response."
            case .imageDecodingFailed: "Failed to decode the generated image."
            case .cancelled: "Generation was cancelled."
            case .rateLimitExceeded: "Too many API calls in a short period. Wait a moment and try again."
            case .masterSwitchOff: "Gemini API calls are disabled. Enable them in the Imagine > Inspector > Tools tab."
            case .vertexNotConfigured(let msg): "Vertex AI backend is selected but not configured: \(msg)"
            }
        }
    }

    struct GenerationRequest {
        var prompt: String
        var referenceImages: [ReferenceImage] = []
        var model: GeminiModel = .flash
        var aspectRatio: String = "3:4"
        var imageSize: String = "2K"
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

    // MARK: - Rate Limiting & Circuit Breaker

    /// Maximum number of `generate()` calls allowed per 60-second window.
    static var rateLimitPerMinute: Int = 5

    /// Circuit breaker: after this many consecutive failures, all calls are blocked
    /// until the app is restarted. Prevents runaway retry loops from burning API quota.
    static let circuitBreakerThreshold: Int = 10

    private static var callCount: Int = 0
    private static var callCountResetTime: Date = Date()
    private static var consecutiveFailures: Int = 0
    private static var circuitBreakerTripped: Bool = false

    // MARK: - Properties

    private let session: URLSession
    private let baseURL = "https://generativelanguage.googleapis.com/v1beta/models"

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 600
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

    /// Callers MUST check `AnimateStore.isGeminiAllowed()` before calling this method.
    /// The Imagine inspector's Tools tab controls the master switch.
    /// Generate a single image from a text prompt with optional reference images.
    ///
    /// Backend selection is read from `ImageGenBackendStore.currentBackend()`:
    /// - `.aiStudio` (default) — uses the provided `apiKey` as `x-goog-api-key`
    /// - `.vertex` — shells out to gcloud for an OAuth token and hits Vertex AI;
    ///   the `apiKey` argument is ignored in this mode.
    func generate(request: GenerationRequest, apiKey: String) async throws -> GenerationResult {
        let backend = ImageGenBackendStore.currentBackend()
        if backend == .aiStudio {
            guard !apiKey.isEmpty else { throw ServiceError.noAPIKey }
        }

        // Circuit breaker: if too many consecutive failures, refuse ALL calls
        // until the app is restarted. This prevents runaway retry loops.
        if Self.circuitBreakerTripped {
            print("[GeminiImageService] 🛑 CIRCUIT BREAKER TRIPPED — all API calls blocked. Restart the app to reset.")
            throw ServiceError.rateLimitExceeded
        }

        // Rate limiting: reset the window counter if more than 60 seconds have elapsed.
        let now = Date()
        if now.timeIntervalSince(Self.callCountResetTime) > 60 {
            Self.callCount = 0
            Self.callCountResetTime = now
        }
        Self.callCount += 1
        print("[GeminiImageService] API call #\(Self.callCount) at \(now) — model: \(request.model.rawValue)")
        if Self.callCount > Self.rateLimitPerMinute {
            print("[GeminiImageService] ⚠️ RATE LIMIT: More than \(Self.rateLimitPerMinute) API calls in 60 seconds. Blocking call.")
            throw ServiceError.rateLimitExceeded
        }

        // Resolve the target URL + auth header based on the selected backend.
        let (url, authHeaderName, authHeaderValue): (URL, String, String)
        switch backend {
        case .aiStudio:
            guard let u = URL(string: "\(baseURL)/\(request.model.rawValue):generateContent") else {
                throw ServiceError.invalidResponse
            }
            url = u
            authHeaderName = "x-goog-api-key"
            authHeaderValue = apiKey

        case .vertex:
            let settings = ImageGenBackendStore.currentVertexSettings()
            guard !settings.projectID.isEmpty else {
                throw ServiceError.vertexNotConfigured("missing project ID")
            }
            let client = VertexAIClient(projectID: settings.projectID, region: settings.region)
            guard let u = client.generateContentURL(modelID: request.model.rawValue) else {
                throw ServiceError.invalidResponse
            }
            url = u
            do {
                let token = try await client.accessToken()
                authHeaderName = "Authorization"
                authHeaderValue = "Bearer \(token)"
            } catch {
                throw ServiceError.vertexNotConfigured(error.localizedDescription)
            }
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
                // Vertex AI requires an explicit role on each content item;
                // AI Studio accepts it as optional. Always set it so the same
                // request body works on both backends.
                ["role": "user", "parts": parts]
            ],
            "generationConfig": [
                "responseModalities": ["TEXT", "IMAGE"],
                "imageConfig": [
                    "aspectRatio": request.aspectRatio,
                    "imageSize": request.imageSize,
                ],
            ],
        ]

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(authHeaderValue, forHTTPHeaderField: authHeaderName)
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch {
            Self.consecutiveFailures += 1
            print("[GeminiImageService] Network error (\(Self.consecutiveFailures) consecutive failures): \(error.localizedDescription)")
            if Self.consecutiveFailures >= Self.circuitBreakerThreshold {
                Self.circuitBreakerTripped = true
                print("[GeminiImageService] 🛑 CIRCUIT BREAKER TRIPPED after \(Self.consecutiveFailures) consecutive failures. All API calls blocked until app restart.")
            }
            throw error
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            Self.consecutiveFailures += 1
            throw ServiceError.invalidResponse
        }

        if httpResponse.statusCode != 200 {
            Self.consecutiveFailures += 1
            let body = String(data: data, encoding: .utf8) ?? "No body"
            print("[GeminiImageService] HTTP \(httpResponse.statusCode) (\(Self.consecutiveFailures) consecutive failures)")
            if Self.consecutiveFailures >= Self.circuitBreakerThreshold {
                Self.circuitBreakerTripped = true
                print("[GeminiImageService] 🛑 CIRCUIT BREAKER TRIPPED after \(Self.consecutiveFailures) consecutive failures. All API calls blocked until app restart.")
            }
            throw ServiceError.httpError(httpResponse.statusCode, body)
        }

        // Success — reset the failure counter
        Self.consecutiveFailures = 0

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

// MARK: - Batch Generation

@available(macOS 26.0, *)
struct GeminiBatchSubmissionPlan: Sendable {
    struct PromptRequest: Sendable {
        var id: String
        var title: String
        var prompt: String
        var referencePaths: [String]
        var recommendedLORACaption: String? = nil
    }

    var characterName: String
    var characterSlug: String
    var displayName: String
    var model: GeminiModel
    var aspectRatio: String
    var imageSize: String
    var outputRoot: URL
    var prompts: [PromptRequest]
}

@available(macOS 26.0, *)
struct GeminiBatchSubmissionResult: Sendable {
    var batchName: String
    var metadataPath: URL
    var outputRoot: URL
    var state: String
    var promptCount: Int
    var submittedAt: Date
}

@available(macOS 26.0, *)
final class GeminiBatchService {
    enum BatchError: LocalizedError {
        case missingAPIKey
        case missingPython
        case missingScript(URL)
        case invalidResponse(String)
        case processFailed(String)

        var errorDescription: String? {
            switch self {
            case .missingAPIKey:
                return "Gemini API key is not set."
            case .missingPython:
                return "Python 3 was not found on this Mac."
            case .missingScript(let url):
                return "Batch helper script not found: \(url.path)"
            case .invalidResponse(let message):
                return "Unexpected batch helper response: \(message)"
            case .processFailed(let message):
                return message
            }
        }
    }

    private let fileManager = FileManager.default

    func submit(plan: GeminiBatchSubmissionPlan, apiKey: String) async throws -> GeminiBatchSubmissionResult {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BatchError.missingAPIKey
        }

        let scriptURL = try batchScriptURL()
        let pythonURL = try pythonExecutableURL()
        let stagingDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("amira-inspiration-batch-submit-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        let planURL = stagingDirectory.appendingPathComponent("batch_plan.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        let payload = SerializablePlan(from: plan)
        try encoder.encode(payload).write(to: planURL)
        defer { try? fileManager.removeItem(at: stagingDirectory) }

        let output = try await runProcess(
            executableURL: pythonURL,
            arguments: [scriptURL.path, "submit", "--plan", planURL.path],
            apiKey: apiKey
        )

        guard let data = output.data(using: .utf8) else {
            throw BatchError.invalidResponse(output)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            let response = try decoder.decode(SubmissionResponse.self, from: data)
            return GeminiBatchSubmissionResult(
                batchName: response.batch_name,
                metadataPath: URL(fileURLWithPath: response.metadata_path),
                outputRoot: URL(fileURLWithPath: response.output_root),
                state: response.batch_state,
                promptCount: response.prompt_count,
                submittedAt: response.submitted_at
            )
        } catch {
            throw BatchError.invalidResponse(output)
        }
    }

    /// Launches the batch watchdog Python process.
    ///
    /// IMPORTANT: `timeoutHours` controls an auto-cancellation safety net inside the
    /// watchdog. Gemini image batches are documented to take up to **24 hours**, so the
    /// default is 24. Do NOT drop this below 12 without a very good reason — a short
    /// timeout will kill batches that are merely queued and would otherwise complete.
    func launchWatchdog(metadataPath: URL, apiKey: String, pollSeconds: Int = 120, timeoutHours: Double = 24.0) throws {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BatchError.missingAPIKey
        }

        let scriptURL = try batchScriptURL()
        let pythonURL = try pythonExecutableURL()
        let logURL = metadataPath.deletingLastPathComponent().appendingPathComponent("watchdog.log")

        if !fileManager.fileExists(atPath: logURL.path) {
            fileManager.createFile(atPath: logURL.path, contents: Data())
        }

        let logHandle = try FileHandle(forWritingTo: logURL)
        try logHandle.seekToEnd()

        let process = Process()
        process.executableURL = pythonURL
        process.arguments = [
            scriptURL.path,
            "watch",
            "--metadata", metadataPath.path,
            "--poll-seconds", String(max(30, pollSeconds)),
            "--timeout-hours", String(timeoutHours),
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        environment["GEMINI_API_KEY"] = apiKey
        process.environment = environment
        process.standardOutput = logHandle
        process.standardError = logHandle
        process.standardInput = nil
        try process.run()
    }

    private func batchScriptURL() throws -> URL {
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("gemini_inspiration_batch.py"),
           fileManager.fileExists(atPath: bundled.path) {
            return bundled
        }

        let repoURL = URL(fileURLWithPath: "/Volumes/Storage VIII/Programming/Amira Writer/Scripts/gemini_inspiration_batch.py")
        if fileManager.fileExists(atPath: repoURL.path) {
            return repoURL
        }

        throw BatchError.missingScript(repoURL)
    }

    private func pythonExecutableURL() throws -> URL {
        let candidates = [
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
            "/usr/bin/python3",
        ]

        if let path = candidates.first(where: { fileManager.fileExists(atPath: $0) }) {
            return URL(fileURLWithPath: path)
        }

        throw BatchError.missingPython
    }

    private func runProcess(
        executableURL: URL,
        arguments: [String],
        apiKey: String
    ) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = executableURL
            process.arguments = arguments

            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
            environment["GEMINI_API_KEY"] = apiKey
            process.environment = environment

            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            process.terminationHandler = { process in
                let stdoutData = outputPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
                let stderr = String(data: stderrData, encoding: .utf8) ?? ""

                if process.terminationStatus == 0 {
                    continuation.resume(returning: stdout.trimmingCharacters(in: .whitespacesAndNewlines))
                } else {
                    let message = [stdout, stderr]
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                        .joined(separator: "\n")
                    continuation.resume(throwing: BatchError.processFailed(message.isEmpty ? "Batch helper failed." : message))
                }
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

@available(macOS 26.0, *)
private extension GeminiBatchService {
    struct SerializablePlan: Codable {
        struct PromptRequest: Codable {
            var id: String
            var title: String
            var prompt: String
            var reference_paths: [String]
            var recommended_lora_caption: String?
        }

        var character_name: String
        var character_slug: String
        var display_name: String
        var model: String
        var aspect_ratio: String
        var image_size: String
        var output_root: String
        var prompts: [PromptRequest]

        init(from plan: GeminiBatchSubmissionPlan) {
            character_name = plan.characterName
            character_slug = plan.characterSlug
            display_name = plan.displayName
            model = plan.model.rawValue
            aspect_ratio = plan.aspectRatio
            image_size = plan.imageSize
            output_root = plan.outputRoot.path
            prompts = plan.prompts.map {
                PromptRequest(
                    id: $0.id,
                    title: $0.title,
                    prompt: $0.prompt,
                    reference_paths: $0.referencePaths,
                    recommended_lora_caption: $0.recommendedLORACaption
                )
            }
        }
    }

    struct SubmissionResponse: Codable {
        var batch_name: String
        var metadata_path: String
        var output_root: String
        var batch_state: String
        var prompt_count: Int
        var submitted_at: Date
    }
}
