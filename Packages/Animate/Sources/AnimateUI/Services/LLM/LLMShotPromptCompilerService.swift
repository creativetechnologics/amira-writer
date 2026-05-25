import Foundation

@available(macOS 26.0, *)
struct LLMShotPromptCompilerService: Sendable {
    struct Request: Sendable {
        var spec: EffectiveShotSpec
        var contract: ReferenceContract
        var moment: ImagineShotMoment
        var deterministicPrompt: String
        var openMatteInstruction: String
        var generatedAspectRatio: String
        var generatedImageSize: String
        var projectRoot: URL
        var provider: SupplementalLLMProvider
        var model: String
        var apiKey: String
    }

    struct Result: Codable, Sendable, Hashable {
        var prompt: String
        var visualChecklist: [String]
        var warnings: [String]
    }

    func compile(_ request: Request) async throws -> Result {
        let prompts = Self.prompts(for: request)
        let raw = try await SupplementalLLMClient(
            configuration: .init(
                provider: request.provider,
                apiKey: request.apiKey,
                model: request.model
            )
        )
        .complete(
            systemPrompt: prompts.system,
            userPrompt: prompts.user,
            temperature: 0.15,
            maxTokens: 4_000,
            jsonMode: true
        )
        return try Self.decode(raw)
    }

    private static func prompts(for request: Request) -> (system: String, user: String) {
        let system = """
        You are a final prompt compiler for a Vertex image-generation pipeline.

        Your job is to write one complete, isolated visual prompt for exactly one still image. The image generator has no project memory. It only knows the prompt and attached images.

        Rules:
        - Output JSON only: {"prompt":"...","visualChecklist":["..."],"warnings":["..."]}.
        - The prompt must describe only visible image content: subjects, location, wardrobe, props, camera angle, lighting, style, composition, and exact frame-state.
        - Do not mention scene names, shot numbers, script lines, project names, character names, motivation, subtext, mission purpose, or why the moment matters.
        - Do not say "beginning frame", "middle frame", "end frame", "earlier instant", "second image", "later image", or "standalone image".
        - Do not say "cinematic photorealism"; use the animated style instructions instead.
        - Do not call the output a photograph, photoreal image, documentary still, concept art sheet, or storyboard panel.
        - Use the attached references only as visual references. If references conflict with the shot requirements, state the visible requirement in the prompt.
        - Preserve the shot-card focus and notes as the priority hierarchy. Elements from broader world continuity should stay secondary unless the shot card asks them to be the visual focus.
        - If a visible element appears only in broad continuity/materials/guardrails, make it small, distant, or optional; do not let it dominate the composition.
        - Keep generated output clean: no text, captions, watermarks, borders, white frame lines, crop boxes, guide marks, UI overlays, or collage panels.
        - If the shot implies movement, make this exact frame position explicit, such as subjects on the left/center/right and the direction they face.
        - If a Humvee cabin/interior is visible, place people naturally in vehicle seats, with realistic body scale and seat positions.
        - Never include power lines, utility poles, telephone poles, electrical wires, hanging cables, or modern grid infrastructure.
        - Treat haze as subtle distance atmospheric perspective only. Do not make haze, dust, fog, or smoke a visible subject unless the shot explicitly requires it.
        """

        let input = PromptInput(
            moment: request.moment.rawValue,
            generatedAspectRatio: request.generatedAspectRatio,
            generatedImageSize: request.generatedImageSize,
            sceneName: request.spec.sceneName,
            shotName: request.spec.shotName,
            shotCardLabel: request.spec.shotCardLabel,
            shotCardFocus: request.spec.shotCardFocus,
            shotCardNotes: request.spec.shotCardNotes,
            shotCardContinuityNotes: request.spec.shotCardContinuityNotes,
            shotCardPlaces: request.spec.shotCardPlaces ?? [],
            shotCardProps: request.spec.shotCardProps ?? [],
            shotCardLandmarks: request.spec.shotCardLandmarks ?? [],
            action: request.spec.action,
            notes: request.spec.notes,
            lyricExcerpt: request.spec.lyricExcerpt,
            cameraShot: request.spec.cameraShot,
            cameraFraming: request.spec.cameraFraming,
            lighting: request.spec.lighting,
            regionalWorldCues: request.spec.regionalWorldCues,
            architectureMaterials: request.spec.architectureMaterials,
            visualTone: request.spec.visualTone,
            negativeGuardrails: request.spec.negativeGuardrails,
            deterministicPrompt: request.deterministicPrompt,
            openMatteInstruction: request.openMatteInstruction,
            references: request.contract.usableReferences.map {
                PromptReference(
                    role: $0.role.rawValue,
                    label: $0.label,
                    source: $0.source,
                    guidance: $0.guidance,
                    pathTail: URL(fileURLWithPath: $0.path).lastPathComponent
                )
            }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let json = (try? String(data: encoder.encode(input), encoding: .utf8)) ?? "{}"
        let user = """
        Compile the final prompt for this one image.

        INPUT_JSON:
        \(json)
        """
        return (system, user)
    }

    private static func decode(_ raw: String) throws -> Result {
        let cleaned = extractJSONObject(raw)
        guard let data = cleaned.data(using: .utf8) else {
            throw SupplementalLLMError.invalidResponse(provider: "LLM prompt compiler")
        }
        let decoded = try JSONDecoder().decode(Result.self, from: data)
        let prompt = decoded.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            throw SupplementalLLMError.invalidResponse(provider: "LLM prompt compiler")
        }
        return .init(
            prompt: prompt,
            visualChecklist: decoded.visualChecklist,
            warnings: decoded.warnings
        )
    }

    private static func extractJSONObject(_ text: String) -> String {
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}") else { return text }
        return String(text[start...end])
    }

    private struct PromptInput: Codable, Sendable {
        var moment: String
        var generatedAspectRatio: String
        var generatedImageSize: String
        var sceneName: String
        var shotName: String
        var shotCardLabel: String?
        var shotCardFocus: String?
        var shotCardNotes: String?
        var shotCardContinuityNotes: String?
        var shotCardPlaces: [String]
        var shotCardProps: [String]
        var shotCardLandmarks: [String]
        var action: String
        var notes: String?
        var lyricExcerpt: String?
        var cameraShot: String?
        var cameraFraming: String
        var lighting: String
        var regionalWorldCues: String
        var architectureMaterials: String
        var visualTone: String
        var negativeGuardrails: [String]
        var deterministicPrompt: String
        var openMatteInstruction: String
        var references: [PromptReference]
    }

    private struct PromptReference: Codable, Sendable {
        var role: String
        var label: String
        var source: String
        var guidance: String?
        var pathTail: String
    }
}
