import Foundation

@available(macOS 26.0, *)
@MainActor
struct MiniMaxAutomationScaffoldService {
    var store: AnimateStore

    struct Request: Sendable {
        var scene: AnimationScene
        var projectRoot: URL
        var mode: String
        var provider: SupplementalLLMProvider
        var model: String
        var writeSidecars: Bool
        var apiKey: String
    }

    func build(_ request: Request) async throws -> MiniMaxAutomationScaffoldArtifact {
        let isExecute = request.mode.lowercased() == "execute"
        let input = await buildInput(scene: request.scene, projectRoot: request.projectRoot)
        let prompts = Self.prompts(for: input)
        var artifact = MiniMaxAutomationScaffoldArtifact(
            id: UUID(),
            createdAt: Date(),
            provider: request.provider.rawValue,
            model: request.model,
            mode: isExecute ? "execute" : "dry_run",
            isDryRun: !isExecute,
            sceneID: request.scene.id,
            sceneName: request.scene.name,
            input: input,
            promptPath: nil,
            responsePath: nil,
            artifactPath: nil,
            rawModelResponse: nil,
            modelOutput: nil,
            blockers: input.shots.flatMap(\.blockers),
            errorMessage: nil
        )

        if request.writeSidecars {
            let paths = try writePromptSidecar(
                systemPrompt: prompts.system,
                userPrompt: prompts.user,
                artifactID: artifact.id,
                sceneID: request.scene.id,
                projectRoot: request.projectRoot
            )
            artifact.promptPath = paths.prompt.path
        }

        guard isExecute else {
            if request.writeSidecars {
                artifact.artifactPath = try writeArtifact(artifact, projectRoot: request.projectRoot).path
            }
            return artifact
        }

        guard !request.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            artifact.errorMessage = "\(request.provider.displayName) API key is not configured."
            artifact.blockers.append(.init(code: .failedProviderError, message: "\(request.provider.displayName) API key is not configured.", field: request.provider.apiKeyFieldName))
            if request.writeSidecars {
                artifact.artifactPath = try writeArtifact(artifact, projectRoot: request.projectRoot).path
            }
            return artifact
        }

        do {
            let raw = try await SupplementalLLMClient(
                configuration: .init(provider: request.provider, apiKey: request.apiKey, model: request.model)
            )
            .complete(systemPrompt: prompts.system, userPrompt: prompts.user)
            artifact.rawModelResponse = raw
            artifact.modelOutput = try Self.decodeModelOutput(raw)
            artifact.blockers.append(contentsOf: validateOutput(artifact.modelOutput, input: input))
            if request.writeSidecars {
                artifact.responsePath = try writeResponseSidecar(
                    raw,
                    artifactID: artifact.id,
                    sceneID: request.scene.id,
                    projectRoot: request.projectRoot
                ).path
            }
        } catch {
            artifact.errorMessage = error.localizedDescription
            artifact.blockers.append(.init(code: .failedProviderError, message: "\(request.provider.displayName) scaffold failed: \(error.localizedDescription)", field: request.provider.rawValue))
        }

