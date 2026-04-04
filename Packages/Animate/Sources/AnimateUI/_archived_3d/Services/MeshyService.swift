import Foundation

@available(macOS 26.0, *)
final class MeshyService: Sendable {
    static let baseURL = "https://api.meshy.ai/openapi/v1"

    let apiKey: String

    init(apiKey: String) {
        self.apiKey = apiKey
    }

    // MARK: - Error

    enum ServiceError: LocalizedError {
        case noAPIKey
        case invalidResponse
        case httpError(Int, String)
        case taskFailed(String)
        case cancelled

        var errorDescription: String? {
            switch self {
            case .noAPIKey: "No Meshy API key configured."
            case .invalidResponse: "Invalid response from Meshy API."
            case .httpError(let code, let msg): "Meshy API error \(code): \(msg)"
            case .taskFailed(let msg): "3D generation failed: \(msg)"
            case .cancelled: "Generation was cancelled."
            }
        }
    }

    // MARK: - Request Builders

    func buildCreateTaskRequest<T: Encodable>(endpoint: String, body: T) throws -> URLRequest {
        let url = URL(string: "\(Self.baseURL)/\(endpoint)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        request.httpBody = try encoder.encode(body)

        return request
    }

    func buildGetTaskRequest(endpoint: String, taskID: String) -> URLRequest {
        let url = URL(string: "\(Self.baseURL)/\(endpoint)/\(taskID)")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        return request
    }

    func buildBalanceRequest() -> URLRequest {
        let url = URL(string: "\(Self.baseURL)/balance")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        return request
    }

    // MARK: - API Calls

    func createMultiImageTo3D(_ request: MeshyMultiImageRequest) async throws -> String {
        guard !apiKey.isEmpty else { throw ServiceError.noAPIKey }
        let urlRequest = try buildCreateTaskRequest(endpoint: "multi-image-to-3d", body: request)
        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        try validateHTTPResponse(response, data: data)
        let result = try JSONDecoder().decode(MeshyCreateTaskResponse.self, from: data)
        return result.result
    }

    func createImageTo3D(_ request: MeshyImageRequest) async throws -> String {
        guard !apiKey.isEmpty else { throw ServiceError.noAPIKey }
        let urlRequest = try buildCreateTaskRequest(endpoint: "image-to-3d", body: request)
        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        try validateHTTPResponse(response, data: data)
        let result = try JSONDecoder().decode(MeshyCreateTaskResponse.self, from: data)
        return result.result
    }

    func getTaskStatus(endpoint: String, taskID: String) async throws -> MeshyTaskResponse {
        let urlRequest = buildGetTaskRequest(endpoint: endpoint, taskID: taskID)
        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        try validateHTTPResponse(response, data: data)
        return try JSONDecoder().decode(MeshyTaskResponse.self, from: data)
    }

    func pollUntilComplete(
        endpoint: String,
        taskID: String,
        onProgress: @Sendable (MeshyTaskResponse) -> Void
    ) async throws -> MeshyTaskResponse {
        while true {
            let task = try await getTaskStatus(endpoint: endpoint, taskID: taskID)
            onProgress(task)

            switch task.status {
            case .succeeded:
                return task
            case .failed:
                throw ServiceError.taskFailed(task.taskError?.message ?? "Unknown error")
            case .canceled:
                throw ServiceError.cancelled
            case .pending, .inProgress:
                try await Task.sleep(for: .seconds(5))
            }
        }
    }

    func checkBalance() async throws -> Int {
        guard !apiKey.isEmpty else { throw ServiceError.noAPIKey }
        let urlRequest = buildBalanceRequest()
        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        try validateHTTPResponse(response, data: data)
        let result = try JSONDecoder().decode(MeshyBalanceResponse.self, from: data)
        return result.balance
    }

    func downloadAsset(from remoteURL: URL, to destination: URL) async throws {
        let (tempURL, response) = try await URLSession.shared.download(from: remoteURL)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw ServiceError.invalidResponse
        }
        let directory = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: tempURL, to: destination)
    }

    // MARK: - Helpers

    private func validateHTTPResponse(_ response: URLResponse, data: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ServiceError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "No body"
            throw ServiceError.httpError(httpResponse.statusCode, body)
        }
    }
}
