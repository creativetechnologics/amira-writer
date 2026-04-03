import Foundation

/// Integration with Tencent HY-Motion-1.0 for text-to-motion generation
/// Uses the HuggingFace Space Gradio API as the inference backend
@available(macOS 26.0, *)
final class HunyuanMotionService: Sendable {

    static let defaultSpaceURL = "https://tencent-hy-motion-1-0.hf.space"

    let spaceURL: String

    init(spaceURL: String = HunyuanMotionService.defaultSpaceURL) {
        self.spaceURL = spaceURL
    }

    // MARK: - Error

    enum ServiceError: LocalizedError {
        case invalidResponse
        case httpError(Int, String)
        case generationFailed(String)
        case noOutputFile
        case spaceUnavailable

        var errorDescription: String? {
            switch self {
            case .invalidResponse: "Invalid response from HY-Motion service."
            case .httpError(let code, let msg): "HY-Motion error \(code): \(msg)"
            case .generationFailed(let msg): "Motion generation failed: \(msg)"
            case .noOutputFile: "No motion file in response."
            case .spaceUnavailable: "HY-Motion Space is currently unavailable. It may be queued or offline."
            }
        }
    }

    // MARK: - Request / Response

    struct MotionRequest: Sendable {
        var prompt: String
        var durationSeconds: Double = 4.0  // 1-12 seconds
        var seed: Int = -1  // -1 for random
        var cfgScale: Double = 7.5  // text adherence strength
        var numVariations: Int = 1

        /// Validate and clamp parameters to acceptable ranges
        var validated: MotionRequest {
            var copy = self
            copy.durationSeconds = max(1, min(12, durationSeconds))
            copy.cfgScale = max(1, min(20, cfgScale))
            copy.numVariations = max(1, min(4, numVariations))
            return copy
        }
    }

    struct MotionResult: Sendable {
        let prompt: String
        let durationSeconds: Double
        let seed: Int
        let fbxFileURL: URL?  // Remote URL to download FBX
        let visualizationHTML: String?  // HTML preview if available
    }

    // MARK: - Motion Categories

    /// Supported motion categories for prompt guidance
    enum MotionCategory: String, CaseIterable, Sendable {
        case locomotion = "Locomotion"
        case sports = "Sports"
        case fitness = "Fitness"
        case dailyActivities = "Daily Activities"
        case socialInteractions = "Social Interactions"
        case performance = "Performance"

        var examplePrompts: [String] {
            switch self {
            case .locomotion:
                ["A person walks forward confidently",
                 "A person runs and then stops suddenly",
                 "A person jumps over an obstacle"]
            case .sports:
                ["A person throws a ball overhand",
                 "A person swings a bat",
                 "A person kicks a ball"]
            case .fitness:
                ["A person does jumping jacks",
                 "A person stretches their arms overhead",
                 "A person does a squat"]
            case .dailyActivities:
                ["A person sits down in a chair",
                 "A person picks up an object from the ground",
                 "A person opens a door and walks through"]
            case .socialInteractions:
                ["A person waves hello",
                 "A person shakes hands",
                 "A person gestures while talking"]
            case .performance:
                ["A person bows to an audience",
                 "A person conducts an orchestra",
                 "A person dances gracefully"]
            }
        }
    }

    // MARK: - Prompt Enhancement

    /// Maps acting beat actions from the animation system to motion-friendly prompts
    static func motionPrompt(
        for action: String,
        characterName: String,
        emotion: String? = nil,
        intensity: Double = 0.5
    ) -> String {
        let intensityWord: String
        switch intensity {
        case 0..<0.3: intensityWord = "subtly"
        case 0.3..<0.6: intensityWord = ""
        case 0.6...0.8: intensityWord = "energetically"
        default: intensityWord = "dramatically"
        }

        let emotionClause = emotion.map { " with a \($0) expression" } ?? ""

        // Map common acting beat actions to motion descriptions
        let motionDescription: String
        switch action.lowercased() {
        case "walk", "walking":
            motionDescription = "A person walks forward \(intensityWord)".trimmingCharacters(in: .whitespaces)
        case "run", "running":
            motionDescription = "A person runs forward \(intensityWord)".trimmingCharacters(in: .whitespaces)
        case "stand", "idle":
            motionDescription = "A person stands in place, shifting weight slightly"
        case "sit", "sitting":
            motionDescription = "A person sits down"
        case "speak", "talking", "talk":
            motionDescription = "A person \(intensityWord) gestures while speaking\(emotionClause)".trimmingCharacters(in: .whitespaces)
        case "sing", "singing":
            motionDescription = "A person \(intensityWord) sways and gestures while singing\(emotionClause)".trimmingCharacters(in: .whitespaces)
        case "listen", "listening":
            motionDescription = "A person stands attentively, nodding occasionally"
        case "gesture", "gesturing":
            motionDescription = "A person \(intensityWord) gestures with their hands\(emotionClause)".trimmingCharacters(in: .whitespaces)
        case "react", "reacting":
            motionDescription = "A person \(intensityWord) reacts\(emotionClause)".trimmingCharacters(in: .whitespaces)
        case "present", "presenting":
            motionDescription = "A person presents something, extending one arm forward \(intensityWord)".trimmingCharacters(in: .whitespaces)
        case "turn", "turning":
            motionDescription = "A person turns around"
        case "bow", "bowing":
            motionDescription = "A person bows \(intensityWord)".trimmingCharacters(in: .whitespaces)
        case "dance", "dancing":
            motionDescription = "A person dances \(intensityWord)\(emotionClause)".trimmingCharacters(in: .whitespaces)
        default:
            motionDescription = "A person \(action) \(intensityWord)\(emotionClause)".trimmingCharacters(in: .whitespaces)
        }

        return motionDescription
    }

