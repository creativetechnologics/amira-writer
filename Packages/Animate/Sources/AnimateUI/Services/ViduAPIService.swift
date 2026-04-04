import Foundation

@available(macOS 26.0, *)
final class ViduAPIService: Sendable {
    let apiKey: String
    private let baseURL = "https://api.vidu.com/ent/v2"

    init(apiKey: String) { self.apiKey = apiKey }

    struct ViduTask: Codable, Sendable {
        var id: String
        var state: String
        var progress: Int?
        var resultURL: String?
        var errorMessage: String?

        enum CodingKeys: String, CodingKey {
            case id, state, progress
            case resultURL = "result_url"
            case errorMessage = "error_message"
        }
    }

    func createKeyFrameTask(
        firstFrameImageData: Data,
        lastFrameImageData: Data,
        prompt: String,
        durationSeconds: Double,
        aspectRatio: String
    ) async throws -> ViduTask {
        guard !apiKey.isEmpty else { throw ViduError.noAPIKey }
        let body: [String: Any] = [
            "type": "keyframe",
            "input": [
                "first_frame": "data:image/png;base64,\(firstFrameImageData.base64EncodedString())",
                "last_frame": "data:image/png;base64,\(lastFrameImageData.base64EncodedString())",
                "prompt": prompt,
                "duration": durationSeconds,
                "aspect_ratio": aspectRatio
            ]
        ]
        var request = URLRequest(url: URL(string: "\(baseURL)/tasks")!)
        request.httpMethod = "POST"
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw ViduError.requestFailed(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return try JSONDecoder().decode(ViduTask.self, from: data)
    }

    func getTaskStatus(taskID: String) async throws -> ViduTask {
        guard !apiKey.isEmpty else { throw ViduError.noAPIKey }
        var request = URLRequest(url: URL(string: "\(baseURL)/tasks/\(taskID)")!)
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw ViduError.requestFailed(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return try JSONDecoder().decode(ViduTask.self, from: data)
    }

    func downloadResult(resultURL: String, to destination: URL) async throws {
        guard let url = URL(string: resultURL) else { throw ViduError.invalidResponse }
        let (tempURL, _) = try await URLSession.shared.download(from: url)
        try FileManager.default.moveItem(at: tempURL, to: destination)
    }

    func pollUntilComplete(taskID: String, progressHandler: @escaping @Sendable (Int) -> Void) async throws -> ViduTask {
        var task = try await getTaskStatus(taskID: taskID)
        while task.state == "pending" || task.state == "processing" {
            try await Task.sleep(for: .seconds(5))
            task = try await getTaskStatus(taskID: taskID)
            if let progress = task.progress { progressHandler(progress) }
        }
        guard task.state == "success" else {
            throw ViduError.taskFailed(task.errorMessage ?? "Unknown error")
        }
        return task
    }

    enum ViduError: LocalizedError {
        case noAPIKey
        case taskFailed(String)
        case requestFailed(statusCode: Int)
        case invalidResponse
        var errorDescription: String? {
            switch self {
            case .noAPIKey: return "No Vidu API key configured."
            case .taskFailed(let msg): return "Vidu generation failed: \(msg)"
            case .requestFailed(let code): return "Vidu request failed (status \(code))."
            case .invalidResponse: return "Invalid response from Vidu API."
            }
        }
    }
}