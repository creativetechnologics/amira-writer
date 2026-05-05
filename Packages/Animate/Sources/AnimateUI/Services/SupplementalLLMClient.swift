import Foundation

@available(macOS 26.0, *)
enum SupplementalLLMProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    case miniMax = "minimax"
    case deepSeek = "deepseek"
    case vertexGemini = "vertex_gemini"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .miniMax: "MiniMax"
        case .deepSeek: "DeepSeek"
        case .vertexGemini: "Vertex Gemini"
        }
    }

    var endpoint: URL {
        switch self {
        case .miniMax:
            URL(string: "https://api.minimax.io/v1/chat/completions")!
        case .deepSeek:
            URL(string: "https://api.deepseek.com/chat/completions")!
        case .vertexGemini:
            URL(string: "https://aiplatform.googleapis.com")!
        }
    }

    var defaultModel: String {
        switch self {
        case .miniMax: "MiniMax-M2.7"
        case .deepSeek: "deepseek-v4-flash"
        case .vertexGemini: "gemini-3-pro-preview"
        }
    }

    var knownModels: [String] {
        switch self {
        case .miniMax:
            ["MiniMax-M2.7", "MiniMax-M2.5"]
        case .deepSeek:
            ["deepseek-v4-flash", "deepseek-v4-pro"]
        case .vertexGemini:
            ["gemini-3-pro-preview", "gemini-3-flash-preview", "gemini-3.1-flash-image-preview", "gemini-3-pro-image-preview"]
        }
    }

    var apiKeyFieldName: String {
        switch self {
        case .miniMax: "miniMaxAPIKey"
        case .deepSeek: "deepSeekAPIKey"
        case .vertexGemini: "vertexADC"
        }
    }
}

@available(macOS 26.0, *)
struct SupplementalLLMConfiguration: Sendable {
    var provider: SupplementalLLMProvider
    var apiKey: String
    var model: String

    var providerName: String { provider.displayName }
}

@available(macOS 26.0, *)
struct SupplementalLLMClient: Sendable {
    var configuration: SupplementalLLMConfiguration

