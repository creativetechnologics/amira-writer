import Foundation

/// Generates animation plans from scene text using the Gemini LLM.
///
/// Takes scene text and a character list, builds a detailed prompt describing the
/// expected JSON schema, calls the Gemini generateContent endpoint (text-only), and
/// returns the raw JSON string that ``LLMAnimationPlanCompiler`` can parse.
@available(macOS 26.0, *)
struct LLMAnimationPlanGenerator: Sendable {

    // MARK: - Input / Output Types

    struct SceneContext: Sendable {
        /// The libretto / script text for this scene (stage directions, dialogue, etc.).
        let sceneText: String
        /// Characters expected to appear in the scene.
        let characters: [CharacterInfo]
        /// Human-readable scene name written into ``LLMAnimationPlan/sceneName``.
        let sceneName: String
        /// Music duration in bars, if known.
        let durationBars: Int?
        let fps: Int
        /// Stage width in metres — used to express x-range guidance in the prompt.
        let stageWidth: Double
        /// Stage depth in metres — used to express z-range guidance in the prompt.
        let stageDepth: Double

        struct CharacterInfo: Sendable {
            let name: String
            let slug: String
            let description: String
        }
    }

    struct GenerationResult: Sendable {
        /// The extracted, valid JSON string ready for ``LLMAnimationPlanCompiler/parse(json:)``.
        let rawJSON: String
        /// The full prompt that was sent to the model.
        let prompt: String
        /// The model identifier that was used (e.g. "gemini-2.0-flash").
        let model: String
    }

    enum GeneratorError: LocalizedError {
        case noAPIKey
        case invalidResponse
        case httpError(Int, String)
        case noTextInResponse
        case jsonExtractionFailed

        var errorDescription: String? {
            switch self {
            case .noAPIKey:
                return "No Gemini API key configured."
            case .invalidResponse:
                return "Invalid response from Gemini."
            case .httpError(let code, let msg):
                return "Gemini error \(code): \(msg)"
            case .noTextInResponse:
                return "No text content in LLM response."
            case .jsonExtractionFailed:
                return "Could not extract JSON from LLM response."
            }
        }
    }

    // MARK: - Prompt Building

    /// Build the system prompt that instructs the LLM on the expected JSON format.
    ///
    /// The schema mirrors ``LLMAnimationPlan`` and its associated model types so
    /// that the generated JSON can be fed directly into ``LLMAnimationPlanCompiler``.
    static func buildPrompt(context: SceneContext) -> String {
        let characterList = context.characters.map { c in
            "- \(c.name) (slug: \(c.slug)): \(c.description)"
        }.joined(separator: "\n")

        let durationNote = context.durationBars.map { "Duration: \($0) bars\n" } ?? ""

        // Normalised x coordinate range: positions are stored as 0…1 (left–right).
        // y is vertical: 0 = ground baseline, 1 = top of stage.
        // We give the LLM illustrative centre/edge values derived from the stage size
        // while keeping the actual values in the 0…1 normalised space the compiler expects.
        return """
        You are an animation director. Given a scene from a libretto or script, \
        generate a detailed animation plan as JSON.

        ## Scene Information
        Scene: \(context.sceneName)
        FPS: \(context.fps)
        Stage: \(context.stageWidth)m wide × \(context.stageDepth)m deep
        \(durationNote)
        ## Characters
        \(characterList.isEmpty ? "(none specified)" : characterList)

        ## Scene Text
        \(context.sceneText)

        ## Output Format

        Return ONLY valid JSON — no markdown fences, no explanation — matching this \
        exact structure. All fields shown are the real field names used by the parser.

        {
          "schemaVersion": 8,
          "sceneName": "\(context.sceneName)",
          "backgroundName": null,
          "lighting": null,

          "characterPlacements": [
            {
              "characterName": "Luke",
              "frame": 0,
              "position": { "x": 0.3, "y": 0.56 },
              "facing": "right",
              "pose": "neutral",
              "emotion": "neutral",
              "zOrder": 0
            }
          ],

          "motions": [
            {
              "characterName": "Luke",
              "startFrame": 24,
              "endFrame": 72,
              "from": { "x": 0.3, "y": 0.56 },
              "to": { "x": 0.6, "y": 0.56 },
              "easing": "ease_in_out",
              "facing": "right",
              "pose": "walking",
              "movementStyle": "walk"
            }
          ],

          "expressions": [
            {
              "characterName": "Luke",
              "frame": 0,
              "expression": "neutral"
            }
          ],

          "dialogueBeats": [
            {
              "characterName": "Luke",
              "startFrame": 72,
              "audioPath": "placeholder",
              "transcript": "the actual dialogue text — include the exact spoken words here",
              "action": "speak",
              "expression": "determined"
            }
          ],

          "cameraMoves": [
            {
              "movement": "hold",
              "startFrame": 0,
              "endFrame": 48,
              "fromShot": "medium",
              "toShot": "medium",
              "easing": "ease_in_out"
            }
          ],

          "objectPlacements": [],
          "objectMotions": [],
          "shadowCues": [],
          "objectStateCues": [],
          "shotPresetApplications": [],
          "notes": []
        }

        ## Field Reference

        ### position (x, y)
        - x: 0.0 = left edge, 0.5 = centre, 1.0 = right edge (normalised stage width)
        - y: 0.56 is a good ground-level baseline; 0 = bottom, 1 = top
        - Keep all values roughly in −0.1 … 1.1 to stay on stage

        ### facing
        Must be one of: "left", "right", "camera", "away"
        - "camera" = character faces the audience (front view)
        - "away" = character faces upstage (back view)
        - Use "left" or "right" for profile / three-quarter views

        ### pose
        Optional. One of: "neutral", "frontal", "threeQuarter", "profile",
        "seated", "walking", "pointing", "action"

        ### emotion / expression
        Use one of these presets:
        joy, love, pride, relief, excitement, hopeful, sad, angry, fear, disgust,
        contempt, worried, frustrated, tired, surprised, awe, attentive, skeptical,
        smug, determined, sympathetic, shy, neutral, contemplative, serene,
        bittersweet, nervousExcitement, guiltySadness, reluctantDetermination

        ### easing
        One of: "linear", "ease_in", "ease_out", "ease_in_out", "stepped"

        ### movement (cameraMoves)
        One of: "zoom_in", "zoom_out", "pan_left", "pan_right", "pan_up",
        "pan_down", "track", "shake", "hold"

        ### fromShot / toShot (cameraMoves)
        One of: "extreme_wide", "wide", "medium", "medium_close", "close",
        "extreme_close"

        ### action (dialogueBeats)
        One of: "speak", "sing", "listen", "gesture", "walk", "run", "stand",
        "sit", "react", "present", "turn", "bow", "dance"

        ### dialogueBeats audioPath
        Always set to "placeholder" — do NOT invent file paths like "audio/dialogue/..."
        or any path that looks like a real file. Audio paths are populated separately by
        the application after generation. The value "placeholder" is the only accepted
        sentinel and will be ignored by the audio loader.

        ## Timing Reference
        - 1 second = \(context.fps) frames
        - 1 bar ≈ \(context.fps * 2) frames (at ~120 BPM)
        \(context.durationBars.map { "- Total scene length ≈ \($0 * context.fps * 2) frames" } ?? "")

        ## Directing Guidelines
        - Place characters at distinct x positions so they don't overlap
        - Characters face each other when conversing (one "right", one "left")
        - Use motions for entrances, exits, and dramatic crosses
        - Match expressions to emotional beats in the text
        - Generate a dialogueBeat for every spoken or sung line (always use audioPath = "placeholder", never invent file paths)
        - Include at least one cameraMove covering the full scene duration
        - Use camera cuts (new cameraMoves) to emphasise dramatic moments
        - Add expression cues as mood shifts happen
        """
    }