        if request.writeSidecars {
            artifact.artifactPath = try writeArtifact(artifact, projectRoot: request.projectRoot).path
        }
        return artifact
    }

    private func buildInput(scene: AnimationScene, projectRoot: URL) async -> MiniMaxAutomationScaffoldInput {
        var warnings: [String] = []
        let world = AutomationSourceResolver.worldContext(projectRoot: projectRoot, warnings: &warnings)
        let specBuilder = EffectiveShotSpecBuilder(store: store)
        let resolver = ReferenceContractResolver(store: store)

        var shotInputs: [MiniMaxAutomationShotInput] = []
        for index in scene.shots.indices {
            let spec = specBuilder.build(scene: scene, shotIndex: index, projectRoot: projectRoot)
            let contract = (try? resolver.resolve(spec: spec, projectRoot: projectRoot, write: false).contract)
            let briefs = await referenceBriefs(from: contract?.usableReferences ?? [], projectRoot: projectRoot)
            shotInputs.append(
                MiniMaxAutomationShotInput(
                    shotID: spec.shotID,
                    shotIndex: spec.shotIndex,
                    shotName: spec.shotName,
                    startFrame: spec.startFrame,
                    endFrame: spec.endFrame,
                    action: spec.action,
                    cameraShot: spec.cameraShot,
                    shotIntent: spec.shotIntent,
                    focusCharacterSlug: spec.focusCharacterSlug,
                    characterSlugs: spec.characterSlugs,
                    backgroundName: spec.backgroundName,
                    promptSeed: spec.prompt,
                    blockers: spec.blockers + (contract?.blockers ?? []),
                    referenceBriefs: briefs
                )
            )
        }

        return MiniMaxAutomationScaffoldInput(
            sceneID: scene.id,
            sceneName: scene.name,
            projectRoot: projectRoot.path,
            worldPeriod: world?.timePeriod ?? "",
            regionalWorldCues: world?.environmental ?? "",
            styleLock: animatedLookPrompt(projectRoot: projectRoot) ?? "",
            hardRules: Self.hardRules(world: world),
            shots: shotInputs
        )
    }

    private func referenceBriefs(
        from references: [ReferenceContractItem],
        projectRoot: URL
    ) async -> [MiniMaxAutomationReferenceBrief] {
        var briefs: [MiniMaxAutomationReferenceBrief] = []
        for ref in references.prefix(10) {
            let path = resolvedPath(ref.path, projectRoot: projectRoot) ?? ref.path
            let lookup = await store.imageIntelligenceRecordAndMetadata(for: path)
            let metadata = lookup.metadata
            briefs.append(
                MiniMaxAutomationReferenceBrief(
                    role: ref.role.rawValue,
                    label: ref.label,
                    path: path,
                    source: ref.source,
                    shortCaption: metadata?.shortCaption,
                    retrievalTags: Array(Self.stringArray(fromJSONString: metadata?.retrievalJSON).prefix(24)),
                    entitiesJSON: metadata?.entitiesJSON,
                    sceneJSON: metadata?.sceneJSON,
                    cameraJSON: metadata?.cameraJSON,
                    styleJSON: metadata?.styleJSON
                )
            )
        }
        return briefs
    }

    private func validateOutput(
        _ output: MiniMaxAutomationScaffoldOutput?,
        input: MiniMaxAutomationScaffoldInput
    ) -> [AutomationBlocker] {
        guard let output else {
            return [.init(code: .failedProviderError, message: "Supplemental LLM did not return a valid scaffold JSON object.", field: "modelOutput")]
        }
        let expectedIDs = Set(input.shots.map { $0.shotID.uuidString.lowercased() })
        let actualIDs = Set(output.shots.map { $0.shotID.lowercased() })
        let missing = expectedIDs.subtracting(actualIDs)
        guard !missing.isEmpty else { return [] }
        return [.init(code: .failedProviderError, message: "Supplemental LLM scaffold omitted \(missing.count) shot(s).", field: "modelOutput.shots")]
    }

    private func writePromptSidecar(
        systemPrompt: String,
        userPrompt: String,
        artifactID: UUID,
        sceneID: UUID,
        projectRoot: URL
    ) throws -> (prompt: URL, dir: URL) {
        let dir = Self.scaffoldDirectory(projectRoot: projectRoot, sceneID: sceneID, artifactID: artifactID)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let promptURL = dir.appendingPathComponent("prompt.txt")
        try ["SYSTEM:\n\(systemPrompt)", "USER:\n\(userPrompt)"].joined(separator: "\n\n---\n\n")
            .write(to: promptURL, atomically: true, encoding: .utf8)
        return (promptURL, dir)
    }

    private func writeResponseSidecar(
        _ raw: String,
        artifactID: UUID,
        sceneID: UUID,
        projectRoot: URL
    ) throws -> URL {
        let dir = Self.scaffoldDirectory(projectRoot: projectRoot, sceneID: sceneID, artifactID: artifactID)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("response.txt")
        try raw.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func writeArtifact(_ artifact: MiniMaxAutomationScaffoldArtifact, projectRoot: URL) throws -> URL {
        let dir = Self.scaffoldDirectory(projectRoot: projectRoot, sceneID: artifact.sceneID, artifactID: artifact.id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("scaffold.json")
        var copy = artifact
        copy.artifactPath = url.path
        try writeCodable(copy, to: url)
        return url
    }

    private static func scaffoldDirectory(projectRoot: URL, sceneID: UUID, artifactID: UUID) -> URL {
        projectRoot
            .appendingPathComponent("Metadata", isDirectory: true)
            .appendingPathComponent("automation", isDirectory: true)
            .appendingPathComponent("minimax-scaffolds", isDirectory: true)
            .appendingPathComponent(sceneID.uuidString, isDirectory: true)
            .appendingPathComponent(artifactID.uuidString, isDirectory: true)
    }

    private static func hardRules(world: AutomationWorldContext?) -> [String] {
        var rules = [
            "Treat this as script-supervisor continuity data, not prose.",
            "Never rely on project title or scene title as visual shorthand.",
            "Spell out visible period, region, architecture, materials, lighting, framing, action, and visual tone.",
            "Costume continuity must be precise: silhouette, color blocking, camouflage pattern, accessories, headgear, footwear, dirt/wear state.",
            "Prefer previous approved frame as continuity reference unless the shot is a hard cut, new location, large time jump, or incompatible camera angle.",
            "When only one object is useful from a frame, flag it as a crop/extraction candidate instead of recommending the whole frame.",
            "For character identity, choose close-up/head-turn references for face/head angle and full-body/costume refs for silhouette/clothing/accessories."
        ]
        if let world {
            rules.append("Canonical world period: \(world.timePeriod)")
            rules.append("Canonical environmental/geography rules: \(world.environmental)")
        }
        return rules
    }

    private static func prompts(for input: MiniMaxAutomationScaffoldInput) -> (system: String, user: String) {
        let system = """
        You are a strict structured-data compiler for an animation pipeline.

        You must convert scene, shot, and image-analysis metadata into script-supervisor continuity JSON.
        Do not write prose outside JSON. Do not include markdown fences. Do not hallucinate project lore.
        If a detail is unknown, write an explicit conservative constraint such as "unknown; must be manually verified".

        Output exactly this JSON object shape:
        {
          "sceneContinuity": {
            "timeOfDay": "string",
            "geographyRules": ["string"],
            "lightingRules": ["string"],
            "forbiddenElements": ["string"],
            "continuityPriorities": ["string"]
          },
          "shots": [
            {
              "shotID": "UUID string from input",
              "shotIndex": 0,
              "continuityIntent": "string",
              "cameraGeometry": ["concrete camera/framing/angle/focal-length/turn notes"],
              "characterRequirements": ["exact visible character requirements"],
              "costumeRequirements": ["precise costume/accessory/camouflage continuity requirements"],
              "propVehicleRequirements": ["vehicles/props/objects that must or must not appear"],
              "referenceSelectionPlan": ["which roles of refs to use and why"],
              "cropOrExtractionCandidates": ["object/character crops worth extracting as isolated references"],
              "generateOrEditRecommendation": "generate | edit_from_previous | edit_from_reference_crop | blocked_manual_review, with reason",
              "promptComponents": ["short concrete visual prompt clauses"],
              "qaChecks": ["specific automated/human checks for this shot"],
              "negativeGuardrails": ["specific forbidden visual elements"]
            }
          ]
        }

        Frontier-quality requirements:
        - Think like a continuity supervisor and a computer-vision retrieval planner.
        - Use eighth-turn language where relevant: front, 1/8 left, 1/4 left, profile, 3/4 back, back, etc.
        - Distinguish close-up identity refs, full-body silhouette refs, costume refs, spatial map refs, previous-frame refs, and crop/extraction refs.
        - Preserve geography: river side, bridge count, town placement, road direction, highland valley material palette.
        - Avoid generic "cinematic" filler unless tied to a concrete visible constraint.
        """

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let json = (try? String(data: encoder.encode(input), encoding: .utf8)) ?? "{}"
        let user = """
        Build the scaffold JSON for this scene input.
        Return JSON only. Include every shot exactly once.

        INPUT_JSON:
        \(json)
        """
        return (system, user)
    }

    private static func decodeModelOutput(_ raw: String) throws -> MiniMaxAutomationScaffoldOutput {
        let cleaned = stripThinkTags(raw)
        let jsonText = extractJSONObject(cleaned)
        guard let data = jsonText.data(using: .utf8) else {
            throw MiniMaxAutomationError.invalidUTF8
        }
        return try JSONDecoder().decode(MiniMaxAutomationScaffoldOutput.self, from: data)
    }

    private static func stripThinkTags(_ text: String) -> String {
        var result = text
        if let regex = try? NSRegularExpression(pattern: #"<think>[\s\S]*?</think>\s*"#) {
            var previous = ""
            while result != previous {
                previous = result
                result = regex.stringByReplacingMatches(
                    in: result,
                    range: NSRange(location: 0, length: (result as NSString).length),
                    withTemplate: ""
                )
            }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func extractJSONObject(_ text: String) -> String {
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}") else { return text }
        return String(text[start...end])
    }

    private static func stringArray(fromJSONString raw: String?) -> [String] {
        guard let raw, let data = raw.data(using: .utf8),
              let values = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return values
    }
}

@available(macOS 26.0, *)
private struct MiniMaxAutomationClient {
    let apiKey: String
    let model: String
    var endpoint: URL = URL(string: "https://api.minimax.io/v1/chat/completions")!

    func completeJSON(systemPrompt: String, userPrompt: String) async throws -> String {
        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userPrompt]
            ],
            "temperature": 0.1,
            "max_tokens": 12000,
            "stream": false
        ]

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.addValue("Bearer \(apiKey.trimmingCharacters(in: .whitespacesAndNewlines))", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw MiniMaxAutomationError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw MiniMaxAutomationError.requestFailed(statusCode: http.statusCode, body: String(data: data, encoding: .utf8) ?? "")
        }
        let decoded = try JSONDecoder().decode(MiniMaxChatCompletionResponse.self, from: data)
        guard let content = decoded.choices?.first?.message?.content?.trimmingCharacters(in: .whitespacesAndNewlines),
              !content.isEmpty else {
            throw MiniMaxAutomationError.invalidResponse
        }
        return content
    }
}

@available(macOS 26.0, *)
private struct MiniMaxChatCompletionResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            let content: String?
        }
        let message: Message?
    }
    let choices: [Choice]?
}

@available(macOS 26.0, *)
private enum MiniMaxAutomationError: LocalizedError {
    case invalidUTF8
    case invalidResponse
    case requestFailed(statusCode: Int, body: String)

    var errorDescription: String? {
        switch self {
        case .invalidUTF8:
            return "Supplemental LLM response was not valid UTF-8."
        case .invalidResponse:
            return "Supplemental LLM response did not contain assistant content."
        case .requestFailed(let statusCode, let body):
            return "Supplemental LLM request failed with status \(statusCode): \(body.prefix(500))"
        }
    }
}