    func complete(
        systemPrompt: String,
        userPrompt: String,
        temperature: Double = 0.1,
        maxTokens: Int = 12_000,
        jsonMode: Bool = true
    ) async throws -> String {
        if configuration.provider == .vertexGemini {
            let apiKey = configuration.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if !apiKey.isEmpty {
                return try await completeWithGeminiAPI(
                    systemPrompt: systemPrompt,
                    userPrompt: userPrompt,
                    temperature: temperature,
                    maxTokens: maxTokens,
                    jsonMode: jsonMode,
                    apiKey: apiKey
                )
            }
            return try await completeWithVertexGemini(
                systemPrompt: systemPrompt,
                userPrompt: userPrompt,
                temperature: temperature,
                maxTokens: maxTokens,
                jsonMode: jsonMode
            )
        }

        let apiKey = configuration.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else {
            throw SupplementalLLMError.missingAPIKey(provider: configuration.provider.displayName)
        }

        var body: [String: Any] = [
            "model": configuration.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? configuration.provider.defaultModel
                : configuration.model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userPrompt]
            ],
            "temperature": temperature,
            "max_tokens": maxTokens,
            "stream": false
        ]

        if jsonMode {
            body["response_format"] = ["type": "json_object"]
        }
        if configuration.provider == .deepSeek {
            body["thinking"] = ["type": "disabled"]
        }

        var request = URLRequest(url: configuration.provider.endpoint)
        request.httpMethod = "POST"
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SupplementalLLMError.invalidResponse(provider: configuration.provider.displayName)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw SupplementalLLMError.requestFailed(
                provider: configuration.provider.displayName,
                statusCode: http.statusCode,
                body: String(data: data, encoding: .utf8) ?? ""
            )
        }

        let decoded = try JSONDecoder().decode(SupplementalChatCompletionResponse.self, from: data)
        guard let content = decoded.choices?.first?.message?.content?.trimmingCharacters(in: .whitespacesAndNewlines),
              !content.isEmpty else {
            throw SupplementalLLMError.invalidResponse(provider: configuration.provider.displayName)
        }
        return content
    }

    private func completeWithGeminiAPI(
        systemPrompt: String,
        userPrompt: String,
        temperature: Double,
        maxTokens: Int,
        jsonMode: Bool,
        apiKey: String
    ) async throws -> String {
        let model = configuration.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? configuration.provider.defaultModel
            : configuration.model
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent") else {
            throw SupplementalLLMError.invalidResponse(provider: "Gemini API")
        }
        var generationConfig: [String: Any] = [
            "temperature": temperature,
            "maxOutputTokens": maxTokens
        ]
        if jsonMode {
            generationConfig["responseMimeType"] = "application/json"
        }
        let body: [String: Any] = [
            "systemInstruction": [
                "parts": [
                    ["text": systemPrompt]
                ]
            ],
            "contents": [
                [
                    "role": "user",
                    "parts": [
                        ["text": userPrompt]
                    ]
                ]
            ],
            "generationConfig": generationConfig
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SupplementalLLMError.invalidResponse(provider: "Gemini API")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw SupplementalLLMError.requestFailed(
                provider: "Gemini API",
                statusCode: http.statusCode,
                body: String(data: data, encoding: .utf8) ?? ""
            )
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else {
            throw SupplementalLLMError.invalidResponse(provider: "Gemini API")
        }
        let text = parts.compactMap { $0["text"] as? String }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw SupplementalLLMError.invalidResponse(provider: "Gemini API")
        }
        return text
    }

    private func completeWithVertexGemini(
        systemPrompt: String,
        userPrompt: String,
        temperature: Double,
        maxTokens: Int,
        jsonMode: Bool
    ) async throws -> String {
        let settings = ImageGenBackendStore.currentVertexSettings()
        guard !settings.projectID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SupplementalLLMError.missingAPIKey(provider: "Vertex project ID")
        }
        let client = await VertexAIClientCache.shared.client(
            projectID: settings.projectID,
            region: settings.region
        )
        let model = configuration.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? configuration.provider.defaultModel
            : configuration.model
        guard let url = client.generateContentURL(modelID: model) else {
            throw SupplementalLLMError.invalidResponse(provider: configuration.provider.displayName)
        }
        let token = try await client.accessToken()
        var generationConfig: [String: Any] = [
            "temperature": temperature,
            "maxOutputTokens": maxTokens
        ]
        if jsonMode {
            generationConfig["responseMimeType"] = "application/json"
        }
        let body: [String: Any] = [
            "systemInstruction": [
                "parts": [
                    ["text": systemPrompt]
                ]
            ],
            "contents": [
                [
                    "role": "user",
                    "parts": [
                        ["text": userPrompt]
                    ]
                ]
            ],
            "generationConfig": generationConfig
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SupplementalLLMError.invalidResponse(provider: configuration.provider.displayName)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw SupplementalLLMError.requestFailed(
                provider: configuration.provider.displayName,
                statusCode: http.statusCode,
                body: String(data: data, encoding: .utf8) ?? ""
            )
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else {
            throw SupplementalLLMError.invalidResponse(provider: configuration.provider.displayName)
        }
        let text = parts.compactMap { $0["text"] as? String }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw SupplementalLLMError.invalidResponse(provider: configuration.provider.displayName)
        }
        return text
    }
}

private struct SupplementalChatCompletionResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            let content: String?
        }
        let message: Message?
    }

    let choices: [Choice]?
}

@available(macOS 26.0, *)
enum SupplementalLLMError: LocalizedError {
    case missingAPIKey(provider: String)
    case invalidResponse(provider: String)
    case requestFailed(provider: String, statusCode: Int, body: String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey(let provider):
            "\(provider) API key is not configured."
        case .invalidResponse(let provider):
            "Invalid response from \(provider)."
        case .requestFailed(let provider, let statusCode, let body):
            "\(provider) request failed (HTTP \(statusCode)): \(body.prefix(500))"
        }
    }
}