    // MARK: - Generation

    /// Generate an animation plan from scene context by calling the Gemini API.
    ///
    /// - Parameters:
    ///   - context: Scene information used to build the prompt.
    ///   - apiKey: Gemini API key (from `AnimateStore.geminiAPIKey`).
    ///   - model: Gemini model identifier. Defaults to `"gemini-2.0-flash"`.
    /// - Returns: A ``GenerationResult`` whose `rawJSON` can be passed directly to
    ///   ``LLMAnimationPlanCompiler/parse(json:)``.
    static func generate(
        context: SceneContext,
        apiKey: String,
        model: String = "gemini-2.0-flash"
    ) async throws -> GenerationResult {
        guard !apiKey.isEmpty else { throw GeneratorError.noAPIKey }

        let prompt = buildPrompt(context: context)

        let baseURL = "https://generativelanguage.googleapis.com/v1beta/models"
        guard let url = URL(string: "\(baseURL)/\(model):generateContent") else {
            throw GeneratorError.invalidResponse
        }

        // Request JSON output directly via responseMimeType to minimise markdown wrapping.
        let requestBody: [String: Any] = [
            "contents": [
                ["parts": [["text": prompt]]]
            ],
            "generationConfig": [
                "responseMimeType": "application/json",
                "temperature": 0.7,
                "maxOutputTokens": 8192,
            ],
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
        request.timeoutInterval = 120

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw GeneratorError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "No body"
            throw GeneratorError.httpError(httpResponse.statusCode, body)
        }

        // Extract the text part from the Gemini candidates array.
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let candidates = json["candidates"] as? [[String: Any]],
            let firstCandidate = candidates.first,
            let content = firstCandidate["content"] as? [String: Any],
            let parts = content["parts"] as? [[String: Any]],
            let firstPart = parts.first,
            let text = firstPart["text"] as? String
        else {
            throw GeneratorError.noTextInResponse
        }

        let cleanJSON = extractJSON(from: text)
        guard !cleanJSON.isEmpty else {
            throw GeneratorError.jsonExtractionFailed
        }

        return GenerationResult(rawJSON: cleanJSON, prompt: prompt, model: model)
    }

    // MARK: - JSON Extraction

    /// Extract a valid JSON object from text that may contain markdown code fences.
    static func extractJSON(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Fast path: entire response is already valid JSON.
        if isValidJSON(trimmed) { return trimmed }

        // Try stripping ```json … ``` or ``` … ``` fences.
        let fencePatterns = ["```json\n", "```JSON\n", "```\n"]
        for pattern in fencePatterns {
            if let startRange = trimmed.range(of: pattern),
               let endRange = trimmed.range(of: "\n```", range: startRange.upperBound..<trimmed.endIndex) {
                let candidate = String(trimmed[startRange.upperBound..<endRange.lowerBound])
                if isValidJSON(candidate) { return candidate }
            }
        }

        // Last resort: substring from first { to last }.
        if let firstBrace = trimmed.firstIndex(of: "{"),
           let lastBrace = trimmed.lastIndex(of: "}") {
            let candidate = String(trimmed[firstBrace...lastBrace])
            if isValidJSON(candidate) { return candidate }
        }

        return ""
    }

    private static func isValidJSON(_ string: String) -> Bool {
        (try? JSONSerialization.jsonObject(with: Data(string.utf8))) != nil
    }
}
