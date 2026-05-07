import Foundation

/// Meshy API client for 3D model generation from images.
///
/// Supports multi-image-to-3D and single-image-to-3D workflows.
/// Uses URLSession with no external dependencies.
@available(macOS 26.0, *)
@MainActor
final class MeshyService {

    // MARK: - Types

    enum ServiceError: LocalizedError {
        case noAPIKey
        case invalidResponse
        case httpError(Int, String)
        case taskFailed(String)
        case taskCancelled
        case decodingFailed(String)
        case downloadFailed(String)
        case rateLimitExceeded
        case networkError(String)

        var errorDescription: String? {
            switch self {
            case .noAPIKey:
                return "Meshy API key is not set."
            case .invalidResponse:
                return "Invalid response from Meshy API."
            case .httpError(let code, let msg):
                return "HTTP \(code): \(msg)"
            case .taskFailed(let message):
                return "Meshy generation failed: \(message)"
            case .taskCancelled:
                return "Generation was cancelled."
            case .decodingFailed(let detail):
                return "Failed to decode Meshy response: \(detail)"
            case .downloadFailed(let detail):
                return "Failed to download generated model: \(detail)"
            case .rateLimitExceeded:
                return "Too many API calls to Meshy. Wait a moment and try again."
            case .networkError(let detail):
                return "Network error: \(detail)"
            }
        }
    }

    struct GenerationResult {
        var taskID: String
        var status: MeshyTaskStatus
        var progress: Int
        var modelURLs: [String: String]?
        var thumbnailURL: String?
    }

    // MARK: - Properties

    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    var apiKey: String = ""

    // MARK: - Init

    init(apiKey: String = "") {
        self.apiKey = apiKey

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 300
        self.session = URLSession(configuration: config)

        self.decoder = JSONDecoder()
        self.decoder.keyDecodingStrategy = .convertFromSnakeCase
        self.decoder.dateDecodingStrategy = .iso8601

        self.encoder = JSONEncoder()
        self.encoder.keyEncodingStrategy = .convertToSnakeCase
    }

    // MARK: - Public API

    /// Create a multi-image-to-3D task. Returns the task ID immediately.
    func createMultiImageTo3D(request: MeshyMultiImageRequest) async throws -> String {
        guard !apiKey.isEmpty else { throw ServiceError.noAPIKey }

        let urlRequest = try buildRequest(
            endpoint: "/multi-image-to-3d",
            method: "POST",
            body: request
        )

        let (data, response) = try await session.data(for: urlRequest)
        try validateHTTPResponse(response, data: data)

        struct CreateResponse: Decodable {
            let result: String
        }

        do {
            let decoded = try decoder.decode(CreateResponse.self, from: data)
            return decoded.result
        } catch {
            throw ServiceError.decodingFailed(error.localizedDescription)
        }
    }

    /// Create a single-image-to-3D task. Returns the task ID immediately.
    func createImageTo3D(request: MeshyImageRequest) async throws -> String {
        guard !apiKey.isEmpty else { throw ServiceError.noAPIKey }

        let urlRequest = try buildRequest(
            endpoint: "/image-to-3d",
            method: "POST",
            body: request
        )

        let (data, response) = try await session.data(for: urlRequest)
        try validateHTTPResponse(response, data: data)

        struct CreateResponse: Decodable {
            let result: String
        }

        do {
            let decoded = try decoder.decode(CreateResponse.self, from: data)
            return decoded.result
        } catch {
            throw ServiceError.decodingFailed(error.localizedDescription)
        }
    }

    /// Get the current status of a task.
    func getTaskStatus(endpoint: String, taskID: String) async throws -> MeshyTaskResponse {
        guard !apiKey.isEmpty else { throw ServiceError.noAPIKey }

        let url = URL(string: "https://api.meshy.ai/openapi/v1\(endpoint)/\(taskID)")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        try validateHTTPResponse(response, data: data)

        do {
            return try decoder.decode(MeshyTaskResponse.self, from: data)
        } catch {
            throw ServiceError.decodingFailed(error.localizedDescription)
        }
    }

    /// Poll until the task completes or fails. Calls `onProgress` every poll interval.
    func pollUntilComplete(
        endpoint: String,
        taskID: String,
        pollInterval: TimeInterval = 5.0,
        onProgress: @escaping (MeshyTaskResponse) -> Void
    ) async throws -> MeshyTaskResponse {
        while true {
            let status = try await getTaskStatus(endpoint: endpoint, taskID: taskID)
            onProgress(status)

            switch status.status {
            case .succeeded:
                return status
            case .failed:
                let errorMessage = status.taskError?.message ?? "Unknown error"
                throw ServiceError.taskFailed(errorMessage)
            case .pending, .inProgress:
                try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
                if Task.isCancelled {
                    throw ServiceError.taskCancelled
                }
            }
        }
    }

    /// Download an asset from a URL to a local file.
    func downloadAsset(from url: URL, to destination: URL) async throws {
        let (data, response) = try await session.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ServiceError.downloadFailed("Invalid response type")
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw ServiceError.downloadFailed("HTTP \(httpResponse.statusCode)")
        }

        let dir = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try data.write(to: destination)
    }

    /// Check the current API key balance.
    func checkBalance() async throws -> Int {
        guard !apiKey.isEmpty else { throw ServiceError.noAPIKey }

        let url = URL(string: "https://api.meshy.ai/openapi/v1/balance")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        try validateHTTPResponse(response, data: data)

        struct BalanceResponse: Decodable {
            let balance: Int
        }

        do {
            let decoded = try decoder.decode(BalanceResponse.self, from: data)
            return decoded.balance
        } catch {
            throw ServiceError.decodingFailed(error.localizedDescription)
        }
    }

    // MARK: - Private Helpers

    private func buildRequest(endpoint: String, method: String, body: some Encodable) throws -> URLRequest {
        let url = URL(string: "https://api.meshy.ai/openapi/v1\(endpoint)")!
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(body)
        return request
    }

    private func validateHTTPResponse(_ response: URLResponse, data: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ServiceError.invalidResponse
        }

        let statusCode = httpResponse.statusCode

        if statusCode == 429 {
            throw ServiceError.rateLimitExceeded
        }

        guard (200..<300).contains(statusCode) else {
            let bodyString = String(data: data, encoding: .utf8) ?? ""
            throw ServiceError.httpError(statusCode, bodyString)
        }
    }
}
