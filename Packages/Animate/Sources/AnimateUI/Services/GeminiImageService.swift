import AppKit
import Foundation

@available(macOS 26.0, *)
private actor GeminiImageGenerationSerialGate {
    private var isRunning = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func enter() async {
        if !isRunning {
            isRunning = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func leave() {
        if waiters.isEmpty {
            isRunning = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

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
        case authFailureHalt(String)
        case referenceImageUnavailable(String)

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
            case .authFailureHalt(let msg):
                return "Gemini halted after 2 consecutive auth failures. Re-check the API key or Vertex credentials before retrying. (\(msg))"
            case .referenceImageUnavailable(let msg):
                return "Reference image unavailable: \(msg)"
            }
        }
    }

    struct GenerationRequest {
        var prompt: String
        var referenceImages: [ReferenceImage] = []
        var model: GeminiModel = .flash
        var aspectRatio: String = "3:4"
        var imageSize: String = "2K"
        /// Gemini image editing examples send the source media before the text
        /// edit instruction. Existing generation flows keep the historical
        /// prompt-first ordering unless an edit plan asks for media-first.
        var referenceImagesFirst: Bool = false
    }

    struct ReferenceImage {
        var data: String  // Base64-encoded
        var mimeType: String  // "image/png", "image/jpeg", "image/webp"
    }

    struct GenerationResult {
        var image: NSImage?
        var imageData: Data
        var textResponse: String?
    }

    private struct DecodedResponsePayload: Sendable {
        let imageData: Data
        let textResponse: String?
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

    /// Circuit breaker: after this many consecutive failures the breaker trips.
    /// It auto-resets after `circuitBreakerCooldownSeconds` of no new failures
    /// so a single 429 burst no longer locks Gemini for the whole session.
    static let circuitBreakerThreshold: Int = 10

    /// Sliding window after which a tripped breaker self-heals if no new
    /// failures have arrived. Matches Gary's `feedback_no_auto_api_calls` rule:
    /// we still refuse calls while tripped; we just don't require a restart.
    static let circuitBreakerCooldownSeconds: TimeInterval = 300

    private static var callCount: Int = 0
    private static var callCountResetTime: Date = Date()
    private static var consecutiveFailures: Int = 0
    private static var circuitBreakerTripped: Bool = false
    private static var lastFailureAt: Date?
    /// Honors the global CLAUDE.md "2 consecutive auth failures → halt" rule
    /// for automated API use. Incremented on 401/403, reset on any 200.
    /// At 2, `authFailureHalted` trips and blocks all calls until the user
    /// explicitly re-authenticates (see `acknowledgeAuthFailure()`).
    private static var consecutiveAuthFailures: Int = 0
    private static var authFailureHalted: Bool = false
    private static let authFailureHaltThreshold: Int = 2

    /// Vertex/AI Studio image generation capacity is one-at-a-time for Gary's account.
    /// Serialize every immediate image-generation request globally so Canvas, Places,
    /// Characters, and All Images append to one long queue instead of racing.
    private static let immediateGenerationGate = GeminiImageGenerationSerialGate()

    // MARK: - Properties

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 600
        return URLSession(configuration: config)
    }()

    private let baseURL = "https://generativelanguage.googleapis.com/v1beta/models"

    init() {}

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
    func generate(
        request: GenerationRequest,
        apiKey: String,
        includePreviewImage: Bool = false,
        backendOverride: ImageGenBackend? = nil
    ) async throws -> GenerationResult {
        let backend = backendOverride ?? ImageGenBackendStore.currentBackend()
        if backend == .aiStudio {
            guard !apiKey.isEmpty else { throw ServiceError.noAPIKey }
        }

        // Global CLAUDE.md rule: stop after 2 consecutive auth failures so a
        // bad key can't fan out into a blacklist incident. Only the user
        // clears this — it does NOT auto-reset on a cooldown.
        if Self.authFailureHalted {
            print("[GeminiImageService] 🚨 AUTH HALT — 2 consecutive 401/403. Blocking until user re-auth.")
            throw ServiceError.authFailureHalt("re-enter API key in Settings")
        }

        // Circuit breaker: if too many consecutive failures, refuse calls until
        // the sliding cooldown window elapses with no further failures.
        if Self.circuitBreakerTripped {
            if let last = Self.lastFailureAt,
               Date().timeIntervalSince(last) > Self.circuitBreakerCooldownSeconds {
                print("[GeminiImageService] ♻️ CIRCUIT BREAKER auto-reset after \(Int(Self.circuitBreakerCooldownSeconds))s cooldown. Allowing a probe call.")
                Self.circuitBreakerTripped = false
                Self.consecutiveFailures = 0
            } else {
                print("[GeminiImageService] 🛑 CIRCUIT BREAKER TRIPPED — all API calls blocked until cooldown expires.")
                throw ServiceError.rateLimitExceeded
            }
        }

        // Only one immediate image generation may be in-flight globally.
        await Self.immediateGenerationGate.enter()
        defer { Task { await Self.immediateGenerationGate.leave() } }

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

        // Start the Vertex attempt record before endpoint/auth resolution so
        // missing project IDs, gcloud/token failures, and malformed endpoint
        // setup are visible in the durable ledger too.
        let vertexAttemptID: UUID? = backend == .vertex
            ? AnimateStore.recordVertexImageGenerationAttemptStarted(
                model: request.model,
                imageSize: request.imageSize,
                aspectRatio: request.aspectRatio,
                referenceImageCount: request.referenceImages.count,
                isEditRequest: request.referenceImagesFirst
            )
            : nil

        do {
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
                let client = await VertexAIClientCache.shared.client(
                    projectID: settings.projectID,
                    region: settings.region
                )
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

            var urlRequest = URLRequest(url: url)
            urlRequest.httpMethod = "POST"
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            urlRequest.setValue(authHeaderValue, forHTTPHeaderField: authHeaderName)
            urlRequest.httpBody = try await Self.serializedRequestBody(for: request)
            let (data, httpResponse) = try await performRequestWithRetry(urlRequest, backend: backend)

            // Success — reset the failure counter and clear any prior trip.
            Self.consecutiveFailures = 0
            Self.circuitBreakerTripped = false
            Self.lastFailureAt = nil

            let payload = try await Self.decodeResponsePayload(from: data)
            let previewImage: NSImage?
            if includePreviewImage {
                guard let image = NSImage(data: payload.imageData) else {
                    throw ServiceError.imageDecodingFailed
                }
                previewImage = image
            } else {
                previewImage = nil
            }

            if backend == .vertex {
                if let vertexAttemptID {
                    AnimateStore.finishVertexImageGenerationAttempt(
                        vertexAttemptID,
                        status: .succeeded,
                        model: request.model,
                        imageSize: request.imageSize,
                        httpStatusCode: httpResponse.statusCode
                    )
                }
            }

            _ = httpResponse
            return GenerationResult(
                image: previewImage,
                imageData: payload.imageData,
                textResponse: payload.textResponse
            )
        } catch {
            if let vertexAttemptID {
                AnimateStore.finishVertexImageGenerationAttempt(
                    vertexAttemptID,
                    status: .failed,
                    model: request.model,
                    imageSize: request.imageSize,
                    errorMessage: error.localizedDescription
                )
            }
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

    /// NSCache of base64-encoded reference payloads keyed by path|mtime|size,
    /// so reusing the same reference across 10 generations costs one read+encode.
    private final class CachedReference {
        let data: String
        let mimeType: String
        init(data: String, mimeType: String) {
            self.data = data
            self.mimeType = mimeType
        }
    }

    nonisolated(unsafe) private static let referenceCache: NSCache<NSString, CachedReference> = {
        let cache = NSCache<NSString, CachedReference>()
        cache.totalCostLimit = 50 * 1024 * 1024  // ~50 MB
        return cache
    }()
    /// Files at or under this size go straight to the wire untouched (PNG
    /// stays lossless). Anything larger is re-encoded as a high-quality JPEG
    /// at the SAME pixel dimensions — a 4K screenshot collapses from ~15 MB
    /// PNG to ~3 MB JPEG with no perceptible quality loss, so continuity
    /// edits keep their full source resolution.
    nonisolated private static let maxInlineReferenceImageBytes = 6 * 1024 * 1024
    /// Hard ceiling on a single inline reference (raw bytes before base64).
    /// Gemini caps total request inline data around 20 MB; with base64
    /// inflation (×1.33) this leaves room for multi-reference edits.
    nonisolated private static let absoluteInlineReferenceCeilingBytes = 14 * 1024 * 1024
    /// Visually-lossless JPEG quality used for the high-quality re-encode
    /// path. 0.95 is the practical equivalent of "JPEGli quality 90"
    /// (visually lossless per JPEGli docs); we're using the system encoder
    /// because libjxl/cjpegli isn't available on Gary's machine. Dropping
    /// to 0.85 only kicks in if the 0.95 output still exceeds the ceiling.
    nonisolated private static let referenceJPEGQualityHigh: CGFloat = 0.95
    nonisolated private static let referenceJPEGQualityFallback: CGFloat = 0.85

    /// Create a required ReferenceImage from a file URL.
    ///
    /// Use this for edit-source images where silently dropping the image would
    /// turn a continuity-preserving edit into a prompt-only generation. Files
    /// larger than the inline cap are re-encoded as high-quality JPEG at the
    /// original pixel dimensions (no downscaling) so we never silently lose
    /// continuity AND never lose resolution.
    nonisolated static func requiredReferenceImage(from url: URL) throws -> ReferenceImage {
        let standardizedURL = url.standardizedFileURL
        let path = standardizedURL.path
        let attrs: [FileAttributeKey: Any]
        do {
            attrs = try FileManager.default.attributesOfItem(atPath: path)
        } catch {
            throw ServiceError.referenceImageUnavailable(
                "Could not inspect \(path): \(error.localizedDescription)"
            )
        }
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
        guard size > 0 else {
            throw ServiceError.referenceImageUnavailable("\(path) is empty or missing.")
        }

        let cacheKey = NSString(string: "\(path)|\(mtime)|\(size)")
        if let hit = referenceCache.object(forKey: cacheKey) {
            return ReferenceImage(data: hit.data, mimeType: hit.mimeType)
        }

        // Small enough to inline as-is — fast path keeps PNGs lossless.
        if size <= Self.maxInlineReferenceImageBytes {
            let data: Data
            do {
                data = try Data(contentsOf: standardizedURL)
            } catch {
                throw ServiceError.referenceImageUnavailable(
                    "Could not read \(path): \(error.localizedDescription)"
                )
            }

            let ext = standardizedURL.pathExtension.lowercased()
            let mimeType: String
            switch ext {
            case "png": mimeType = "image/png"
            case "jpg", "jpeg": mimeType = "image/jpeg"
            case "webp": mimeType = "image/webp"
            default: mimeType = "image/png"
            }

            let encoded = data.base64EncodedString()
            referenceCache.setObject(
                CachedReference(data: encoded, mimeType: mimeType),
                forKey: cacheKey,
                cost: encoded.utf8.count
            )
            return ReferenceImage(data: encoded, mimeType: mimeType)
        }

        // Oversized — re-encode as high-quality JPEG at ORIGINAL dimensions.
        // No downscaling: a 4K identity reference stays 4K so Gemini can
        // still see facial detail / signage / textures.
        guard let recoded = Self.fullResJPEGData(at: standardizedURL) else {
            throw ServiceError.referenceImageUnavailable(
                "\(path) is \(String(format: "%.1f", Double(size) / 1_048_576.0)) MB and could not be re-encoded for inline Gemini reference. Try re-exporting it as JPEG."
            )
        }

        let encoded = recoded.base64EncodedString()
        referenceCache.setObject(
            CachedReference(data: encoded, mimeType: "image/jpeg"),
            forKey: cacheKey,
            cost: encoded.utf8.count
        )
        print("[GeminiImageService] Re-encoded oversized reference at full resolution (\(String(format: "%.1f", Double(size) / 1_048_576.0)) MB → \(String(format: "%.1f", Double(recoded.count) / 1_048_576.0)) MB JPEG): \(path)")
        return ReferenceImage(data: encoded, mimeType: "image/jpeg")
    }

    /// Decode `url` and re-encode as JPEG at the same pixel dimensions.
    /// Tries the high-quality factor first (visually lossless); falls back to
    /// a slightly lower quality only if the high-quality output still exceeds
    /// the absolute inline ceiling. Returns nil if AppKit can't decode.
    nonisolated private static func fullResJPEGData(at url: URL) -> Data? {
        guard let image = NSImage(contentsOf: url) else { return nil }
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }

        if let highQ = bitmap.representation(
            using: .jpeg,
            properties: [.compressionFactor: Self.referenceJPEGQualityHigh]
        ), highQ.count <= Self.absoluteInlineReferenceCeilingBytes {
            return highQ
        }

        return bitmap.representation(
            using: .jpeg,
            properties: [.compressionFactor: Self.referenceJPEGQualityFallback]
        )
    }

    /// Create an optional ReferenceImage from a file URL.
    ///
    /// Optional context references may be skipped when unavailable, but the
    /// reason is logged. Edit-source images should use `requiredReferenceImage`.
    nonisolated static func referenceImage(from url: URL) -> ReferenceImage? {
        do {
            return try requiredReferenceImage(from: url)
        } catch {
            print("[GeminiImageService] Skipping optional inline reference image: \(url.path) — \(error.localizedDescription)")
            return nil
        }
    }

    /// Save a generated image to disk as PNG.
    static func saveImage(_ data: Data, to directory: URL, filename: String) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent(filename)
        try data.write(to: fileURL)
        return fileURL
    }

    private static func serializedRequestBody(for request: GenerationRequest) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            var parts: [[String: Any]] = []
            let referenceParts: [[String: Any]] = request.referenceImages.map { ref in
                [
                    "inlineData": [
                        "mimeType": ref.mimeType,
                        "data": ref.data,
                    ]
                ]
            }

            if request.referenceImagesFirst {
                parts.append(contentsOf: referenceParts)
                parts.append(["text": request.prompt])
            } else {
                parts.append(["text": request.prompt])
                parts.append(contentsOf: referenceParts)
            }

            let requestBody: [String: Any] = [
                "contents": [
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

            return try JSONSerialization.data(withJSONObject: requestBody)
        }.value
    }

    private static func decodeResponsePayload(from data: Data) async throws -> DecodedResponsePayload {
        try await Task.detached(priority: .userInitiated) {
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let candidates = json["candidates"] as? [[String: Any]],
                  let firstCandidate = candidates.first,
                  let content = firstCandidate["content"] as? [String: Any],
                  let responseParts = content["parts"] as? [[String: Any]]
            else {
                throw ServiceError.invalidResponse
            }

            var imageData: Data?
            var textResponse: String?

            for part in responseParts {
                if let text = part["text"] as? String {
                    textResponse = text
                } else if let inlineData = part["inlineData"] as? [String: Any],
                          let base64String = inlineData["data"] as? String {
                    guard let decoded = Data(base64Encoded: base64String) else {
                        throw ServiceError.imageDecodingFailed
                    }
                    imageData = decoded
                }
            }

            guard let imageData else {
                throw ServiceError.noImageInResponse
            }

            return DecodedResponsePayload(imageData: imageData, textResponse: textResponse)
        }.value
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
                let (data, response) = try await Self.session.data(for: urlRequest)
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw ServiceError.invalidResponse
                }

                if httpResponse.statusCode == 200 {
                    // Any success clears both fault counters. A good call erases
                    // recent transient 429/503 history AND resets the auth-halt
                    // counter so a later 401 starts a fresh streak.
                    Self.consecutiveAuthFailures = 0
                    return (data, httpResponse)
                }

                // 401/403 feed the global 2-strike auth halt separately from the
                // general circuit breaker so one bad key is stopped in two
                // calls, not ten.
                if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                    Self.consecutiveAuthFailures += 1
                    print(
                        "[GeminiImageService] HTTP \(httpResponse.statusCode) auth failure " +
                        "(\(Self.consecutiveAuthFailures)/\(Self.authFailureHaltThreshold) consecutive)"
                    )
                    if Self.consecutiveAuthFailures >= Self.authFailureHaltThreshold {
                        Self.authFailureHalted = true
                        let msg = Self.serverMessage(from: data)
                        throw ServiceError.authFailureHalt(
                            msg.isEmpty ? "HTTP \(httpResponse.statusCode)" : msg
                        )
                    }
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
        let now = Date()
        // Sliding-window reset: if no failures for the cooldown period, treat
        // this as a fresh failure streak instead of piling onto an ancient one.
        if let last = Self.lastFailureAt,
           now.timeIntervalSince(last) > Self.circuitBreakerCooldownSeconds {
            Self.consecutiveFailures = 0
        }
        Self.lastFailureAt = now
        Self.consecutiveFailures += 1
        print("[GeminiImageService] failure (\(Self.consecutiveFailures) consecutive): \(error.localizedDescription)")
        if Self.consecutiveFailures >= Self.circuitBreakerThreshold {
            Self.circuitBreakerTripped = true
            print("[GeminiImageService] 🛑 CIRCUIT BREAKER TRIPPED after \(Self.consecutiveFailures) consecutive failures. Auto-reset in \(Int(Self.circuitBreakerCooldownSeconds))s of quiet.")
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

    /// Call after the user saves a new Gemini API key / re-signs into Vertex
    /// so the service can issue calls again. Also clears the general breaker
    /// so a fresh auth probe isn't gated by old 429 history.
    static func acknowledgeAuthFailureResolved() {
        consecutiveAuthFailures = 0
        authFailureHalted = false
        circuitBreakerTripped = false
        consecutiveFailures = 0
        lastFailureAt = nil
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
