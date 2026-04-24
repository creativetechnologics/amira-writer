import Foundation

/// Service for analyzing images using the Gemini Developer API.
/// Uses URLSession REST calls, NOT the existing GeminiImageService.
@available(macOS 26.0, *)
public actor GeminiImageAnalysisService {

    public struct AnalysisConfig: Sendable {
        public let apiKey: String
        public let visualModelID: String
        public let embeddingModelID: String
        public let embeddingDimension: Int
        public let thinkingLevel: ThinkingLevel
        public let baseURL: String

        public init(
            apiKey: String,
            visualModelID: String = "gemini-3-flash-preview",
            embeddingModelID: String = "gemini-embedding-2",
            embeddingDimension: Int = 3072,
            thinkingLevel: ThinkingLevel = .low,
            baseURL: String = "https://generativelanguage.googleapis.com"
        ) {
            self.apiKey = apiKey
            self.visualModelID = visualModelID
            self.embeddingModelID = embeddingModelID
            self.embeddingDimension = embeddingDimension
            self.thinkingLevel = thinkingLevel
            self.baseURL = baseURL
        }
    }

    public enum ThinkingLevel: String, Sendable {
        case minimal
        case low
    }

    public struct VisualAnalysisResult: Sendable {
        public let summary: String
        public let shortCaption: String
        public let longCaption: String
        public let assetRoles: [String]
        public let entities: [Entity]
        public let scene: SceneInfo
        public let camera: CameraInfo
        public let style: StyleInfo
        public let quality: QualityInfo
        public let retrievalTags: [String]
        public let confidence: ConfidenceInfo
        public let rawJSON: String

        public struct Entity: Sendable {
            public let type: String
            public let description: String
            public let count: Int?
        }

        public struct SceneInfo: Sendable {
            public let setting: String?
            public let topography: String?
            public let terrain: String?
            public let foliage: String?
            public let architecture: String?
            public let weather: String?
            public let season: String?
            public let timeOfDay: String?
            public let lighting: String?
        }

        public struct CameraInfo: Sendable {
            public let angle: String?
            public let distance: String?
            public let composition: String?
            public let movement: String?
        }

        public struct StyleInfo: Sendable {
            public let palette: String?
            public let mood: String?
            public let genre: String?
            public let artisticStyle: String?
        }

        public struct QualityInfo: Sendable {
            public let overall: String?
            public let sharpness: String?
            public let exposure: String?
            public let colorAccuracy: String?
            public let artifacts: [String]
        }

        public struct ConfidenceInfo: Sendable {
            public let overall: Double
            public let uncertainFields: [String]
        }
    }

    public struct EmbeddingResult: Sendable {
        public let vector: [Float]
        public let dimension: Int
        public let modelID: String
    }

    public enum AnalysisError: Error, Sendable, Equatable {
        case invalidURL
        case invalidResponse
        case apiError(String)
        case decodingError(String)
        case noAPIKey
        case imageTooLarge
        case rateLimited
        case invalidImage
    }

    private let config: AnalysisConfig
    private let urlSession: URLSession

    public init(config: AnalysisConfig, urlSession: URLSession = .shared) {
        self.config = config
        self.urlSession = urlSession
    }

    // MARK: - Visual Analysis

    public func analyzeImage(imageData: Data, mimeType: String = "image/png") async throws -> VisualAnalysisResult {
        guard !config.apiKey.isEmpty else {
            throw AnalysisError.noAPIKey
        }

        let base64Image = imageData.base64EncodedString()

        let requestBody: [String: Any] = [
            "contents": [
                [
                    "parts": [
                        [
                            "text": "Analyze this image and provide structured metadata."
                        ],
                        [
                            "inline_data": [
                                "mime_type": mimeType,
                                "data": base64Image
                            ]
                        ]
                    ]
                ]
            ],
            "generationConfig": [
                "responseMimeType": "application/json",
                "responseSchema": analysisSchema,
                "thinkingLevel": config.thinkingLevel.rawValue
            ]
        ]

        let url = try makeURL(modelID: config.visualModelID)
        let request = try makeRequest(url: url, body: requestBody)

        let (data, response) = try await urlSession.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AnalysisError.invalidResponse
        }

        if httpResponse.statusCode == 429 {
            throw AnalysisError.rateLimited
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let errorText = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw AnalysisError.apiError("HTTP \(httpResponse.statusCode): \(errorText)")
        }

        return try parseAnalysisResponse(data: data)
    }

    // MARK: - Embeddings

    public func embedImage(imageData: Data, mimeType: String = "image/png") async throws -> EmbeddingResult {
        guard !config.apiKey.isEmpty else {
            throw AnalysisError.noAPIKey
        }

        let base64Image = imageData.base64EncodedString()

        let requestBody: [String: Any] = [
            "model": "models/\(config.embeddingModelID)",
            "content": [
                "parts": [
                    [
                        "inline_data": [
                            "mime_type": mimeType,
                            "data": base64Image
                        ]
                    ]
                ]
            ]
        ]

        let url = try makeURLEmbedding()
        let request = try makeRequest(url: url, body: requestBody)

        let (data, response) = try await urlSession.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AnalysisError.invalidResponse
        }

        if httpResponse.statusCode == 429 {
            throw AnalysisError.rateLimited
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let errorText = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw AnalysisError.apiError("HTTP \(httpResponse.statusCode): \(errorText)")
        }

        return try parseEmbeddingResponse(data: data)
    }

    public func embedText(_ text: String) async throws -> EmbeddingResult {
        guard !config.apiKey.isEmpty else {
            throw AnalysisError.noAPIKey
        }

        let requestBody: [String: Any] = [
            "model": "models/\(config.embeddingModelID)",
            "content": [
                "parts": [
                    [
                        "text": text
                    ]
                ]
            ]
        ]

        let url = try makeURLEmbedding()
        let request = try makeRequest(url: url, body: requestBody)

        let (data, response) = try await urlSession.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AnalysisError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let errorText = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw AnalysisError.apiError("HTTP \(httpResponse.statusCode): \(errorText)")
        }

        return try parseEmbeddingResponse(data: data)
    }

    // MARK: - Private Helpers

    private func makeURL(modelID: String) throws -> URL {
        guard let url = URL(string: "\(config.baseURL)/v1beta/models/\(modelID):generateContent?key=\(config.apiKey)") else {
            throw AnalysisError.invalidURL
        }
        return url
    }

    private func makeURLEmbedding() throws -> URL {
        guard let url = URL(string: "\(config.baseURL)/v1beta/models/\(config.embeddingModelID):embedContent?key=\(config.apiKey)") else {
            throw AnalysisError.invalidURL
        }
        return url
    }

    private func makeRequest(url: URL, body: [String: Any]) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private func parseAnalysisResponse(data: Data) throws -> VisualAnalysisResult {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let first = candidates.first,
              let content = first["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]],
              let firstPart = parts.first,
              let text = firstPart["text"] as? String else {
            throw AnalysisError.decodingError("Invalid response structure")
        }

        guard let responseData = text.data(using: .utf8),
              let responseJSON = try JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
            throw AnalysisError.decodingError("Invalid JSON in response text")
        }

        return VisualAnalysisResult(
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

    private func parseEmbeddingResponse(data: Data) throws -> EmbeddingResult {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let embedding = json["embedding"] as? [String: Any],
              let values = embedding["values"] as? [Double] else {
            throw AnalysisError.decodingError("Invalid embedding response structure")
        }

        let vector = values.map { Float($0) }

        return EmbeddingResult(
            vector: vector,
            dimension: vector.count,
            modelID: config.embeddingModelID
        )
    }

    // MARK: - Parsers

    private func parseEntities(_ array: [[String: Any]]) -> [VisualAnalysisResult.Entity] {
        array.compactMap { dict in
            guard let type = dict["type"] as? String else { return nil }
            return VisualAnalysisResult.Entity(
                type: type,
                description: dict["description"] as? String ?? "",
                count: dict["count"] as? Int
            )
        }
    }

    private func parseScene(_ dict: [String: Any]) -> VisualAnalysisResult.SceneInfo {
        VisualAnalysisResult.SceneInfo(
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

    private func parseCamera(_ dict: [String: Any]) -> VisualAnalysisResult.CameraInfo {
        VisualAnalysisResult.CameraInfo(
            angle: dict["angle"] as? String,
            distance: dict["distance"] as? String,
            composition: dict["composition"] as? String,
            movement: dict["movement"] as? String
        )
    }

    private func parseStyle(_ dict: [String: Any]) -> VisualAnalysisResult.StyleInfo {
        VisualAnalysisResult.StyleInfo(
            palette: dict["palette"] as? String,
            mood: dict["mood"] as? String,
            genre: dict["genre"] as? String,
            artisticStyle: dict["artistic_style"] as? String
        )
    }

    private func parseQuality(_ dict: [String: Any]) -> VisualAnalysisResult.QualityInfo {
        VisualAnalysisResult.QualityInfo(
            overall: dict["overall"] as? String,
            sharpness: dict["sharpness"] as? String,
            exposure: dict["exposure"] as? String,
            colorAccuracy: dict["color_accuracy"] as? String,
            artifacts: dict["artifacts"] as? [String] ?? []
        )
    }

    private func parseConfidence(_ dict: [String: Any]) -> VisualAnalysisResult.ConfidenceInfo {
        VisualAnalysisResult.ConfidenceInfo(
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
                "asset_roles": [
                    "type": "array",
                    "items": ["type": "string"]
                ],
                "entities": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": [
                            "type": ["type": "string"],
                            "description": ["type": "string"],
                            "count": ["type": "integer"]
                        ]
                    ]
                ],
                "scene": [
                    "type": "object",
                    "properties": [
                        "setting": ["type": "string"],
                        "topography": ["type": "string"],
                        "terrain": ["type": "string"],
                        "foliage": ["type": "string"],
                        "architecture": ["type": "string"],
                        "weather": ["type": "string"],
                        "season": ["type": "string"],
                        "time_of_day": ["type": "string"],
                        "lighting": ["type": "string"]
                    ]
                ],
                "camera": [
                    "type": "object",
                    "properties": [
                        "angle": ["type": "string"],
                        "distance": ["type": "string"],
                        "composition": ["type": "string"],
                        "movement": ["type": "string"]
                    ]
                ],
                "style": [
                    "type": "object",
                    "properties": [
                        "palette": ["type": "string"],
                        "mood": ["type": "string"],
                        "genre": ["type": "string"],
                        "artistic_style": ["type": "string"]
                    ]
                ],
                "quality": [
                    "type": "object",
                    "properties": [
                        "overall": ["type": "string"],
                        "sharpness": ["type": "string"],
                        "exposure": ["type": "string"],
                        "color_accuracy": ["type": "string"],
                        "artifacts": [
                            "type": "array",
                            "items": ["type": "string"]
                        ]
                    ]
                ],
                "retrieval_tags": [
                    "type": "array",
                    "items": ["type": "string"]
                ],
                "confidence": [
                    "type": "object",
                    "properties": [
                        "overall": ["type": "number"],
                        "uncertain_fields": [
                            "type": "array",
                            "items": ["type": "string"]
                        ]
                    ]
                ]
            ]
        ]
    }
}