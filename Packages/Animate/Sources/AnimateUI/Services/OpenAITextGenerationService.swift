import Foundation

@available(macOS 26.0, *)
struct OpenAITextGenerationService: Sendable {
    enum ServiceError: LocalizedError {
        case noAPIKey
        case invalidResponse
        case emptyResponse
        case requestFailed(statusCode: Int, message: String)

        var errorDescription: String? {
            switch self {
            case .noAPIKey:
                return "OpenAI API key is not configured. Add one in API Settings."
            case .invalidResponse:
                return "OpenAI returned an invalid text response."
            case .emptyResponse:
                return "OpenAI returned an empty prompt response."
            case let .requestFailed(statusCode, message):
                return "OpenAI prompt request failed (HTTP \(statusCode)): \(message)"
            }
        }
    }

    private struct RequestBody: Encodable {
        var model: String
        var input: String
    }

    private struct ResponseBody: Decodable {
        var output_text: String?
        var output: [OutputItem]?

        struct OutputItem: Decodable {
            var content: [ContentItem]?
        }

        struct ContentItem: Decodable {
            var text: String?
        }
    }

    private struct ErrorResponse: Decodable {
        var error: APIError?

        struct APIError: Decodable {
            var message: String?
        }
    }

    func generateText(
        instruction: String,
        apiKey: String,
        model: String = "gpt-5.2"
    ) async throws -> String {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { throw ServiceError.noAPIKey }

        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(trimmedKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(RequestBody(model: model, input: instruction))

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ServiceError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode(ErrorResponse.self, from: data).error?.message)
                ?? String(data: data, encoding: .utf8)
                ?? "Unknown error"
            throw ServiceError.requestFailed(statusCode: http.statusCode, message: message)
        }

        let decoded = try JSONDecoder().decode(ResponseBody.self, from: data)
        let outputText = decoded.output_text
            ?? decoded.output?.compactMap { item in
                item.content?.compactMap(\.text).joined(separator: "\n")
            }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        let trimmed = outputText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { throw ServiceError.emptyResponse }
        return trimmed
    }
}
