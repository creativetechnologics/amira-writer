import Foundation

@available(macOS 26.0, *)
final class MiniMaxPromptService: Sendable {
    let apiKey: String
    private let baseURL = "https://api.minimaxi.chat/v1/text/chatcompletion_v2"
    private let model = "MiniMax-Text-01"

    init(apiKey: String) { self.apiKey = apiKey }

    func generateSDPrompt(
        placeName: String,
        category: String,
        notes: String,
        sceneContext: String? = nil
    ) async throws -> String {
        guard !apiKey.isEmpty else { throw MiniMaxError.noAPIKey }

        let systemPrompt = "You are an expert at writing Stable Diffusion prompts. Generate a detailed, comma-separated prompt for generating a background plate image. Focus on: composition, lighting, atmosphere, materials, color palette. Do NOT include character descriptions. Output ONLY the prompt text, nothing else."

        var userContent = "Location: \(placeName)\nCategory: \(category)\nNotes: \(notes)"
        if let ctx = sceneContext { userContent += "\nScene context: \(ctx)" }
        userContent += "\n\nGenerate a detailed Stable Diffusion prompt for this location as a background plate."

        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userContent]
            ],
            "max_tokens": 500,
            "temperature": 0.7
        ]

        var request = URLRequest(url: URL(string: baseURL)!)
        request.httpMethod = "POST"
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw MiniMaxError.requestFailed(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0)
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let choices = json?["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String
        else { throw MiniMaxError.invalidResponse }

        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func generateFramePrompt(
        background: String,
        characters: [(name: String, position: String, expression: String)],
        cameraShot: String,
        isFirstFrame: Bool,
        motionDirection: String,
        animationStyle: String
    ) async throws -> String {
        guard !apiKey.isEmpty else { throw MiniMaxError.noAPIKey }

        let systemPrompt = "You are an expert at writing image generation prompts for animation keyframes. Generate a detailed prompt describing a single frame. Include: character positions, expressions, camera angle, background, lighting, and animation style. Output ONLY the prompt, nothing else."

        var charDesc = characters.map { "\($0.name) at \($0.position), expression: \($0.expression)" }.joined(separator: "; ")
        let frameType = isFirstFrame ? "FIRST frame (starting state)" : "LAST frame (ending state after motion)"
        let userContent = "Background: \(background)\nCharacters: \(charDesc)\nCamera: \(cameraShot)\nFrame type: \(frameType)\nMotion: \(motionDirection)\nAnimation style: \(animationStyle)\n\nGenerate a detailed image generation prompt for this keyframe."

        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userContent]
            ],
            "max_tokens": 500,
            "temperature": 0.7
        ]

        var request = URLRequest(url: URL(string: baseURL)!)
        request.httpMethod = "POST"
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw MiniMaxError.requestFailed(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0)
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let choices = json?["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String
        else { throw MiniMaxError.invalidResponse }

        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    enum MiniMaxError: LocalizedError {
        case noAPIKey
        case requestFailed(statusCode: Int)
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .noAPIKey: return "No MiniMax API key configured."
            case .requestFailed(let code): return "MiniMax request failed (status \(code))."
            case .invalidResponse: return "Invalid response from MiniMax API."
            }
        }
    }
}