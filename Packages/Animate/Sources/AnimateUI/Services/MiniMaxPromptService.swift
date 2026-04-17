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

        let systemPrompt = """
        You are an expert at writing image-generation prompts for background plates.

        RULES:
        1. Write only in plain-language visual description.
        2. NEVER include place names, scene titles, character names, script references, or internal project labels.
        3. If the input uses shorthand or names, translate them into concrete visible details: architecture, terrain, materials, atmosphere, camera framing, lighting, and time of day.
        4. Describe only what the image model can actually see in the final frame.
        5. Do NOT include character descriptions unless the user explicitly asks for visible people.
        6. Output ONLY the prompt text, nothing else.
        """

        var userContent = """
        The following fields may contain internal names or shorthand. Use them only as hidden clues and rewrite them into one fully explicit visual prompt for a single background plate.

        Location label: \(placeName)
        Category: \(category)
        Notes: \(notes)
        """
        if let ctx = sceneContext {
            userContent += "\nScene/context label (do not mention directly): \(ctx)"
        }
        userContent += "\n\nGenerate the final prompt now."

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

        let systemPrompt = """
        You are an expert at writing image-generation prompts for animation keyframes.

        RULES:
        1. Write the frame entirely as plain-language visual description.
        2. NEVER include character names, scene names, script references, or internal labels.
        3. Convert all shorthand into concrete visible staging: body placement, expression, camera, lighting, environment, and motion state.
        4. Describe only what the image model can actually see in the frame.
        5. Output ONLY the prompt text, nothing else.
        """

        let charDesc = characters.enumerated().map { index, character in
            "character \(index + 1) at \(character.position), expression: \(character.expression)"
        }.joined(separator: "; ")
        let frameType = isFirstFrame ? "FIRST frame (starting state)" : "LAST frame (ending state after motion)"
        let userContent = """
        The following fields may contain shorthand. Rewrite them into one explicit image prompt for a single frame.

        Background/context label: \(background)
        Characters (use generic labels only): \(charDesc)
        Camera: \(cameraShot)
        Frame type: \(frameType)
        Motion state: \(motionDirection)
        Animation style: \(animationStyle)

        Generate the final prompt now.
        """

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
