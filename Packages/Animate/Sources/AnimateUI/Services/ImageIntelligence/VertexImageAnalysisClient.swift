import Foundation

/// Vertex AI client for image analysis (visual analysis + embeddings).
/// Auth: delegates to `gcloud auth application-default print-access-token`.
@available(macOS 26.0, *)
actor VertexImageAnalysisClient {

    public enum VertexAnalysisError: Error, Sendable, Equatable {
        case gcloudNotFound
        case gcloudFailed(String)
        case missingConfig(String)
        case tokenFetchFailed(String)
        case httpError(Int, String)
        case invalidResponse
        case decodingError(String)

        public var localizedDescription: String {
            switch self {
            case .gcloudNotFound:
                return "gcloud CLI not found. Install: brew install --cask google-cloud-sdk"
            case .gcloudFailed(let msg):
                return "gcloud failed: \(msg)"
            case .missingConfig(let msg):
                return "Vertex not configured: \(msg)"
            case .tokenFetchFailed(let msg):
                return "Token fetch failed: \(msg)"
            case .httpError(let code, let msg):
                return "HTTP \(code): \(msg)"
            case .invalidResponse:
                return "Invalid response from Vertex API"
            case .decodingError(let msg):
                return "Failed to decode response: \(msg)"
            }
        }
    }

    public struct AnalysisConfig: Sendable, Codable {
        public let projectID: String
        public let region: String
        public let visualModelID: String
        public let embeddingModelID: String
        public let embeddingDimension: Int

        public init(
            projectID: String,
            region: String = "global",
            visualModelID: String = "gemini-3-flash-preview",
            embeddingModelID: String = "gemini-embedding-2",
            embeddingDimension: Int = 3072
        ) {
            self.projectID = projectID
            self.region = region
            self.visualModelID = visualModelID
            self.embeddingModelID = embeddingModelID
            self.embeddingDimension = embeddingDimension
        }
    }

    private let config: AnalysisConfig
    private let urlSession: URLSession
    private var cachedToken: String?
    private var tokenAcquiredAt: Date?
    private static let tokenValidSeconds: TimeInterval = 55 * 60

    public init(config: AnalysisConfig, urlSession: URLSession = .shared) {
        self.config = config
        self.urlSession = urlSession
    }

    // MARK: - Token

    private func accessToken(forceRefresh: Bool = false) async throws -> String {
        if !forceRefresh,
           let token = cachedToken,
           let acquired = tokenAcquiredAt,
           Date().timeIntervalSince(acquired) < Self.tokenValidSeconds {
            return token
        }
        let fresh = try await Self.fetchTokenViaGcloud()
        cachedToken = fresh
        tokenAcquiredAt = Date()
        return fresh
    }

    public func invalidateToken() {
        cachedToken = nil
        tokenAcquiredAt = nil
    }

    private static let gcloudPaths = [
        "/opt/homebrew/bin/gcloud",
        "/usr/local/bin/gcloud",
        "/usr/bin/gcloud",
    ]

    private static func fetchTokenViaGcloud() async throws -> String {
        let path = gcloudPaths.first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let binary = path else { throw VertexAnalysisError.gcloudNotFound }
        return try await withCheckedThrowingContinuation { cont in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: binary)
            proc.arguments = ["auth", "application-default", "print-access-token"]
            let stdout = Pipe()
            let stderr = Pipe()
            proc.standardOutput = stdout
            proc.standardError = stderr
            proc.environment = ProcessInfo.processInfo.environment
            proc.terminationHandler = { proc in
                let outData = (try? stdout.fileHandleForReading.readToEnd()) ?? Data()
                let errData = (try? stderr.fileHandleForReading.readToEnd()) ?? Data()
                let outStr = String(decoding: outData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                let errStr = String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                if proc.terminationStatus == 0, !outStr.isEmpty {
                    cont.resume(returning: outStr)
                } else {
                    cont.resume(throwing: VertexAnalysisError.gcloudFailed(errStr.isEmpty ? "exit \(proc.terminationStatus)" : errStr))
                }
            }
            try? proc.run()
        }
    }

    // MARK: - URLs

    private func generateContentURL(modelID: String) -> URL? {
        let host: String
        if config.region == "global" {
            host = "aiplatform.googleapis.com"
        } else {
            host = "\(config.region)-aiplatform.googleapis.com"
        }
        let path = "v1/projects/\(config.projectID)/locations/\(config.region)/publishers/google/models/\(modelID):generateContent"
        return URL(string: "https://\(host)/\(path)")
    }

    private func embedContentURL() -> URL? {
        let host: String
        if config.region == "global" {
            host = "aiplatform.googleapis.com"
        } else {
            host = "\(config.region)-aiplatform.googleapis.com"
        }
        let path = "v1beta1/projects/\(config.projectID)/locations/\(config.region)/publishers/google/models/\(config.embeddingModelID):embedContent"
        return URL(string: "https://\(host)/\(path)")
    }

    // MARK: - Visual Analysis

    public func analyzeImage(imageData: Data, mimeType: String = "image/png") async throws -> GeminiImageAnalysisService.VisualAnalysisResult {
        guard !config.projectID.isEmpty else {
            throw VertexAnalysisError.missingConfig("project ID is empty")
        }
        let token = try await accessToken()
        guard let url = generateContentURL(modelID: config.visualModelID) else {
            throw VertexAnalysisError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let base64Image = imageData.base64EncodedString()
        let parts: [[String: Any]] = [
            ["text": "Analyze this image and provide structured metadata."],
            ["inlineData": ["mimeType": mimeType, "data": base64Image]]
        ]
        let requestBody: [String: Any] = [
            "contents": [["parts": parts]],
            "generationConfig": [
                "responseMimeType": "application/json",
                "responseSchema": analysisSchema,
                "thinkingLevel": "low"
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        let (data, response) = try await urlSession.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw VertexAnalysisError.invalidResponse
        }

        if httpResponse.statusCode == 401 {
            invalidateToken()
            return try await analyzeImage(imageData: imageData, mimeType: mimeType)
        }

        if httpResponse.statusCode == 429 {
            throw GeminiImageAnalysisService.AnalysisError.rateLimited
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? "Unknown"
            throw VertexAnalysisError.httpError(httpResponse.statusCode, msg)
        }

        return try parseAnalysisResponse(data: data)
    }

    // MARK: - Embeddings

    public func embedImage(imageData: Data, mimeType: String = "image/png") async throws -> GeminiImageAnalysisService.EmbeddingResult {
        try await embedContent(imageBase64: imageData.base64EncodedString(), mimeType: mimeType)
    }

    public func embedText(_ text: String) async throws -> GeminiImageAnalysisService.EmbeddingResult {
        try await embedContent(text: text)
    }

    private func embedContent(text: String? = nil, imageBase64: String? = nil, mimeType: String? = nil) async throws -> GeminiImageAnalysisService.EmbeddingResult {
        guard !config.projectID.isEmpty else {
            throw VertexAnalysisError.missingConfig("project ID is empty")
        }
        let token = try await accessToken()
        guard let url = embedContentURL() else {
            throw VertexAnalysisError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var parts: [[String: Any]] = []
        if let text {
            parts.append(["text": text])
        }
        if let b64 = imageBase64, let mime = mimeType {
            parts.append(["inlineData": ["mimeType": mime, "data": b64]])
        }

        let requestBody: [String: Any] = [
            "model": "models/\(config.embeddingModelID)",
            "content": ["parts": parts]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        let (data, response) = try await urlSession.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw VertexAnalysisError.invalidResponse
        }

        if httpResponse.statusCode == 401 {
            invalidateToken()
            return try await embedContent(text: text, imageBase64: imageBase64, mimeType: mimeType)
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? "Unknown"
            throw VertexAnalysisError.httpError(httpResponse.statusCode, msg)
        }

        return try parseEmbeddingResponse(data: data)
    }

    // MARK: - Parsing

    private func parseAnalysisResponse(data: Data) throws -> GeminiImageAnalysisService.VisualAnalysisResult {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let first = candidates.first,
              let content = first["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]],
              let firstPart = parts.first,
              let text = firstPart["text"] as? String else {
            throw VertexAnalysisError.decodingError("Invalid response structure")
        }

        guard let responseData = text.data(using: .utf8),
              let responseJSON = try JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
            throw VertexAnalysisError.decodingError("Invalid JSON in response text")
        }

        return GeminiImageAnalysisService.VisualAnalysisResult(
            summary: responseJSON["summary"] as? String ?? "",
            shortCaption: responseJSON["short_caption"] as? String ?? "",
            longCaption: responseJSON["long_caption"] as? String ?? "",
            assetRoles: responseJSON["asset_roles"] as? [String] ?? [],
            entities: parseEntities(responseJSON["entities"] as? [[String: Any]] ?? []),
            scene: parseScene(responseJSON["scene"] as? [String: Any] ?? [:]),
            camera: parseCamera(responseJSON["camera"] as? [String: Any] ?? [:]),
            style: parseStyle(responseJSON["style"] as? [String: Any] ?? [:]),
            quality: parseQuality(responseJSON["quality"] as? [String: Any] ?? [:]),
            retrievalTags: responseJSON["retrieval_tags"] as? [String] ?? [],
            confidence: parseConfidence(responseJSON["confidence"] as? [String: Any] ?? [:]),
            rawJSON: text
        )
    }

    private func parseEmbeddingResponse(data: Data) throws -> GeminiImageAnalysisService.EmbeddingResult {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let embedding = json["embedding"] as? [String: Any],
              let values = embedding["values"] as? [Double] else {
            throw VertexAnalysisError.decodingError("Invalid embedding response structure")
        }
        let vector = values.map { Float($0) }
        return GeminiImageAnalysisService.EmbeddingResult(
            vector: vector,
            dimension: vector.count,
            modelID: config.embeddingModelID
        )
    }

    private func parseEntities(_ array: [[String: Any]]) -> [GeminiImageAnalysisService.VisualAnalysisResult.Entity] {
        array.compactMap { dict in
            guard let type = dict["type"] as? String else { return nil }
            return GeminiImageAnalysisService.VisualAnalysisResult.Entity(
                type: type,
                description: dict["description"] as? String ?? "",
                count: dict["count"] as? Int
            )
        }
    }

    private func parseScene(_ dict: [String: Any]) -> GeminiImageAnalysisService.VisualAnalysisResult.SceneInfo {
        GeminiImageAnalysisService.VisualAnalysisResult.SceneInfo(
            setting: dict["setting"] as? String,
            topography: dict["topography"] as? String,
            terrain: dict["terrain"] as? String,
            foliage: dict["foliage"] as? String,
            architecture: dict["architecture"] as? String,
            weather: dict["weather"] as? String,
            season: dict["season"] as? String,
            timeOfDay: dict["time_of_day"] as? String,
            lighting: dict["lighting"] as? String
        )
    }

    private func parseCamera(_ dict: [String: Any]) -> GeminiImageAnalysisService.VisualAnalysisResult.CameraInfo {
        GeminiImageAnalysisService.VisualAnalysisResult.CameraInfo(
            angle: dict["angle"] as? String,
            distance: dict["distance"] as? String,
            composition: dict["composition"] as? String,
            movement: dict["movement"] as? String
        )
    }

    private func parseStyle(_ dict: [String: Any]) -> GeminiImageAnalysisService.VisualAnalysisResult.StyleInfo {
        GeminiImageAnalysisService.VisualAnalysisResult.StyleInfo(
            palette: dict["palette"] as? String,
            mood: dict["mood"] as? String,
            genre: dict["genre"] as? String,
            artisticStyle: dict["artistic_style"] as? String
        )
    }

    private func parseQuality(_ dict: [String: Any]) -> GeminiImageAnalysisService.VisualAnalysisResult.QualityInfo {
        GeminiImageAnalysisService.VisualAnalysisResult.QualityInfo(
            overall: dict["overall"] as? String,
            sharpness: dict["sharpness"] as? String,
            exposure: dict["exposure"] as? String,
            colorAccuracy: dict["color_accuracy"] as? String,
            artifacts: dict["artifacts"] as? [String] ?? []
        )
    }

    private func parseConfidence(_ dict: [String: Any]) -> GeminiImageAnalysisService.VisualAnalysisResult.ConfidenceInfo {
        GeminiImageAnalysisService.VisualAnalysisResult.ConfidenceInfo(
            overall: dict["overall"] as? Double ?? 0.0,
            uncertainFields: dict["uncertain_fields"] as? [String] ?? []
        )
    }

    // MARK: - Schema

    private var analysisSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "summary": ["type": "string"],
                "short_caption": ["type": "string"],
                "long_caption": ["type": "string"],
                "asset_roles": ["type": "array", "items": ["type": "string"]],
                "entities": ["type": "array", "items": ["type": "object", "properties": [
                    "type": ["type": "string"],
                    "description": ["type": "string"],
                    "count": ["type": "integer"]
                ]]],
                "scene": ["type": "object", "properties": [
                    "setting": ["type": "string"],
                    "topography": ["type": "string"],
                    "terrain": ["type": "string"],
                    "foliage": ["type": "string"],
                    "architecture": ["type": "string"],
                    "weather": ["type": "string"],
                    "season": ["type": "string"],
                    "time_of_day": ["type": "string"],
                    "lighting": ["type": "string"]
                ]],
                "camera": ["type": "object", "properties": [
                    "angle": ["type": "string"],
                    "distance": ["type": "string"],
                    "composition": ["type": "string"],
                    "movement": ["type": "string"]
                ]],
                "style": ["type": "object", "properties": [
                    "palette": ["type": "string"],
                    "mood": ["type": "string"],
                    "genre": ["type": "string"],
                    "artistic_style": ["type": "string"]
                ]],
                "quality": ["type": "object", "properties": [
                    "overall": ["type": "string"],
                    "sharpness": ["type": "string"],
                    "exposure": ["type": "string"],
                    "color_accuracy": ["type": "string"],
                    "artifacts": ["type": "array", "items": ["type": "string"]]
                ]],
                "retrieval_tags": ["type": "array", "items": ["type": "string"]],
                "confidence": ["type": "object", "properties": [
                    "overall": ["type": "number"],
                    "uncertain_fields": ["type": "array", "items": ["type": "string"]]
                ]]
            ]
        ]
    }
}