    // MARK: - API Calls

    /// Submit a motion generation request to the HuggingFace Space
    func generate(_ request: MotionRequest) async throws -> MotionResult {
        let validated = request.validated

        // Build the Gradio API request
        // Gradio Spaces use /api/predict or /call/<fn_index>
        guard let url = URL(string: "\(spaceURL)/api/predict") else {
            throw ServiceError.invalidResponse
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.timeoutInterval = 300  // Motion generation can take minutes

        // Gradio API format: {"data": [param1, param2, ...]}
        let body: [String: Any] = [
            "data": [
                validated.prompt,
                validated.durationSeconds,
                validated.seed,
                validated.cfgScale,
                validated.numVariations
            ]
        ]

        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ServiceError.invalidResponse
        }

        // Handle queue/unavailable states
        if httpResponse.statusCode == 503 {
            throw ServiceError.spaceUnavailable
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let responseBody = String(data: data, encoding: .utf8) ?? "No body"
            throw ServiceError.httpError(httpResponse.statusCode, responseBody)
        }

        // Parse Gradio response
        // Format: {"data": [output1, output2, ...]}
        // File outputs come as: {"name": "filename.fbx", "data": "base64...", "is_file": true}
        // or as URL paths: "/file=<path>"
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let outputData = json["data"] as? [Any] else {
            throw ServiceError.invalidResponse
        }

        // Extract FBX file URL from response
        var fbxURL: URL?
        var htmlPreview: String?

        for output in outputData {
            if let fileDict = output as? [String: Any] {
                if let fileName = fileDict["name"] as? String, fileName.hasSuffix(".fbx") {
                    if let filePath = fileDict["url"] as? String {
                        fbxURL = URL(string: "\(spaceURL)/file=\(filePath)")
                    } else {
                        fbxURL = URL(string: "\(spaceURL)/file=\(fileName)")
                    }
                }
            } else if let htmlString = output as? String, htmlString.contains("<html") || htmlString.contains("<iframe") {
                htmlPreview = htmlString
            }
        }

        return MotionResult(
            prompt: validated.prompt,
            durationSeconds: validated.durationSeconds,
            seed: validated.seed,
            fbxFileURL: fbxURL,
            visualizationHTML: htmlPreview
        )
    }

    /// Download a generated FBX file to a local destination
    func downloadMotion(from remoteURL: URL, to destination: URL) async throws {
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

    /// Generate motion and download FBX in one call
    func generateAndDownload(
        request: MotionRequest,
        destinationDirectory: URL,
        onProgress: @Sendable (String) -> Void
    ) async throws -> URL {
        onProgress("Submitting motion generation request...")
        let result = try await generate(request)

        guard let fbxURL = result.fbxFileURL else {
            throw ServiceError.noOutputFile
        }

        onProgress("Downloading FBX file...")
        let fileName = "motion-\(Int(Date().timeIntervalSince1970)).fbx"
        let destination = destinationDirectory.appendingPathComponent(fileName)
        try await downloadMotion(from: fbxURL, to: destination)

        // Save metadata alongside
        let metadataURL = destination.deletingPathExtension().appendingPathExtension("json")
        let metadata: [String: Any] = [
            "prompt": result.prompt,
            "durationSeconds": result.durationSeconds,
            "seed": result.seed,
            "sourceURL": fbxURL.absoluteString,
            "downloadedAt": ISO8601DateFormatter().string(from: Date()),
            "provider": "HY-Motion-1.0 via HuggingFace Space"
        ]
        if let data = try? JSONSerialization.data(withJSONObject: metadata, options: .prettyPrinted) {
            try? data.write(to: metadataURL)
        }

        onProgress("Motion downloaded: \(fileName)")
        return destination
    }
}
