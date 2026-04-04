import Foundation

@available(macOS 26.0, *)
final class ViduAPIService: Sendable {
    let apiKey: String
    private let baseURL = "https://api.vidu.com/ent/v2"

    init(apiKey: String) { self.apiKey = apiKey }

    // MARK: - Models

    struct ViduTask: Codable, Sendable {
        var id: String
        var state: String         // created, pending, processing, success, failed
        var model: String?
        var createdAt: String?
        var videoURL: String?
        var coverImageURL: String?
        var errorMessage: String?

        enum CodingKeys: String, CodingKey {
            case id, state, model
            case createdAt = "created_at"
            case videoURL = "video_url"
            case coverImageURL = "cover_image_url"
            case errorMessage = "err_msg"
        }
    }

    struct CreateTaskResponse: Codable, Sendable {
        var taskId: String
        var state: String

        enum CodingKeys: String, CodingKey {
            case taskId = "task_id"
            case state
        }
    }

    // MARK: - Create Start-End-to-Video Task

    /// Create a Vidu start-end-to-video generation task.
    /// - Parameters:
    ///   - startImageURL: Public URL of the first frame image
    ///   - endImageURL: Public URL of the last frame image
    ///   - prompt: Text description of the motion (max 1500 chars)
    ///   - duration: 4 or 8 seconds
    ///   - resolution: "720p" or "1080p" (8s only supports 720p)
    ///   - movementAmplitude: "auto", "small", "medium", or "large"
    func createStartEndTask(
        startImageURL: String,
        endImageURL: String,
        prompt: String,
        duration: Int = 4,
        resolution: String = "720p",
        movementAmplitude: String = "auto"
    ) async throws -> CreateTaskResponse {
        guard !apiKey.isEmpty else { throw ViduError.noAPIKey }

        let body: [String: Any] = [
            "model": "vidu2.0",
            "images": [startImageURL, endImageURL],
            "prompt": String(prompt.prefix(1500)),
            "duration": duration,
            "resolution": resolution,
            "movement_amplitude": movementAmplitude
        ]

        var request = URLRequest(url: URL(string: "\(baseURL)/start-end2video")!)
        request.httpMethod = "POST"
        request.addValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ViduError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw ViduError.requestFailed(statusCode: http.statusCode, message: errorBody)
        }

        return try JSONDecoder().decode(CreateTaskResponse.self, from: data)
    }

    // MARK: - Poll Task Status

    /// Get the current status of a generation task.
    func getTaskStatus(taskID: String) async throws -> ViduTask {
        guard !apiKey.isEmpty else { throw ViduError.noAPIKey }

        var request = URLRequest(url: URL(string: "\(baseURL)/generations/\(taskID)")!)
        request.httpMethod = "GET"
        request.addValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw ViduError.requestFailed(
                statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0,
                message: String(data: data, encoding: .utf8) ?? ""
            )
        }

        return try JSONDecoder().decode(ViduTask.self, from: data)
    }

    // MARK: - Download Result

    /// Download the generated video to a local file.
    func downloadResult(videoURL: String, to destination: URL) async throws {
        guard let url = URL(string: videoURL) else { throw ViduError.invalidResponse }
        let (tempURL, _) = try await URLSession.shared.download(from: url)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: tempURL, to: destination)
    }

    // MARK: - Poll Until Complete

    /// Poll a task until it reaches success or failed state.
    /// - Parameters:
    ///   - taskID: The task ID from createStartEndTask
    ///   - interval: Polling interval in seconds (default 5)
    ///   - progressHandler: Called with task state on each poll
    func pollUntilComplete(
        taskID: String,
        interval: Double = 5,
        progressHandler: @escaping @Sendable (String) -> Void
    ) async throws -> ViduTask {
        while true {
            let task = try await getTaskStatus(taskID: taskID)
            progressHandler(task.state)

            switch task.state {
            case "success":
                return task
            case "failed":
                throw ViduError.taskFailed(task.errorMessage ?? "Generation failed")
            case "created", "pending", "processing":
                try await Task.sleep(for: .seconds(interval))
            default:
                try await Task.sleep(for: .seconds(interval))
            }
        }
    }

    // MARK: - Errors

    enum ViduError: LocalizedError {
        case noAPIKey
        case taskFailed(String)
        case requestFailed(statusCode: Int, message: String)
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .noAPIKey:
                return "No Vidu API key configured. Add one in Settings."
            case .taskFailed(let msg):
                return "Vidu generation failed: \(msg)"
            case .requestFailed(let code, let msg):
                return "Vidu request failed (HTTP \(code)): \(msg)"
            case .invalidResponse:
                return "Invalid response from Vidu API."
            }
        }
    }
}
