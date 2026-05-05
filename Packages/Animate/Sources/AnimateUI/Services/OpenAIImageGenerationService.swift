import Foundation

@available(macOS 26.0, *)
enum OpenAIImageQuality: String, CaseIterable, Identifiable, Codable, Sendable {
    case low
    case medium
    case high

    var id: String { rawValue }
    var displayName: String { rawValue.capitalized }
}

@available(macOS 26.0, *)
struct OpenAIImageGenerationResult: Sendable {
    var imageData: Data
    var revisedPrompt: String?
    var responseText: String?
}

@available(macOS 26.0, *)
struct OpenAIImageGenerationService: Sendable {
    enum ServiceError: LocalizedError {
        case noAPIKey
        case invalidResponse
        case noImageReturned
        case requestFailed(statusCode: Int, message: String)
        case imageDownloadFailed

        var errorDescription: String? {
            switch self {
            case .noAPIKey:
                return "OpenAI API key is not configured. Add one in API Settings."
            case .invalidResponse:
                return "OpenAI returned an invalid image response."
            case .noImageReturned:
                return "OpenAI did not return image data."
            case let .requestFailed(statusCode, message):
                return "OpenAI image request failed (HTTP \(statusCode)): \(message)"
            case .imageDownloadFailed:
                return "OpenAI returned an image URL, but the app could not download it."
            }
        }
    }

    private struct ImageGenerationRequest: Encodable {
        var model: String
        var prompt: String
        var size: String
        var quality: String
        var n: Int
    }

    private struct ImageResponse: Decodable {
        var data: [ImageData]
        var usage: Usage?

        struct ImageData: Decodable {
            var b64_json: String?
            var url: String?
            var revised_prompt: String?
        }

        struct Usage: Decodable {
            var total_tokens: Int?
            var input_tokens: Int?
            var output_tokens: Int?
        }
    }

    private struct ErrorResponse: Decodable {
        var error: APIError?

        struct APIError: Decodable {
            var message: String?
            var type: String?
            var code: String?
        }
    }

    func generate(
        prompt: String,
        referenceImageURLs: [URL],
        apiKey: String,
        model: String = "gpt-image-2",
        quality: OpenAIImageQuality = .low,
        size: String = "1536x1024"
    ) async throws -> OpenAIImageGenerationResult {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { throw ServiceError.noAPIKey }

        let response: ImageResponse
        if referenceImageURLs.isEmpty {
            response = try await generateFromText(
                prompt: prompt,
                apiKey: trimmedKey,
                model: model,
                quality: quality,
                size: size
            )
        } else {
            response = try await editWithReferences(
                prompt: prompt,
                referenceImageURLs: referenceImageURLs,
                apiKey: trimmedKey,
                model: model,
                quality: quality,
                size: size
            )
        }

        guard let first = response.data.first else { throw ServiceError.noImageReturned }
        let imageData: Data
        if let b64 = first.b64_json,
           let decoded = Data(base64Encoded: b64) {
            imageData = decoded
        } else if let rawURL = first.url,
                  let url = URL(string: rawURL) {
            let downloaded = try await URLSession.shared.data(from: url).0
            guard !downloaded.isEmpty else { throw ServiceError.imageDownloadFailed }
            imageData = downloaded
        } else {
            throw ServiceError.noImageReturned
        }

        let usageText: String?
        if let usage = response.usage {
            usageText = [
                first.revised_prompt.map { "revised_prompt: \($0)" },
                usage.total_tokens.map { "total_tokens: \($0)" },
                usage.input_tokens.map { "input_tokens: \($0)" },
                usage.output_tokens.map { "output_tokens: \($0)" }
            ]
            .compactMap { $0 }
            .joined(separator: "\n")
        } else {
            usageText = first.revised_prompt.map { "revised_prompt: \($0)" }
        }

        return OpenAIImageGenerationResult(
            imageData: imageData,
            revisedPrompt: first.revised_prompt,
            responseText: usageText
        )
    }

    private func generateFromText(
        prompt: String,
        apiKey: String,
        model: String,
        quality: OpenAIImageQuality,
        size: String
    ) async throws -> ImageResponse {
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/images/generations")!)
        request.timeoutInterval = 300
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            ImageGenerationRequest(
                model: model,
                prompt: prompt,
                size: size,
                quality: quality.rawValue,
                n: 1
            )
        )
        return try await send(request)
    }

    private func editWithReferences(
        prompt: String,
        referenceImageURLs: [URL],
        apiKey: String,
        model: String,
        quality: OpenAIImageQuality,
        size: String
    ) async throws -> ImageResponse {
        let boundary = "OpenAIImageBoundary-\(UUID().uuidString)"
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/images/edits")!)
        request.timeoutInterval = 300
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        appendFormField(name: "model", value: model, boundary: boundary, body: &body)
        appendFormField(name: "prompt", value: prompt, boundary: boundary, body: &body)
        appendFormField(name: "size", value: size, boundary: boundary, body: &body)
        appendFormField(name: "quality", value: quality.rawValue, boundary: boundary, body: &body)
        appendFormField(name: "n", value: "1", boundary: boundary, body: &body)

        for url in referenceImageURLs {
            let data = try Data(contentsOf: url)
            appendFileField(
                name: "image[]",
                filename: url.lastPathComponent,
                mimeType: mimeType(for: url),
                data: data,
                boundary: boundary,
                body: &body
            )
        }

        body.appendString("--\(boundary)--\r\n")
        request.httpBody = body
        return try await send(request)
    }

    private func send(_ request: URLRequest) async throws -> ImageResponse {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ServiceError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode(ErrorResponse.self, from: data).error?.message)
                ?? String(data: data, encoding: .utf8)
                ?? "Unknown error"
            throw ServiceError.requestFailed(statusCode: http.statusCode, message: message)
        }
        return try JSONDecoder().decode(ImageResponse.self, from: data)
    }

    private func appendFormField(name: String, value: String, boundary: String, body: inout Data) {
        body.appendString("--\(boundary)\r\n")
        body.appendString("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
        body.appendString("\(value)\r\n")
    }

    private func appendFileField(
        name: String,
        filename: String,
        mimeType: String,
        data: Data,
        boundary: String,
        body: inout Data
    ) {
        body.appendString("--\(boundary)\r\n")
        body.appendString("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n")
        body.appendString("Content-Type: \(mimeType)\r\n\r\n")
        body.append(data)
        body.appendString("\r\n")
    }

    private func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg":
            return "image/jpeg"
        case "webp":
            return "image/webp"
        default:
            return "image/png"
        }
    }
}

private extension Data {
    mutating func appendString(_ string: String) {
        append(Data(string.utf8))
    }
}
