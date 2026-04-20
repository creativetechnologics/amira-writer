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
        case resourceExhausted(String)
        case masterSwitchOff
        case vertexNotConfigured(String)

        var errorDescription: String? {
            switch self {
            case .noAPIKey:
                return "Gemini API key is not set."
            case .invalidResponse:
                return "Invalid response from Gemini API."
            case .httpError(let code, let msg):
                return "HTTP \(code): \(msg)"
            case .noImageInResponse:
                return "No image was returned in the response."
            case .imageDecodingFailed:
                return "Failed to decode the generated image."
            case .cancelled:
                return "Generation was cancelled."
            case .rateLimitExceeded:
                return "Too many API calls in a short period. Wait a moment and try again."
            case .resourceExhausted(let message):
                let detail = message.trimmingCharacters(in: .whitespacesAndNewlines)
                if detail.isEmpty {
                    return "Vertex AI temporarily ran out of shared capacity (HTTP 429 RESOURCE_EXHAUSTED). The app already retried with backoff. Try again in a moment or switch the run to batch mode."
                }
                return "Vertex AI temporarily ran out of shared capacity (HTTP 429 RESOURCE_EXHAUSTED). The app already retried with backoff. \(detail)"
            case .masterSwitchOff:
                return "Gemini API calls are disabled. Enable them in Settings (gear icon in the title bar)."
            case .vertexNotConfigured(let msg):
                return "Vertex AI backend is selected but not configured: \(msg)"
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
    static var rateLimitPerMinute: Int = 12

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

        do {
            let (data, httpResponse) = try await performRequestWithRetry(urlRequest, backend: backend)

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

            _ = httpResponse
            return GenerationResult(image: image, imageData: imageData, textResponse: textResponse)
        } catch {
            if case ServiceError.cancelled = error {
                throw error
            }
            recordFailure(error)
            throw error
        }
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

    // MARK: - Retry helpers

    private func performRequestWithRetry(
        _ urlRequest: URLRequest,
        backend: ImageGenBackend
    ) async throws -> (Data, HTTPURLResponse) {
        let maxAttempts = backend == .vertex ? 5 : 3
        var lastTransportError: Error?

        for attempt in 1...maxAttempts {
            do {
                let (data, response) = try await session.data(for: urlRequest)
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw ServiceError.invalidResponse
                }

                if httpResponse.statusCode == 200 {
                    return (data, httpResponse)
                }

                let serverMessage = Self.serverMessage(from: data)
                if Self.shouldRetryHTTPStatus(httpResponse.statusCode), attempt < maxAttempts {
                    let delay = Self.retryDelaySeconds(
                        attempt: attempt,
                        retryAfterHeader: httpResponse.value(forHTTPHeaderField: "Retry-After")
                    )
                    let formattedDelay = String(format: "%.1f", delay)
                    print(
                        "[GeminiImageService] HTTP \(httpResponse.statusCode) on attempt \(attempt)/\(maxAttempts); " +
                        "retrying in \(formattedDelay)s (\(serverMessage))"
                    )
                    try? await Task.sleep(nanoseconds: Self.nanoseconds(for: delay))
                    continue
                }

                if httpResponse.statusCode == 429 {
                    throw ServiceError.resourceExhausted(serverMessage)
                }

                let fallback = String(data: data, encoding: .utf8) ?? "No body"
                throw ServiceError.httpError(
                    httpResponse.statusCode,
                    serverMessage.isEmpty ? fallback : serverMessage
                )
            } catch let error as ServiceError {
                throw error
            } catch {
                if Task.isCancelled {
                    throw ServiceError.cancelled
                }
                lastTransportError = error
                guard Self.shouldRetryTransportError(error), attempt < maxAttempts else {
                    throw error
                }
                let delay = Self.retryDelaySeconds(attempt: attempt, retryAfterHeader: nil)
                let formattedDelay = String(format: "%.1f", delay)
                print(
                    "[GeminiImageService] transient transport error on attempt \(attempt)/\(maxAttempts): " +
                    "\(error.localizedDescription). Retrying in \(formattedDelay)s"
                )
                try? await Task.sleep(nanoseconds: Self.nanoseconds(for: delay))
            }
        }

        throw lastTransportError ?? ServiceError.invalidResponse
    }

    private func recordFailure(_ error: Error) {
        Self.consecutiveFailures += 1
        print("[GeminiImageService] failure (\(Self.consecutiveFailures) consecutive): \(error.localizedDescription)")
        if Self.consecutiveFailures >= Self.circuitBreakerThreshold {
            Self.circuitBreakerTripped = true
            print("[GeminiImageService] 🛑 CIRCUIT BREAKER TRIPPED after \(Self.consecutiveFailures) consecutive failures. All API calls blocked until app restart.")
        }
    }

    private static func shouldRetryHTTPStatus(_ statusCode: Int) -> Bool {
        statusCode == 429 || statusCode == 500 || statusCode == 502 || statusCode == 503 || statusCode == 504
    }

    private static func shouldRetryTransportError(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .timedOut,
             .networkConnectionLost,
             .cannotFindHost,
             .cannotConnectToHost,
             .dnsLookupFailed,
             .notConnectedToInternet,
             .resourceUnavailable:
            return true
        default:
            return false
        }
    }

    private static func retryDelaySeconds(attempt: Int, retryAfterHeader: String?) -> Double {
        if let retryAfterHeader,
           let parsed = Double(retryAfterHeader.trimmingCharacters(in: .whitespacesAndNewlines)),
           parsed > 0 {
            return parsed
        }
        let cappedExponent = min(attempt - 1, 4)
        let base = pow(2.0, Double(cappedExponent))
        let jitter = Double.random(in: 0.15...0.85)
        return min(base + jitter, 12.0)
    }

    private static func nanoseconds(for seconds: Double) -> UInt64 {
        UInt64(max(0, seconds) * 1_000_000_000)
    }

    private static func serverMessage(from data: Data) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = json["error"] as? [String: Any],
           let message = error["message"] as? String {
            return message.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return (String(data: data, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Turnaround Generation

@available(macOS 26.0, *)
extension GeminiImageService {

    /// Prompt templates for generating character turnaround views.
    struct TurnaroundPrompts {
        static func prompt(for angle: AngleView, characterName _: String, style: String = "") -> String {
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
            Generate a full-body turnaround illustration of the exact same character shown in the reference image, in \(angleDesc). \
            The character should be standing in a neutral A-pose with arms slightly away from the body. \
            Use a clean white or transparent background. \
            Do not mention any character names or internal labels. \
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
        static func prompt(for partType: PartType, characterName _: String, angle _: AngleView) -> String {
            let partName = partType.rawValue
                .replacingOccurrences(of: "Left", with: " (left)")
                .replacingOccurrences(of: "Right", with: " (right)")

            return """
            Extract and isolate the \(partName) from this character illustration. \
            Output ONLY the isolated body part on a completely transparent background. \
            Do not mention any character names or internal labels. \
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

        static func prompt(for expression: String, characterName _: String) -> String {
            """
            Generate the face of the exact same character from the reference image showing a \(expression) expression. \
            Match the exact same art style, proportions, and details as the reference image. \
            Do not mention any character names or internal labels. \
            Show only the head and face area on a transparent background. \
            The expression should be clear and exaggerated enough for animation readability.
            """
        }
    }

    /// Prompt templates for generating viseme (mouth shape) variants.
    struct VisemePrompts {
        static func prompt(for viseme: PrestonBlairViseme, characterName _: String) -> String {
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
            Generate just the mouth area of the exact same character from the reference image showing the \(viseme.label) viseme shape: \(shapeDesc). \
            Match the exact same art style as the reference image. \
            Do not mention any character names or internal labels. \
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

/// Result of a `GeminiBatchService.cancel(...)` invocation.
///
/// `state` reflects the local metadata state after the cancel attempt.
/// `cancelError` is non-nil when the Google side of the cancel failed —
/// metadata was still saved so the UI can decide whether to retry, but
/// the batch may still be running remotely. Callers should surface this
/// to the user instead of silently treating it as a clean cancel.
@available(macOS 26.0, *)
struct GeminiBatchCancelResult {
    var state: String
    var cancelError: String?

    var didCancelRemotely: Bool {
        cancelError == nil && state == "JOB_STATE_CANCELLED"
    }
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

    /// Cancel a batch on Google's side. Wraps the Python helper's `cancel`
    /// subcommand, which calls `client.batches.cancel(name:)` and rewrites
    /// local metadata to `JOB_STATE_CANCELLED`.
    ///
    /// The call is safe to invoke on an already-terminal batch — the helper
    /// detects the terminal state and returns success without re-calling
    /// Google, so the UI can always surface "Cancel" without pre-checking.
    func cancel(
        metadataPath: URL,
        apiKey: String,
        reason: String = "User cancelled from app"
    ) async throws -> GeminiBatchCancelResult {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BatchError.missingAPIKey
        }

        let scriptURL = try batchScriptURL()
        let pythonURL = try pythonExecutableURL()

        let output = try await runProcess(
            executableURL: pythonURL,
            arguments: [
                scriptURL.path,
                "cancel",
                "--metadata", metadataPath.path,
                "--reason", reason,
            ],
            apiKey: apiKey
        )

        guard let data = output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BatchError.invalidResponse(output)
        }

        let state = json["state"] as? String ?? "JOB_STATE_CANCELLED"
        let cancelError = json["cancel_error"] as? String
        return GeminiBatchCancelResult(
            state: state,
            cancelError: cancelError
        )
    }

    private func batchScriptURL() throws -> URL {
        // Prefer the copy bundled in the AnimateUI resource bundle (added via
        // Package.swift .copy).
        //
        // IMPORTANT: use `SafeBundle.module` — the SPM-auto-generated
        // `Bundle.module` raises `fatalError` when the resource bundle
        // cannot be located, which crashed the app on batch submit
        // (2026-04-16 crash in `_assertionFailure` via
        // `GeminiBatchService.batchScriptURL()` → `Bundle.module.unsafeMutableAddressor`).
        if let moduleBundled = SafeBundle.module?
            .url(forResource: "gemini_inspiration_batch", withExtension: "py"),
           fileManager.fileExists(atPath: moduleBundled.path) {
            return moduleBundled
        }

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
                    reference_paths: $0.referencePaths
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
